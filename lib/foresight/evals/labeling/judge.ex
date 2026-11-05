defmodule Foresight.Evals.Labeling.Judge do
  @moduledoc """
  Relevance-labeling pipeline, judge step: LLM graded-relevance judge. For each (query, candidate) pair it
  asks a `complete_json_schema/4`-capable LLM (default: z.ai GLM-5.2) for a 0..3 relevance
  grade, and emits `source: :llm` label attrs recording the judge model.

  Integrity contract: unlike the entity extractor, there is NO safe fallback grade — a
  fabricated default would bias the fusion-weight optimisation. So on an incapable/absent LLM, any error,
  an unparseable result, or a grade outside 0..3, the pair is SKIPPED and reported under
  `:errors` (with its `query_ref`/`memory_ref` and a reason), never labeled. The bulk pass
  therefore reports exactly what it graded and what it could not.

  The pair's `split` is preserved on the emitted label so a `:calibration` pair's llm row
  lines up with its human row for the Cohen's-kappa join. Structure + parsing are pure and
  fake-LLM testable; only the live call is paid.
  """

  alias Foresight.LLMs.StructuredRecovery

  require Logger

  @temperature 0.1
  @max_tokens 512
  @grade_scale 0..3

  # Rubric text is versioned because the version string is persisted into the label's
  # judge_model (`<model>@<rubric>`). A hardcoded prompt behind a version constant would
  # make that provenance a lie the first time the prompt was edited, so every version we
  # have ever graded against stays addressable and re-runnable here.
  @rubric_v1 """
  You are grading how relevant a stored memory is to answering a user's question, on a 0-3 \
  scale. 3 = directly answers or is essential; 2 = clearly relevant, partial support; \
  1 = tangentially/weakly related; 0 = irrelevant. Judge ONLY relevance to the question, \
  not correctness or writing quality. Respond as JSON \
  {"grade": <0-3 integer>, "reason": <short string>}.\
  """

  # v2 tightens the 0/1 and 1/2 boundaries after an independent review found the
  # judge awarding 1 for lexical-overlap-only rows and missing the multi-hop clause.
  @rubric_v2 """
  You are grading how relevant a stored memory is to answering a user's question.
  Apply these strict boundaries:
  - Grade 3 requires direct answer-bearing evidence sufficient to answer the question.
  - Grade 2 is meaningful partial support. In a count, temporal, comparison, or multi-hop
    question, one necessary step is grade 2 even when other memories are needed.
  - Grade 1 requires genuine engagement with the queried entity or topic and some weak
    contextual value, but supplies no necessary answer evidence.
  - Grade 0 supplies no answer-bearing evidence.
  - Lexical or topical overlap alone is grade 0. A wrong instance, analogy, or different
    problem is grade 0 even when it shares vocabulary. If your reason says the memory
    does not address the question, use grade 0 unless you can identify genuine contextual
    value.
  Judge only relevance, not factual correctness or writing quality. Choose the highest
  grade whose complete definition is satisfied. Respond as JSON
  {"grade": <0-3 integer>, "reason": <short string>}.\
  """

  @rubrics %{"relevance-v1" => @rubric_v1, "relevance-v2" => @rubric_v2}

  # v1 remains the default because v2 measured WORSE, not better. Judged with the same
  # model (gpt-oss:120b) against independent-agent grades on the 40-pair
  # calibration split, quadratic kappa fell on both lanes: public 0.8954 -> 0.8081,
  # professional 0.8656 -> 0.7834. Mechanism: the "one necessary step is grade 2" clause
  # mass-promotes 1s to 2s (professional grade-2 count 6 -> 13 against a reference of 5),
  # which costs more than the 1-for-lexical-overlap errors it was written to fix.
  # v2 is kept addressable so the finding stays reproducible. 
  @rubric_version "relevance-v1"

  @type pair :: %{
          required(:bank_id) => String.t(),
          required(:query_ref) => String.t(),
          required(:memory_ref) => String.t(),
          optional(atom()) => term()
        }
  @type result :: %{labels: [map()], errors: [map()]}

  @spec label_all([pair()], keyword()) :: result()
  def label_all(pairs, opts) do
    judge_model = Keyword.fetch!(opts, :judge_model)
    llm = opts[:llm]
    concurrency = Keyword.get(opts, :concurrency, 1)

    pairs
    |> label_pairs(llm, judge_model, opts, concurrency)
    |> Enum.reduce(%{labels: [], errors: []}, fn
      {:ok, attrs}, acc -> Map.update!(acc, :labels, &[attrs | &1])
      {:error, err}, acc -> Map.update!(acc, :errors, &[err | &1])
    end)
    |> Map.update!(:labels, &Enum.reverse/1)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  @doc "The rubric new runs grade against by default."
  def rubric_version, do: @rubric_version

  @doc "Every rubric version this judge can still grade against."
  def rubric_versions, do: Map.keys(@rubrics)

  defp rubric!(opts) do
    version = Keyword.get(opts, :rubric, @rubric_version)

    case Map.fetch(@rubrics, version) do
      {:ok, text} ->
        {version, text}

      :error ->
        raise ArgumentError,
              "unknown rubric #{inspect(version)}; known: #{inspect(rubric_versions())}"
    end
  end

  defp label_one_with_retry(pair, llm, judge_model, opts) do
    max_attempts = Keyword.get(opts, :max_attempts, 1)
    retry_sleep_ms = Keyword.get(opts, :retry_sleep_ms, 0)

    Enum.reduce_while(1..max_attempts, nil, fn attempt, _last_result ->
      case label_one(pair, llm, judge_model, opts) do
        {:ok, _attrs} = result ->
          {:halt, result}

        {:error, _error} = result when attempt < max_attempts ->
          if retry_sleep_ms > 0, do: Process.sleep(retry_sleep_ms)
          {:cont, result}

        {:error, _error} = result ->
          {:halt, result}
      end
    end)
  end

  defp label_one(pair, llm, judge_model, opts) do
    {rubric_version, _text} = rubric!(opts)

    with true <- capable?(llm) or {:error, error(pair, :llm_incapable)},
         {:ok, grade, reason} <- grade(llm, pair, judge_model, opts) do
      # Always derived from the rubric ACTUALLY sent. There is deliberately no caller
      # override: one existed, and it let a label claim a rubric version the LLM never
      # saw, which is precisely the reproducibility lie the version string exists to
      # prevent — a future reader would rerun under the named rubric and get other grades.
      label_model = "#{judge_model}@#{rubric_version}"

      {:ok,
       %{
         bank_id: pair.bank_id,
         query_ref: pair.query_ref,
         query_text: pair[:query_text],
         memory_ref: pair.memory_ref,
         grade: grade,
         source: :llm,
         split: pair[:split],
         judge_model: label_model,
         judge_reason: reason
       }}
    else
      {:error, %{} = err} -> {:error, err}
    end
  end

  defp grade(llm, pair, judge_model, opts) do
    prompt = %{query: "relevance.judge", content: pair[:content]}

    case safe_complete(llm, prompt, pair, judge_model, opts) do
      {:ok, %{"grade" => g, "reason" => reason}}
      when is_integer(g) and g in @grade_scale and is_binary(reason) and reason != "" ->
        {:ok, g, reason}

      {:ok, %{"grade" => g}} when is_integer(g) and g in @grade_scale ->
        {:error, error(pair, :missing_reason)}

      {:ok, %{"grade" => g}} when is_integer(g) ->
        {:error, error(pair, :grade_out_of_range)}

      {:ok, _other} ->
        {:error, error(pair, :unparseable_grade)}

      {:error, reason} ->
        {:error, error(pair, reason)}
    end
  end

  defp label_pairs(pairs, llm, judge_model, opts, concurrency) when concurrency > 1 do
    pairs
    |> Task.async_stream(&label_one_with_retry(&1, llm, judge_model, opts),
      max_concurrency: concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, %{reason: {:judge_task_exited, reason}}}
    end)
  end

  defp label_pairs(pairs, llm, judge_model, opts, _concurrency) do
    Enum.map(pairs, &label_one_with_retry(&1, llm, judge_model, opts))
  end

  defp safe_complete(llm, prompt, pair, judge_model, opts) do
    {_version, rubric} = rubric!(opts)

    llm.complete_json_schema(
      prompt,
      messages(pair, rubric),
      schema(),
      llm_opts(opts, judge_model)
    )
  rescue
    e ->
      Logger.warning("relevance judge crashed: #{inspect(e)}")
      {:error, :judge_crashed}
  catch
    :exit, reason ->
      Logger.warning("relevance judge exited: #{inspect(reason)}")
      {:error, :judge_exited}
  else
    {:ok, map} when is_map(map) ->
      {:ok, map}

    {:error, reason} ->
      case StructuredRecovery.recover(reason) do
        {:ok, %{"grade" => _} = map} -> {:ok, map}
        _ -> {:error, reason}
      end
  end

  defp capable?(llm) do
    is_atom(llm) and not is_nil(llm) and Code.ensure_loaded?(llm) and
      function_exported?(llm, :complete_json_schema, 4)
  end

  defp error(pair, reason) do
    %{query_ref: pair.query_ref, memory_ref: pair.memory_ref, reason: reason}
  end

  defp messages(pair, system) do
    user = "Question:\n#{pair[:query_text]}\n\nStored memory:\n#{pair[:content]}"

    [%{role: :system, content: String.trim(system)}, %{role: :user, content: user}]
  end

  defp schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["grade", "reason"],
      "properties" => %{
        "grade" => %{"type" => "integer", "minimum" => 0, "maximum" => 3},
        "reason" => %{"type" => "string"}
      }
    }
  end

  defp llm_opts(opts, judge_model) do
    provider_opts =
      (opts[:provider_opts] || [])
      |> Keyword.put(:model, judge_model)
      |> put_default(:temperature, @temperature)
      |> put_default(:max_tokens, @max_tokens)

    opts
    |> Keyword.take([:provider, :sleep_ms])
    |> Keyword.put(:provider_opts, provider_opts)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp put_default(kw, key, default) do
    case Keyword.get(kw, key) do
      nil -> Keyword.put(kw, key, default)
      _present -> kw
    end
  end
end
