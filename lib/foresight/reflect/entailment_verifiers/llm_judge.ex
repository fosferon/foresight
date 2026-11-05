defmodule Foresight.Reflect.EntailmentVerifiers.LLMJudge do
  @moduledoc """
  LLM-judge entailment verifier. One structured call over the existing LLM
  routing decides, for each answer clause, whether the cited-memory text supports it — no
  new model or serving. Reuses the `complete_json_schema/4` seam.

  Faithful to the pipeline's LlmCore isolation, it DEGRADES to all-supported when the LLM
  is absent/incapable, on any error, timeout, or malformed result: a broken verifier must
  never block a reflect answer. Likewise a clause the model omits defaults to supported.
  """

  @behaviour Foresight.Reflect.EntailmentVerifier

  alias Foresight.LLMs.StructuredRecovery

  require Logger

  @temperature 0.0
  @max_tokens 1024

  @impl true
  def verify([], _evidence, _opts), do: []

  def verify(clauses, evidence, opts) when is_list(clauses) do
    llm = opts[:llm]

    supported_by_index =
      if capable?(llm) do
        judge(llm, clauses, evidence, opts)
      else
        %{}
      end

    clauses
    |> Enum.with_index()
    |> Enum.map(fn {clause, index} ->
      # Default missing/erroring judgements to supported (degrade-safe).
      supported? = Map.get(supported_by_index, index, true)
      %{clause: clause, supported?: supported?, score: if(supported?, do: 1.0, else: 0.0)}
    end)
  end

  # Mirrors `Retain.FactExtraction.extractable?/1`.
  defp capable?(llm) do
    is_atom(llm) and not is_nil(llm) and Code.ensure_loaded?(llm) and
      function_exported?(llm, :complete_json_schema, 4)
  end

  # Returns a %{index => supported?} map; empty map on any failure (→ all default to
  # supported in the caller).
  defp judge(llm, clauses, evidence, opts) do
    prompt = %{query: "reflect.entailment", clauses: length(clauses)}

    case llm.complete_json_schema(prompt, messages(clauses, evidence), schema(), llm_opts(opts)) do
      {:ok, %{"verdicts" => verdicts}} when is_list(verdicts) ->
        index_map(verdicts)

      {:ok, _other} ->
        %{}

      {:error, reason} ->
        case StructuredRecovery.recover(reason) do
          {:ok, %{"verdicts" => verdicts}} when is_list(verdicts) ->
            index_map(verdicts)

          _ ->
            Logger.warning(
              "entailment LLM-judge failed; treating clauses as supported: #{inspect(reason)}"
            )

            %{}
        end
    end
  rescue
    error ->
      Logger.warning(
        "entailment LLM-judge crashed; treating clauses as supported: #{inspect(error)}"
      )

      %{}
  catch
    :exit, reason ->
      Logger.warning(
        "entailment LLM-judge exited; treating clauses as supported: #{inspect(reason)}"
      )

      %{}
  end

  defp index_map(verdicts) do
    for v <- verdicts, is_map(v), is_integer(index = v["index"]), into: %{} do
      {index, v["supported"] == true}
    end
  end

  defp messages(clauses, evidence) do
    numbered =
      clauses
      |> Enum.with_index()
      |> Enum.map(fn {c, i} -> "#{i}. #{c}" end)
      |> Enum.join("\n")

    ev =
      if evidence == [],
        do: "(no evidence was cited)",
        else: Enum.map_join(evidence, "\n", &"- #{&1}")

    system =
      "You verify grounding. Given EVIDENCE (cited memories) and a numbered list of " <>
        "answer CLAUSES, decide for each clause whether the evidence SUPPORTS it. A clause " <>
        "is supported only if the evidence directly entails it; a clause that is " <>
        "contradicted by, or merely topically related to but not stated in, the evidence is " <>
        "NOT supported. Respond as JSON {\"verdicts\": [{\"index\": <n>, \"supported\": " <>
        "<true|false>}, ...]} with one entry per clause index."

    user = "EVIDENCE:\n" <> ev <> "\n\nCLAUSES:\n" <> numbered

    [%{role: :system, content: system}, %{role: :user, content: user}]
  end

  defp schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["verdicts"],
      "properties" => %{
        "verdicts" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["index", "supported"],
            "properties" => %{
              "index" => %{"type" => "integer"},
              "supported" => %{"type" => "boolean"}
            }
          }
        }
      }
    }
  end

  # Route to a verifier LLM role/provider if configured; inject low-temp defaults. Mirrors
  # the provider-opts handling in `Retain.FactExtraction.llm_opts/1`.
  defp llm_opts(opts) do
    provider_opts =
      (opts[:provider_opts] || [])
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
