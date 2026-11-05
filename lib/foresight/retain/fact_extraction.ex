defmodule Foresight.Retain.FactExtraction do
  @moduledoc """
  Retain-time atomic fact extraction — the keystone that gives reflect
  something structured to aggregate over.

  Faithful port of Hindsight's `engine/retain/fact_extraction.py`: each incoming
  retain item (a chat session, document, or paragraph) is decomposed by an LLM
  into a LIST of atomic facts, one input to N discrete memory units. Whole-session
  blobs cannot be aggregated across sessions (the buried "took course X" / "spent
  €40" facts never individuate, so cross-session counts and temporal ordering are
  unanswerable); atomizing them restores the material that recall ranks,
  consolidation merges into observations, and reflect sums.

  Each produced fact-item INHERITS the parent's provenance and — critically — its
  `mentioned_at` (the session date), so every atomic fact carries the timestamp
  reflect's per-entry temporal arithmetic depends on. Extraction OVERRIDES only
  `content` (the assembled fact text), `type` (world/experience), and the
  `occurred_*` dates for datable events.

  Extraction is gated: it runs only when a mode is configured AND an
  extraction-capable LLM is available. It degrades to passthrough (the original
  item, i.e. today's blob behaviour) on any LLM error, timeout, or empty result —
  extraction never fails a retain. This mirrors the LlmCore isolation the rest of
  the pipeline relies on.
  """

  alias Foresight.LLMs.StructuredRecovery
  alias Foresight.Prompts.Retain.V1, as: Prompt

  require Logger

  @doc """
  Expand `items` into atomic fact-items, or return them unchanged (passthrough).

  Opts:
    * `:mode` — "concise" | "verbatim" | "custom" | nil/"none" (nil/"none" disables)
    * `:llm` — the `Foresight.LLM` implementation module (needs `complete_json_schema/4`)
    * `:mission` — optional extraction mission steering what is worth keeping
    * `:custom_instructions` — guidelines body for `"custom"` mode
    * `:chunk_size` — characters per extraction chunk (default 3000)
    * `:deadline_ms` — wall-clock budget for the whole call. Once it has elapsed,
      every item (and every chunk) not yet started is stored as-is and counted in
      `fallback_items`, with the fallback telemetry reason `:deadline`. A chunk
      already in flight finishes (or hits the LLM timeout). nil (default) is no deadline.
    * `:max_concurrency` — chunks of one item extracted concurrently, in order
      (default 1, i.e. sequential). Wall time then scales with the slowest chunk
      rather than the sum. Usage recorded by the LLM inside the concurrent calls is
      folded back into the caller's ledger.
    * `:provider` / `:provider_opts` / `:sleep_ms` — passed through to the LLM
  """
  @spec maybe_extract([map()], keyword()) :: [map()]
  def maybe_extract(items, opts) when is_list(items), do: items |> extract(opts) |> elem(0)

  @typedoc """
  Per-call accounting of how extraction degraded. `fallback_items` counts items stored
  as their raw text because extraction ERRORED (LLM error, timeout, or a response that
  was not a facts list); `empty_items` counts items stored raw because extraction ran
  and found no facts. Both are 0 when extraction is disabled.
  """
  @type stats :: %{
          enabled: boolean(),
          mode: String.t() | nil,
          fallback_items: non_neg_integer(),
          empty_items: non_neg_integer()
        }

  @doc """
  Like `maybe_extract/2`, returning `{items, stats}`. Retain surfaces the stats on its
  result so a caller can tell a degraded retain from a clean one without attaching to
  the `[:foresight, :retain, :extraction_fallback]` telemetry event.
  """
  @spec extract([map()], keyword()) :: {[map()], stats()}
  def extract(items, opts) when is_list(items) do
    mode = enabled_mode(opts[:mode])
    llm = opts[:llm]

    if is_nil(mode) or not extractable?(llm) do
      {items, %{enabled: false, mode: nil, fallback_items: 0, empty_items: 0}}
    else
      typed = typed_entities?(opts)
      initial = %{enabled: true, mode: mode, fallback_items: 0, empty_items: 0}
      opts = Keyword.put(opts, :deadline_at, deadline_at(opts[:deadline_ms]))

      {expanded, stats} =
        Enum.reduce(items, {[], initial}, fn item, {acc, stats} ->
          {expanded_items, outcome} = extract_item(item, llm, mode, typed, opts)
          {[expanded_items | acc], bump_stat(stats, outcome)}
        end)

      {expanded |> Enum.reverse() |> List.flatten(), stats}
    end
  end

  defp bump_stat(stats, :fallback), do: Map.update!(stats, :fallback_items, &(&1 + 1))
  defp bump_stat(stats, :empty), do: Map.update!(stats, :empty_items, &(&1 + 1))
  defp bump_stat(stats, _outcome), do: stats

  # Opt-in typed entity extraction. Off by default so the extraction baseline
  # (and the eval) is unchanged; callers or config can enable it once type quality is
  # measured. Accepts an explicit opt or the :typed_entity_extraction app config.
  defp typed_entities?(opts) do
    case Keyword.get(opts, :typed_entities) do
      nil -> Application.get_env(:foresight, :typed_entity_extraction, false) == true
      value -> value == true
    end
  end

  @doc "True when `mode` and `llm` would drive real extraction (used by callers to log/branch)."
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts) do
    not is_nil(enabled_mode(opts[:mode])) and extractable?(opts[:llm])
  end

  defp enabled_mode(nil), do: nil

  defp enabled_mode(mode) when is_binary(mode) do
    case String.downcase(mode) do
      "" -> nil
      "none" -> nil
      "off" -> nil
      "false" -> nil
      _other -> mode
    end
  end

  defp enabled_mode(_other), do: nil

  defp extractable?(llm) do
    is_atom(llm) and not is_nil(llm) and Code.ensure_loaded?(llm) and
      function_exported?(llm, :complete_json_schema, 4)
  end

  defp extract_item(%{"content" => content} = item, llm, mode, typed, opts)
       when is_binary(content) do
    if deadline_passed?(opts[:deadline_at]) do
      # Nothing of this item was started: one fallback event for the item, not one
      # per chunk it would have had.
      report_fallback(:deadline, mode)
      {[item], :fallback}
    else
      extract_item_chunks(item, content, llm, mode, typed, opts)
    end
  end

  defp extract_item(item, _llm, _mode, _typed, _opts), do: {[item], :skipped}

  defp extract_item_chunks(item, content, llm, mode, typed, opts) do
    event_date = event_date(item)

    # Split long input into ~3000-char chunks and extract per chunk, so long
    # sessions don't cap out in one LLM response (Hindsight `chunk_text` /
    # `_chunk_conversation`, fact_extraction.py ~L364-450). Facts are concatenated
    # across chunks IN ORDER; a short input is a single chunk (prior behaviour).
    chunk_results =
      content
      |> chunk_text(chunk_size(opts))
      |> run_chunks(mode, opts, &extract_chunk_facts(&1, llm, mode, typed, event_date, opts))

    # If ANY chunk ERRORED, fall back to the whole-item blob
    # so a transient/partial failure never silently drops that chunk's content —
    # this preserves the pre-chunking safe-degradation contract (any extraction
    # failure → store the blob). A chunk that legitimately yields no significant
    # facts (`{:ok, []}`) is not an error and does not trigger the fallback.
    if Enum.any?(chunk_results, &(&1 == :error)) do
      {[item], :fallback}
    else
      facts = Enum.flat_map(chunk_results, fn {:ok, facts} -> facts end)

      case facts |> Enum.map(&fact_to_item(&1, item)) |> Enum.reject(&is_nil/1) do
        [] -> {[item], :empty}
        mapped -> {add_temporal_offsets(mapped), :extracted}
      end
    end
  end

  # Run the per-chunk extraction sequentially (the default, and always for a single
  # chunk) or across a bounded number of concurrent tasks, keeping chunk order. The
  # usage ledger is per process, so each task records into its own and hands the
  # entries back for the caller's ledger; a task killed by the deadline is a
  # `:deadline` fallback like any other.
  defp run_chunks([chunk], _mode, _opts, fun), do: [fun.(chunk)]

  defp run_chunks(chunks, mode, opts, fun) do
    case max_concurrency(opts) do
      1 ->
        Enum.map(chunks, fun)

      concurrency ->
        chunks
        |> Task.async_stream(
          fn chunk ->
            Foresight.Usage.start()
            result = fun.(chunk)
            {result, Foresight.Usage.drain()}
          end,
          max_concurrency: concurrency,
          ordered: true,
          timeout: task_timeout(opts[:deadline_at]),
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, {result, usage_entries}} ->
            Enum.each(usage_entries, &Foresight.Usage.record/1)
            result

          {:exit, :timeout} ->
            report_fallback(:deadline, mode)
            :error

          {:exit, reason} ->
            report_fallback({:exit, reason}, mode)
            :error
        end)
    end
  end

  defp max_concurrency(opts) do
    case opts[:max_concurrency] do
      n when is_integer(n) and n > 1 -> n
      _other -> 1
    end
  end

  defp deadline_at(ms) when is_integer(ms) and ms > 0,
    do: System.monotonic_time(:millisecond) + ms

  defp deadline_at(_ms), do: nil

  defp deadline_passed?(nil), do: false
  defp deadline_passed?(at), do: System.monotonic_time(:millisecond) >= at

  defp task_timeout(nil), do: :infinity
  defp task_timeout(at), do: max(at - System.monotonic_time(:millisecond), 1)

  # Run one extraction call for a single chunk. `{:ok, facts}` on a valid facts
  # list (possibly empty — legitimately no significant facts); `:error` on an LLM
  # error OR a non-facts response, which the caller treats as a failure and blobs
  # the whole item (safe degradation: a bad chunk never crashes retain, and never
  # silently drops content).
  defp extract_chunk_facts(chunk, llm, mode, typed, event_date, opts) do
    if deadline_passed?(opts[:deadline_at]) do
      report_fallback(:deadline, mode)
      :error
    else
      do_extract_chunk_facts(chunk, llm, mode, typed, event_date, opts)
    end
  end

  defp do_extract_chunk_facts(chunk, llm, mode, typed, event_date, opts) do
    messages =
      Prompt.messages(chunk, event_date,
        mode: mode,
        mission: opts[:mission],
        custom_instructions: opts[:custom_instructions],
        typed_entities: typed
      )

    prompt = %{query: "retain.extract", mode: mode, content: chunk}

    case safe_complete(llm, prompt, messages, typed, opts) do
      {:ok, %{"facts" => facts}} when is_list(facts) ->
        {:ok, facts}

      {:ok, other} ->
        # Valid JSON that is not a facts list. It falls back exactly like an LLM error
        # and must be just as visible; it used to be the one silent fallback path.
        report_fallback({:unexpected_extraction_shape, shape_summary(other)}, mode)
        :error

      {:error, reason} ->
        report_fallback(reason, mode)
        :error
    end
  end

  # This fallback stores the raw blob instead of extracted facts, which is exactly
  # the deficit that per-chunk fact extraction fixed (-0.267 answer accuracy). It degrades quality
  # silently by design — retain still succeeds — so anything measuring quality needs
  # a way to know it happened. A log line is not that: an earlier head-to-head
  # degraded 10 times and would have scored the run anyway. Hence the telemetry
  # event (one per failed chunk) and the per-item counts retain reports.
  #
  # The log line names only the failure KIND. The raw reason is never logged: a
  # structured-output failure carries the model's attempted output, i.e. facts
  # derived from the user's text. Telemetry handlers do receive the raw reason.
  defp report_fallback(reason, mode) do
    kind = reason_kind(reason)

    Logger.warning("retain fact extraction failed; storing content as-is (#{kind})")

    :telemetry.execute(
      [:foresight, :retain, :extraction_fallback],
      %{count: 1},
      %{reason: reason, reason_kind: kind, mode: mode}
    )
  end

  defp shape_summary(%{} = map), do: map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
  defp shape_summary(other), do: type_name(other)

  defp reason_kind(%{__struct__: module, reason: reason}) when is_atom(reason),
    do: "#{inspect(module)} #{inspect(reason)}"

  defp reason_kind(%{__struct__: module}), do: inspect(module)
  defp reason_kind({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_kind(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_kind(other), do: type_name(other)

  defp type_name(value) when is_binary(value), do: "binary"
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(value) when is_number(value), do: "number"
  defp type_name(value) when is_tuple(value), do: "tuple"
  defp type_name(_value), do: "term"

  # Mirror Hindsight's `_add_temporal_offsets` (fact_extraction.py ~L2245-2269,
  # SECONDS_PER_FACT = 0.01). Each fact's timestamp is nudged by `index * 10ms` so
  # facts extracted from one session keep their emission order and don't tie on a
  # shared session date. Index 0 (offset 0) is left byte-for-byte unchanged; later
  # facts add ms while preserving the same calendar date and timezone. Facts with no
  # `mentioned_at` are unaffected. NOTE: Hindsight also offsets occurred_start/end;
  # this port scopes the nudge to mentioned_at deliberately, so datable
  # occurred_* dates stay exactly as extracted/inferred.
  @ms_per_fact 10

  defp add_temporal_offsets(items) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} -> offset_mentioned_at(item, index * @ms_per_fact) end)
  end

  defp offset_mentioned_at(item, 0), do: item

  defp offset_mentioned_at(item, offset_ms) do
    case item["mentioned_at"] do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _utc_offset} ->
            shifted = DateTime.add(dt, offset_ms, :millisecond)
            Map.put(item, "mentioned_at", DateTime.to_iso8601(shifted))

          _ ->
            item
        end

      _ ->
        item
    end
  end

  defp safe_complete(llm, prompt, messages, typed, opts) do
    case llm.complete_json_schema(
           prompt,
           messages,
           Prompt.schema(typed_entities: typed),
           llm_opts(opts)
         ) do
      {:ok, response} when is_map(response) ->
        {:ok, stringify(response)}

      {:error, reason} ->
        # Ollama-served models routinely wrap their JSON in ```json fences (and
        # sometimes trailing commas) despite response_format, which trips the
        # strict structured-output parse. The error carries the raw body, so try
        # to recover valid facts from it before giving up to passthrough.
        case StructuredRecovery.recover(reason) do
          {:ok, %{"facts" => _} = decoded} -> {:ok, stringify(decoded)}
          _ -> {:error, reason}
        end

      other ->
        {:error, {:unexpected_extraction_result, other}}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Hindsight hardcodes temperature 0.1 for reproducible, low-noise extraction
  # (fact_extraction.py:938/1016). It also sets max_completion_tokens so long
  # chunks don't truncate (py:942/1017). Foresight forwards `max_tokens` via
  # provider_opts (LlmCore.maybe_put_opt(:max_tokens, ...)). Default value used
  # unless the caller already set one — RETAIN_MAX_COMPLETION_TOKENS in Hindsight is
  # 64000, but that exceeds Foresight's local model context; 4096 is the safe
  # default here (still > the 3000-char chunk size, so it cannot truncate a single chunk).
  @extraction_temperature 0.1
  @extraction_max_tokens 4096

  # Only forward non-nil provider hints: LlmCore merges these onto the engine
  # config, and a nil provider_opts would crash its Keyword.merge. Inject the
  # extraction defaults (temperature/max_tokens) into provider_opts unless the
  # caller already supplied them.
  defp llm_opts(opts) do
    # Default when the key is absent OR explicitly nil, so a
    # caller-passed `nil` (not a meaningful override) does not flow through to
    # LlmCore in place of the extraction default.
    provider_opts =
      (opts[:provider_opts] || [])
      |> put_default(:temperature, @extraction_temperature)
      |> put_default(:max_tokens, @extraction_max_tokens)

    opts
    |> Keyword.take([:provider, :sleep_ms])
    |> Keyword.put(:provider_opts, provider_opts)
    |> Keyword.put(:usage_role, :extract)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp put_default(kw, key, default) do
    case Keyword.get(kw, key) do
      nil -> Keyword.put(kw, key, default)
      _present -> kw
    end
  end

  # Build a retain item for one extracted fact, inheriting the parent's provenance
  # (context, tags, metadata, document_ref, source_location, mentioned_at, scopes)
  # and overriding only content / type / occurred dates.
  defp fact_to_item(%{} = fact, parent) do
    text = fact |> Prompt.build_fact_text() |> Foresight.Text.Sanitize.llm_output()

    if blank?(text) do
      nil
    else
      {occurred_start, occurred_end} = occurred_dates(fact, parent, text)

      parent
      |> Map.drop(["id"])
      |> Map.merge(%{
        "content" => text,
        "type" => map_fact_type(fact["fact_type"]),
        "entities" => fact_entities(fact),
        "occurred_start" => occurred_start,
        "occurred_end" => occurred_end
      })
      |> put_occurred_at(fact, occurred_start)
    end
  end

  defp fact_to_item(_fact, _parent), do: nil

  # Carry the LLM-extracted entities on the fact-item so materialize_entities uses
  # them directly, mirroring Hindsight's `fact.entities` source
  # (entity_processing.py:32) instead of re-deriving entities from the fact text
  # with a regex. The schema emits a bare string array; be tolerant of the
  # {"name"/"text" => ...} object shape too. Empty/absent → [] (respected, not
  # backfilled by the fallback extractor).
  defp fact_entities(%{"entities" => list}) when is_list(list) do
    list
    |> Enum.map(&normalize_entity_entry/1)
    |> Enum.reject(&(entry_name(&1) == ""))
    |> Enum.uniq_by(&entry_name/1)
  end

  defp fact_entities(_fact), do: []

  # Typed entities: a bare string stays a string (implicitly CONCEPT downstream);
  # an object carrying a "type" is preserved as {"name","type"} with the type upcased;
  # an object WITHOUT a type collapses to its bare name, keeping the string-array
  # contract backward-compatible for untyped extraction.
  defp normalize_entity_entry(name) when is_binary(name), do: String.trim(name)

  defp normalize_entity_entry(%{} = obj) do
    name = entity_text(obj)
    type = entity_type(obj)

    cond do
      name == "" -> ""
      is_nil(type) -> name
      true -> %{"name" => name, "type" => type}
    end
  end

  defp normalize_entity_entry(_other), do: ""

  defp entity_text(%{"name" => name}) when is_binary(name), do: String.trim(name)
  defp entity_text(%{"text" => text}) when is_binary(text), do: String.trim(text)
  defp entity_text(_other), do: ""

  defp entity_type(%{"type" => type}) when is_binary(type) do
    case String.trim(type) do
      "" -> nil
      trimmed -> String.upcase(trimmed)
    end
  end

  defp entity_type(_other), do: nil

  defp entry_name(name) when is_binary(name), do: name
  defp entry_name(%{"name" => name}) when is_binary(name), do: name
  defp entry_name(_other), do: ""

  # Hindsight "assistant" (first-person actions/experiences) maps to Foresight's
  # :experience; "world" stays "world". Unknown → let normalize_fact_type default.
  defp map_fact_type("world"), do: "world"
  defp map_fact_type("assistant"), do: "experience"
  defp map_fact_type("experience"), do: "experience"
  defp map_fact_type(_other), do: "experience"

  # Only datable events carry occurred_* ; conversation facts leave them nil so the
  # parent's occurred_at (if any) does not spuriously anchor a non-event fact.
  #
  # Mirror Hindsight's occurred-date fallbacks (fact_extraction.py ~L1122-1136).
  # When the LLM omits occurred_start, infer it from a relative expression in the
  # assembled fact text against the parent's event date (`_infer_temporal_date`,
  # py ~L29-65). When occurred_end is absent but a start exists, default it to the
  # start (point event).
  defp occurred_dates(%{"fact_kind" => "event"} = fact, parent, text) do
    start =
      normalize_date(fact["occurred_start"]) || infer_temporal_date(text, event_date(parent))

    finish = normalize_date(fact["occurred_end"]) || start
    {start, finish}
  end

  defp occurred_dates(_fact, _parent, _text), do: {nil, nil}

  defp put_occurred_at(item, %{"fact_kind" => "event"}, occurred_start) do
    Map.put(item, "occurred_at", occurred_start || item["occurred_at"])
  end

  defp put_occurred_at(item, _fact, _occurred_start), do: Map.drop(item, ["occurred_at"])

  defp event_date(item), do: item["mentioned_at"] || item["occurred_at"] || item["occurred_start"]

  # Port of `_infer_temporal_date` (py ~L29-65). Map a relative time expression
  # found in the fact text to a day offset, resolve it against the event date at
  # 00:00:00, and serialise. First match wins (Python iterates an ordered dict);
  # no match or no event date → nil. Patterns are matched case-insensitively.
  # Resolve against the event date's WALL-CLOCK date and keep
  # its UTC offset, matching Hindsight (`event_date + timedelta`, offset preserved).
  # `DateTime.from_iso8601/1` normalises to a UTC instant, so using its date
  # directly can land a full day off for a non-zero offset — shift back by the
  # offset first, then re-attach it on output.
  @temporal_patterns [
    {~r/\blast night\b/, -1},
    {~r/\byesterday\b/, -1},
    {~r/\btoday\b/, 0},
    {~r/\bthis morning\b/, 0},
    {~r/\bthis afternoon\b/, 0},
    {~r/\bthis evening\b/, 0},
    {~r/\btonigh?t\b/, 0},
    {~r/\btomorrow\b/, 1},
    {~r/\blast week\b/, -7},
    {~r/\bthis week\b/, 0},
    {~r/\bnext week\b/, 7},
    {~r/\blast month\b/, -30},
    {~r/\bthis month\b/, 0},
    {~r/\bnext month\b/, 30}
  ]

  defp infer_temporal_date(_text, nil), do: nil

  defp infer_temporal_date(text, event_date) when is_binary(text) do
    with base when is_binary(base) <- normalize_date(event_date),
         {:ok, dt, offset_s} <- DateTime.from_iso8601(base) do
      fact_lower = String.downcase(text)

      case Enum.find(@temporal_patterns, fn {re, _} -> Regex.match?(re, fact_lower) end) do
        {_re, offset_days} ->
          local_date =
            dt
            |> DateTime.add(offset_s, :second)
            |> DateTime.to_date()
            |> Date.add(offset_days)

          Date.to_iso8601(local_date) <> "T00:00:00" <> format_offset(offset_s)

        nil ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp infer_temporal_date(_text, _event_date), do: nil

  # Serialise a UTC offset (seconds) as an ISO-8601 suffix: 0 → "Z", else ±HH:MM.
  defp format_offset(0), do: "Z"

  defp format_offset(seconds) when is_integer(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    abs_s = abs(seconds)
    hh = abs_s |> div(3600) |> Integer.to_string() |> String.pad_leading(2, "0")
    mm = abs_s |> rem(3600) |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{sign}#{hh}:#{mm}"
  end

  defp normalize_date(nil), do: nil
  defp normalize_date(""), do: nil
  defp normalize_date("N/A"), do: nil
  defp normalize_date("n/a"), do: nil

  defp normalize_date(value) when is_binary(value) do
    # The extractor commonly emits date-only values ("2024-03-01"); the retain
    # pipeline's parse_datetime requires a full ISO-8601 datetime and would drop
    # them, losing the event's occurred date. Coerce a bare date to start-of-day
    # UTC so it persists; pass through anything already datetime-shaped.
    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value) do
      value <> "T00:00:00Z"
    else
      value
    end
  end

  defp normalize_date(_other), do: nil

  # Chunking. DEFAULT_RETAIN_CHUNK_SIZE = 3000 (Hindsight config.py:570).
  # Overridable via app config for parity with HINDSIGHT_API_RETAIN_CHUNK_SIZE.
  @default_chunk_size 3000

  # Recursive-split separators, in priority order — paragraph, line, sentence,
  # clause, word, character (last resort). Faithful to Hindsight's
  # RecursiveCharacterTextSplitter separator list (fact_extraction.py ~L399-409).
  @chunk_separators ["\n\n", "\n", ". ", "! ", "? ", "; ", ", ", " ", ""]

  defp chunk_size(opts) do
    opts[:chunk_size] || Application.get_env(:foresight, :retain_chunk_size, @default_chunk_size)
  end

  # Port of Hindsight `chunk_text` (fact_extraction.py ~L364-412): short input →
  # one chunk; a JSON array of turn dicts → chunk at turn boundaries; otherwise the
  # recursive sentence-aware text splitter.
  defp chunk_text(text, max_chars) do
    if String.length(text) <= max_chars do
      [text]
    else
      case parse_conversation(text) do
        {:ok, turns} -> chunk_conversation(turns, max_chars)
        :error -> split_text(text, max_chars)
      end
    end
  end

  defp parse_conversation(text) do
    case Jason.decode(text) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_map/1), do: {:ok, list}, else: :error

      _ ->
        :error
    end
  end

  # Port of `_chunk_conversation` (py ~L415-450): accumulate whole turns until the
  # next would overflow max_chars, then start a new chunk. Each chunk is a
  # JSON-serialised list of complete turns; never splits mid-turn.
  defp chunk_conversation(turns, max_chars) do
    {chunks, current, _size} =
      Enum.reduce(turns, {[], [], 2}, fn turn, {chunks, current, size} ->
        turn_size = String.length(Jason.encode!(turn)) + 1

        {chunks, current, size} =
          if size + turn_size > max_chars and current != [] do
            {[encode_turns(current) | chunks], [], 2}
          else
            {chunks, current, size}
          end

        {chunks, current ++ [turn], size + turn_size}
      end)

    chunks = if current != [], do: [encode_turns(current) | chunks], else: chunks

    case Enum.reverse(chunks) do
      [] -> [encode_turns(turns)]
      list -> list
    end
  end

  defp encode_turns(turns), do: Jason.encode!(turns)

  # Recursive sentence-aware splitter mirroring the STRATEGY of langchain's
  # RecursiveCharacterTextSplitter (chunk_overlap = 0): pick the highest-priority
  # separator present in the text, split on it (retaining the separator so joined
  # chunks reconstruct the input — no content, and thus no facts, are lost), greedily
  # merge adjacent pieces under max_chars, and recurse into any oversized piece with
  # the remaining separators. It does not replicate langchain's separator
  # re-attachment/overlap internals (moot at overlap 0); chunk boundaries may differ
  # by a separator but every chunk stays under max_chars and order is preserved.
  defp split_text(text, max_chars), do: recursive_split(text, @chunk_separators, max_chars)

  defp recursive_split(text, separators, max_chars) do
    {sep, rest} = choose_separator(text, separators)

    text
    |> split_keep(sep)
    |> merge_pieces(rest, max_chars)
  end

  defp choose_separator(text, separators) do
    case Enum.drop_while(separators, fn s -> s != "" and not String.contains?(text, s) end) do
      [sep | rest] -> {sep, rest}
      [] -> {"", []}
    end
  end

  # Last-resort character split (separator ""): no separator to retain.
  defp split_keep(text, ""), do: String.graphemes(text)

  # Split on `sep`, re-attaching it to every piece but the last so a join
  # reconstructs the original text.
  defp split_keep(text, sep) do
    parts = String.split(text, sep)
    last = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.map(fn {p, i} -> if i < last, do: p <> sep, else: p end)
    |> Enum.reject(&(&1 == ""))
  end

  defp merge_pieces(pieces, rest, max_chars) do
    {chunks, current} =
      Enum.reduce(pieces, {[], ""}, fn piece, {chunks, current} ->
        cond do
          # A piece that alone exceeds the budget: flush what we have, then split it
          # further with the remaining separators (or keep it if none are left).
          String.length(piece) > max_chars ->
            flushed = if current == "", do: chunks, else: chunks ++ [current]
            subchunks = if rest == [], do: [piece], else: recursive_split(piece, rest, max_chars)
            {flushed ++ subchunks, ""}

          # Adding this piece would overflow the current chunk: emit and start fresh.
          current != "" and String.length(current) + String.length(piece) > max_chars ->
            {chunks ++ [current], piece}

          true ->
            {chunks, current <> piece}
        end
      end)

    if current == "", do: chunks, else: chunks ++ [current]
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_other), do: true

  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
