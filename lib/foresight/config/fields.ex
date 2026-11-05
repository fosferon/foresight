defmodule Foresight.Config.Fields do
  @moduledoc false

  @env_prefix "HINDSIGHT_API_"

  @defaults %{
    "embed_model" => nil,
    "embedding_dim" => nil,
    "llm_gemini_safety_settings" => nil,
    "mcp_enabled_tools" => nil,
    "native_language" => nil,
    "retain_chunk_size" => 3000,
    "retain_extraction_mode" => "concise",
    "retain_mission" => nil,
    "retain_custom_instructions" => nil,
    "retain_default_strategy" => nil,
    "retain_strategies" => nil,
    "retain_chunk_batch_size" => 100,
    "enable_observations" => true,
    "consolidation_max_memories_per_round" => 100,
    "consolidation_llm_batch_size" => 8,
    "consolidation_source_facts_max_tokens" => 4096,
    "consolidation_source_facts_max_tokens_per_observation" => 256,
    "observations_mission" => nil,
    "max_observations_per_scope" => -1,
    "entity_labels" => nil,
    "entities_allow_free_form" => true,
    "reflect_mission" => nil,
    "reflect_source_facts_max_tokens" => -1,
    "recall_include_chunks" => true,
    "recall_max_tokens" => 2048,
    "recall_chunks_max_tokens" => 1000,
    "recall_rerank_window" => nil,
    # Cosine-similarity floor for the semantic arm; nil/invalid falls back to 0.3.
    "recall_semantic_floor" => 0.3,
    "recall_budget_function" => "fixed",
    "recall_budget_fixed_low" => 100,
    "recall_budget_fixed_mid" => 300,
    "recall_budget_fixed_high" => 1000,
    "recall_budget_adaptive_low" => 0.025,
    "recall_budget_adaptive_mid" => 0.075,
    "recall_budget_adaptive_high" => 0.25,
    "recall_budget_min" => 20,
    "recall_budget_max" => 2000,
    # Per-bank learned fusion parameters (mode/normalization/weights/…).
    # nil means "use the global :recall_fusion config", i.e. today's behaviour.
    "recall_fusion" => nil,
    "disposition_skepticism" => nil,
    "disposition_literalism" => nil,
    "disposition_empathy" => nil
  }

  @additional_configurable_fields ~w(
    default_bank_template
    llm_provider
    llm_model
    llm_base_url
    llm_api_key
    llm_extract_provider
    llm_extract_model
    llm_extract_base_url
    llm_extract_api_key
    llm_reflect_provider
    llm_reflect_model
    llm_reflect_base_url
    llm_reflect_api_key
    llm_judge_provider
    llm_judge_model
    llm_judge_base_url
    llm_judge_api_key
  )

  @configurable_fields @defaults
                       |> Map.keys()
                       |> Kernel.++(@additional_configurable_fields)
                       |> MapSet.new()

  @credential_fields MapSet.new(~w(
    llm_api_key
    llm_extract_api_key
    llm_reflect_api_key
    llm_judge_api_key
  ))

  @redacted_value "[REDACTED]"

  @spec defaults() :: map()
  def defaults, do: @defaults

  @spec configurable_fields() :: [String.t()]
  def configurable_fields do
    @configurable_fields
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @spec credential_fields() :: [String.t()]
  def credential_fields do
    @credential_fields
    |> MapSet.to_list()
    |> Enum.sort()
  end

  @spec redact_credentials(map()) :: map()
  def redact_credentials(layer) when is_map(layer) do
    layer
    |> normalize_layer()
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if MapSet.member?(@credential_fields, key) and not is_nil(value) do
        Map.put(acc, key, @redacted_value)
      else
        Map.put(acc, key, value)
      end
    end)
  end

  def redact_credentials(layer), do: layer

  @spec normalize_updates(map()) :: {:ok, map()} | {:error, [String.t()]}
  def normalize_updates(updates) when is_map(updates) do
    Enum.reduce(updates, {:ok, %{}, []}, fn {key, value}, {:ok, normalized, unknowns} ->
      field = normalize_field_name(key)

      if MapSet.member?(@configurable_fields, field) do
        {:ok, Map.put(normalized, field, value), unknowns}
      else
        {:ok, normalized, [field | unknowns]}
      end
    end)
    |> case do
      {:ok, normalized, []} -> {:ok, normalized}
      {:ok, _normalized, unknowns} -> {:error, Enum.sort(Enum.uniq(unknowns))}
    end
  end

  def normalize_updates(_updates), do: {:error, ["updates"]}

  @spec normalize_layer(term()) :: map()
  def normalize_layer(layer) when is_map(layer) do
    layer
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, normalize_field_name(key), value)
    end)
  end

  def normalize_layer(_layer), do: %{}

  defp normalize_field_name(key) when is_atom(key),
    do: key |> Atom.to_string() |> normalize_field_name()

  defp normalize_field_name(key) when is_binary(key) do
    key
    |> String.trim()
    |> strip_env_prefix()
    |> String.downcase()
  end

  defp normalize_field_name(key), do: key |> to_string() |> normalize_field_name()

  defp strip_env_prefix(key) do
    if String.starts_with?(key, @env_prefix) do
      key
      |> String.trim_leading(@env_prefix)
    else
      key
    end
  end
end
