defmodule Foresight.BankTemplate.Schema do
  @moduledoc false

  @spec manifest() :: map()
  def manifest do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "title" => "BankTemplateManifest",
      "description" =>
        "A bank template manifest for import/export. Mirrors the live Hindsight v1 template surface.",
      "type" => "object",
      "required" => ["version"],
      "properties" => %{
        "version" => %{
          "type" => "string",
          "description" => "Manifest schema version (currently '1')"
        },
        "bank" => nullable_ref("#/$defs/BankTemplateConfig", "Bank configuration to apply."),
        "mental_models" =>
          nullable_array_ref(
            "#/$defs/BankTemplateMentalModel",
            "Mental models to create or update (matched by id). Omit to leave unchanged."
          ),
        "directives" =>
          nullable_array_ref(
            "#/$defs/BankTemplateDirective",
            "Directives to create or update (matched by name). Omit to leave unchanged."
          )
      },
      "$defs" => %{
        "BankTemplateConfig" => bank_template_config(),
        "BankTemplateDirective" => bank_template_directive(),
        "BankTemplateMentalModel" => bank_template_mental_model(),
        "MentalModelTrigger" => mental_model_trigger(),
        "TagGroupLeaf" => tag_group_leaf(),
        "TagGroupAnd" => tag_group_node("and"),
        "TagGroupOr" => tag_group_node("or"),
        "TagGroupNot" => tag_group_not()
      }
    }
  end

  @spec template_config_field_names() :: [String.t()]
  def template_config_field_names do
    template_config_fields()
    |> Enum.map(fn {key, _schema, _description} -> key end)
  end

  defp bank_template_config do
    %{
      "type" => "object",
      "title" => "BankTemplateConfig",
      "description" =>
        "Bank configuration fields within a template manifest. Credential fields are intentionally excluded.",
      "properties" =>
        Map.new(template_config_fields(), fn {key, schema, description} ->
          {key, Map.put(schema, "description", description)}
        end)
    }
  end

  defp bank_template_directive do
    %{
      "type" => "object",
      "title" => "BankTemplateDirective",
      "description" =>
        "A directive definition within a bank template manifest. Directives are matched by name on re-import.",
      "required" => ["name", "content"],
      "properties" => %{
        "name" => %{"type" => "string", "description" => "Human-readable name for the directive"},
        "content" => %{
          "type" => "string",
          "description" => "The directive text to inject into prompts"
        },
        "priority" => %{
          "type" => "integer",
          "default" => 0,
          "description" => "Higher priority directives are injected first"
        },
        "is_active" => %{
          "type" => "boolean",
          "default" => true,
          "description" => "Whether this directive is active"
        },
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "default" => [],
          "description" => "Tags for filtering"
        }
      }
    }
  end

  defp bank_template_mental_model do
    %{
      "type" => "object",
      "title" => "BankTemplateMentalModel",
      "description" => "A mental model definition within a bank template manifest.",
      "required" => ["id", "name", "source_query"],
      "properties" => %{
        "id" => %{
          "type" => "string",
          "description" => "Unique ID for the mental model (alphanumeric lowercase with hyphens)"
        },
        "name" => %{
          "type" => "string",
          "description" => "Human-readable name for the mental model"
        },
        "source_query" => %{
          "type" => "string",
          "description" => "The query to run to generate content"
        },
        "tags" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "default" => [],
          "description" => "Tags for scoped visibility"
        },
        "max_tokens" => %{
          "type" => "integer",
          "minimum" => 256,
          "maximum" => 8192,
          "default" => 2048,
          "description" => "Maximum tokens for generated content"
        },
        "trigger" => %{
          "$ref" => "#/$defs/MentalModelTrigger",
          "default" => %{},
          "description" => "Trigger settings"
        }
      }
    }
  end

  defp mental_model_trigger do
    %{
      "type" => "object",
      "title" => "MentalModelTrigger",
      "description" => "Trigger settings for a mental model.",
      "properties" => %{
        "mode" => %{
          "type" => "string",
          "enum" => ["full", "delta"],
          "default" => "full",
          "description" => "Refresh mode."
        },
        "refresh_after_consolidation" => %{
          "type" => "boolean",
          "default" => false,
          "description" => "If true, refresh this mental model after observations consolidation."
        },
        "fact_types" =>
          nullable_schema(%{
            "type" => "array",
            "items" => %{"type" => "string", "enum" => ["world", "experience", "observation"]},
            "description" => "Filter which fact types are retrieved during refresh."
          }),
        "exclude_mental_models" => %{
          "type" => "boolean",
          "default" => false,
          "description" => "If true, exclude all mental models from the reflect loop."
        },
        "exclude_mental_model_ids" =>
          nullable_schema(%{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Exclude specific mental models by ID from the reflect loop."
          }),
        "tags_match" =>
          nullable_schema(%{
            "type" => "string",
            "enum" => ["any", "all", "any_strict", "all_strict"],
            "description" => "Override how the model's tags filter memories during refresh."
          }),
        "tag_groups" =>
          nullable_schema(%{
            "type" => "array",
            "items" => %{
              "oneOf" => [
                %{"$ref" => "#/$defs/TagGroupLeaf"},
                %{"$ref" => "#/$defs/TagGroupAnd"},
                %{"$ref" => "#/$defs/TagGroupOr"},
                %{"$ref" => "#/$defs/TagGroupNot"}
              ]
            },
            "description" => "Compound boolean tag expressions to use during refresh."
          }),
        "include_chunks" =>
          nullable_schema(%{
            "type" => "boolean",
            "description" => "Override whether refresh recall returns raw chunk text."
          }),
        "recall_max_tokens" =>
          nullable_schema(%{
            "type" => "integer",
            "description" => "Override the token budget for facts returned during refresh."
          }),
        "recall_chunks_max_tokens" =>
          nullable_schema(%{
            "type" => "integer",
            "description" => "Override the token budget for raw chunks returned during refresh."
          })
      }
    }
  end

  defp tag_group_leaf do
    %{
      "type" => "object",
      "required" => ["tag"],
      "properties" => %{
        "tag" => %{"type" => "string"}
      }
    }
  end

  defp tag_group_node(operator) do
    %{
      "type" => "object",
      "required" => [operator],
      "properties" => %{
        operator => %{
          "type" => "array",
          "items" => %{
            "oneOf" => [
              %{"$ref" => "#/$defs/TagGroupLeaf"},
              %{"$ref" => "#/$defs/TagGroupAnd"},
              %{"$ref" => "#/$defs/TagGroupOr"},
              %{"$ref" => "#/$defs/TagGroupNot"}
            ]
          }
        }
      }
    }
  end

  defp tag_group_not do
    %{
      "type" => "object",
      "required" => ["not"],
      "properties" => %{
        "not" => %{
          "oneOf" => [
            %{"$ref" => "#/$defs/TagGroupLeaf"},
            %{"$ref" => "#/$defs/TagGroupAnd"},
            %{"$ref" => "#/$defs/TagGroupOr"},
            %{"$ref" => "#/$defs/TagGroupNot"}
          ]
        }
      }
    }
  end

  defp template_config_fields do
    [
      {"reflect_mission", nullable_string(), "Mission/context for Reflect operations"},
      {"retain_mission", nullable_string(), "Steers what gets extracted during retain"},
      {"retain_extraction_mode", nullable_string(), "Fact extraction mode"},
      {"retain_custom_instructions", nullable_string(), "Custom extraction prompt"},
      {"retain_chunk_size", nullable_integer(), "Max token size for each content chunk"},
      {"enable_observations", nullable_boolean(), "Toggle observation consolidation"},
      {"observations_mission", nullable_string(), "Controls what gets synthesised"},
      {"disposition_skepticism", nullable_bounded_integer(1, 5), "Skepticism trait (1-5)"},
      {"disposition_literalism", nullable_bounded_integer(1, 5), "Literalism trait (1-5)"},
      {"disposition_empathy", nullable_bounded_integer(1, 5), "Empathy trait (1-5)"},
      {"entity_labels",
       nullable_schema(%{
         "type" => "array",
         "items" => %{"type" => "object", "additionalProperties" => true}
       }), "Controlled vocabulary for entity labels"},
      {"entities_allow_free_form", nullable_boolean(),
       "Allow entities outside the label vocabulary"},
      {"retain_default_strategy", nullable_string(), "Name of the default retain strategy"},
      {"retain_strategies",
       nullable_schema(%{"type" => "object", "additionalProperties" => true}),
       "Map of retain strategy name to per-strategy config dict"},
      {"retain_chunk_batch_size", nullable_integer(), "Max chunks per streaming batch"},
      {"mcp_enabled_tools",
       nullable_schema(%{"type" => "array", "items" => %{"type" => "string"}}),
       "MCP tool allowlist for this bank"},
      {"consolidation_llm_batch_size", nullable_integer(),
       "LLM batch size for observation consolidation"},
      {"consolidation_source_facts_max_tokens", nullable_integer(),
       "Max tokens of source facts per consolidation batch"},
      {"consolidation_source_facts_max_tokens_per_observation", nullable_integer(),
       "Max tokens of source facts per observation"},
      {"max_observations_per_scope", nullable_integer(),
       "Max observations to retain per consolidation scope"},
      {"reflect_source_facts_max_tokens", nullable_integer(),
       "Max tokens of source facts per reflect call"},
      {"recall_max_tokens", nullable_integer(), "Max tokens returned from recall"},
      {"recall_chunks_max_tokens", nullable_integer(), "Max tokens returned from chunk recall"},
      {"llm_gemini_safety_settings", nullable_schema(%{"type" => "array", "items" => %{}}),
       "Per-bank Gemini safety settings"},
      {"recall_budget_function", nullable_string(), "Recall budget mapping function"},
      {"recall_budget_fixed_low", nullable_integer(), "Fixed thinking budget for low"},
      {"recall_budget_fixed_mid", nullable_integer(), "Fixed thinking budget for mid"},
      {"recall_budget_fixed_high", nullable_integer(), "Fixed thinking budget for high"},
      {"recall_budget_adaptive_low", nullable_number(), "Adaptive ratio for low"},
      {"recall_budget_adaptive_mid", nullable_number(), "Adaptive ratio for mid"},
      {"recall_budget_adaptive_high", nullable_number(), "Adaptive ratio for high"},
      {"recall_budget_min", nullable_integer(), "Adaptive floor"},
      {"recall_budget_max", nullable_integer(), "Adaptive ceiling"}
    ]
  end

  defp nullable_ref(ref, description) do
    %{
      "anyOf" => [%{"$ref" => ref}, %{"type" => "null"}],
      "description" => description
    }
  end

  defp nullable_array_ref(ref, description) do
    nullable_schema(%{
      "type" => "array",
      "items" => %{"$ref" => ref},
      "description" => description
    })
  end

  defp nullable_string, do: nullable_schema(%{"type" => "string"})
  defp nullable_integer, do: nullable_schema(%{"type" => "integer"})
  defp nullable_boolean, do: nullable_schema(%{"type" => "boolean"})
  defp nullable_number, do: nullable_schema(%{"type" => "number"})

  defp nullable_bounded_integer(min, max) do
    nullable_schema(%{"type" => "integer", "minimum" => min, "maximum" => max})
  end

  defp nullable_schema(schema), do: %{"anyOf" => [schema, %{"type" => "null"}]}
end
