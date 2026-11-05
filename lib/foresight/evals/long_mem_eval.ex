defmodule Foresight.Evals.LongMemEval do
  @moduledoc """
  Adapter for LongMemEval (ICLR 2025), an MIT-licensed benchmark for long-term agent
  memory. It maps almost one-to-one onto Foresight's differentiators: temporal reasoning,
  knowledge updates (supersession), multi-session reasoning, and abstention.

  Native format (per instance): `question`, `answer`, `question_type`, `question_date`,
  `haystack_session_ids` + `haystack_dates` + `haystack_sessions` (each session a list of
  {role, content} turns, evidence turns flagged `has_answer`), and `answer_session_ids`
  (the gold evidence sessions ⊆ haystack). Abstention instances have a `_abs` question_id.

  Retrieval unit is the **session**: each haystack session becomes one retain-ready memory
  keyed by its session id, and `relevance` labels a session 1 iff it is an answer session.
  Session granularity matches the gold `answer_session_ids`; turn-level `has_answer` flags
  are preserved in metadata for a finer labelling pass later.

  Data is NOT vendored (we do not redistribute the corpus). Fetch a split with
  `mix foresight.evals.fetch` into `priv/evals/data/` (gitignored), then `load/1` it.
  """

  alias Foresight.Evals.Dataset

  @doc """
  Load and normalise a LongMemEval split from a JSON file path into `Dataset.Instance`s.

  Options:
    * `:limit` — take at most N instances (after optional sampling).
    * `:types` — keep only these `question_type`s.
  """
  @spec load(String.t(), keyword()) :: {:ok, [Dataset.t()]} | {:error, term()}
  def load(path, opts \\ []) do
    with {:ok, body} <- File.read(path),
         {:ok, raw} <- Jason.decode(body) do
      instances =
        raw
        |> maybe_filter_types(Keyword.get(opts, :types))
        |> maybe_limit(Keyword.get(opts, :limit))
        |> Enum.map(&to_instance/1)

      {:ok, instances}
    end
  end

  @doc "Same as `load/2` but raises on error."
  @spec load!(String.t(), keyword()) :: [Dataset.t()]
  def load!(path, opts \\ []) do
    case load(path, opts) do
      {:ok, instances} -> instances
      {:error, reason} -> raise "failed to load LongMemEval from #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Normalise a single raw LongMemEval instance (a decoded map) into a `Dataset.Instance`.
  Public so the loader can be unit-tested against a synthetic instance without shipping any
  of the copyrighted corpus.
  """
  @spec to_instance(map()) :: Dataset.t()
  def to_instance(raw) do
    session_ids = raw["haystack_session_ids"] || []
    sessions = raw["haystack_sessions"] || []
    dates = raw["haystack_dates"] || []
    answer_ids = MapSet.new(raw["answer_session_ids"] || [])

    memories =
      [session_ids, sessions, pad(dates, length(session_ids))]
      |> Enum.zip()
      |> Enum.map(fn {sid, turns, date} -> session_memory(sid, turns, date) end)
      |> Dataset.label_memories()

    relevance =
      for sid <- session_ids,
          into: %{},
          do: {sid, if(MapSet.member?(answer_ids, sid), do: 1, else: 0)}

    %Dataset{
      id: raw["question_id"],
      query: raw["question"],
      query_timestamp: normalize_date(raw["question_date"]),
      question_type: raw["question_type"],
      memories: memories,
      relevance: relevance,
      reference_answer: raw["answer"],
      abstention?: String.ends_with?(to_string(raw["question_id"]), "_abs")
    }
  end

  defp session_memory(session_id, turns, date) do
    turns = List.wrap(turns)

    content =
      turns
      |> Enum.map(fn t -> "#{t["role"]}: #{t["content"]}" end)
      |> Enum.join("\n")

    has_answer_turns =
      turns
      |> Enum.with_index()
      |> Enum.filter(fn {t, _i} -> t["has_answer"] == true end)
      |> Enum.map(fn {_t, i} -> i end)

    %{
      "id" => session_id,
      "content" => content,
      "context" => "chat",
      "mentioned_at" => normalize_date(date),
      "tags" => ["source:longmemeval"],
      "metadata" => %{"has_answer_turns" => has_answer_turns}
    }
  end

  defp maybe_filter_types(instances, nil), do: instances

  defp maybe_filter_types(instances, types) do
    keep = MapSet.new(types)
    Enum.filter(instances, &MapSet.member?(keep, &1["question_type"]))
  end

  defp maybe_limit(instances, nil), do: instances
  defp maybe_limit(instances, n) when is_integer(n), do: Enum.take(instances, n)

  # LongMemEval dates look like "2023/04/10 (Mon) 23:07"; normalise to ISO8601 UTC so the
  # recall recency/temporal signals can parse them. Best-effort: unparseable → passed through.
  defp normalize_date(nil), do: nil

  defp normalize_date(date) when is_binary(date) do
    case Regex.run(~r"(\d{4})/(\d{2})/(\d{2}).*?(\d{2}):(\d{2})", date) do
      [_, y, mo, d, h, mi] -> "#{y}-#{mo}-#{d}T#{h}:#{mi}:00Z"
      _ -> date
    end
  end

  defp pad(list, n) do
    list ++ List.duplicate(nil, max(n - length(list), 0))
  end
end
