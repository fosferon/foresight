# This adapter pattern-matches %LlmCore.LLM.Response{} and %LlmCore.LLM.Error{},
# which are compile-time references to an OPTIONAL dependency. Without this guard a
# consumer that does not want llm_core could not compile Foresight at all — the whole
# library failed on one adapter for a backend they had chosen not to use.
#
# Same shape as Foresight.MCP.Server: real module when the dependency is present, a
# stub that fails loudly and legibly when it is not. The stub matters — silently
# returning {:error, ...} would look like an LLM outage rather than a missing dep.
if Code.ensure_loaded?(LlmCore.LLM.Response) do
  defmodule Foresight.LLMs.LlmCore do
    @moduledoc false

    @behaviour Foresight.LLM
    @default_local_max_context 4_096
    @default_local_output_reserve 1_024

    alias Foresight.LLMs.StructuredRecovery
    alias LlmCore.LLM.Error, as: LlmError

    @impl true
    def complete_structured(prompt, messages, response_module, opts) do
      provider_opts =
        Keyword.merge(config(:provider_opts, []), Keyword.get(opts, :provider_opts, []))

      {provider, provider_opts} =
        resolve_provider_and_opts(
          Keyword.get(opts, :provider) || config(:provider) || llm_core_native(),
          provider_opts,
          {:json_schema, schema_for(response_module)}
        )

      prompt_input = if messages == [], do: prompt_messages(prompt), else: messages
      response_format = {:json_schema, schema_for(response_module)}
      provider_call_opts = Keyword.put(provider_opts, :response_format, response_format)

      with {:ok, dispatch_result} <- safe_dispatch(provider, prompt_input, provider_call_opts),
           {:ok, response} <- safe_process_response(provider, dispatch_result, response_format) do
        record_usage(response, provider, opts)
        {:ok, to_struct(response_module, response.structured)}
      else
        # A fenced/loose-JSON body (gpt-oss:20b wraps structured output in ```json)
        # would otherwise hard-fail every caller — including the reflect agentic loop,
        # which then aborts the whole reflect. Best-effort recover into the struct
        # (same fix retain/consolidation already have via the same fix); unrecoverable
        # errors (connection, non-JSON) fall through unchanged.
        {:error, reason} = error ->
          record_usage_error(provider, opts)

          case StructuredRecovery.recover_struct(reason, response_module) do
            {:ok, recovered} -> {:ok, recovered}
            :error -> error
          end
      end
    end

    # Every call is written to the operation's usage ledger (Foresight.Usage), a
    # no-op when the caller opened none. `:usage_role` names the pipeline stage
    # (extract, consolidate, ...) so consumers can attribute cost per stage.
    defp record_usage(response, _provider, opts) do
      Foresight.Usage.record(Foresight.Usage.llm_entry(response, Keyword.get(opts, :usage_role)))
    end

    defp record_usage_error(provider, opts) do
      Foresight.Usage.record(
        Foresight.Usage.llm_error_entry(provider, Keyword.get(opts, :usage_role))
      )
    end

    @impl true
    def complete_json_schema(prompt, messages, schema, opts) when is_map(schema) do
      provider_opts =
        Keyword.merge(config(:provider_opts, []), Keyword.get(opts, :provider_opts, []))

      {provider, provider_opts} =
        resolve_provider_and_opts(
          Keyword.get(opts, :provider) || config(:provider) || llm_core_native(),
          provider_opts,
          {:json_schema, schema}
        )

      prompt_input = if messages == [], do: prompt_messages(prompt), else: messages
      response_format = {:json_schema, schema}
      provider_call_opts = Keyword.put(provider_opts, :response_format, response_format)

      with {:ok, dispatch_result} <- safe_dispatch(provider, prompt_input, provider_call_opts),
           {:ok, response} <- safe_process_response(provider, dispatch_result, response_format) do
        record_usage(response, provider, opts)
        {:ok, response.structured}
      else
        {:error, _reason} = error ->
          record_usage_error(provider, opts)
          error
      end
    end

    @impl true
    def complete_with_tools(messages, opts) do
      provider_opts =
        Keyword.merge(config(:provider_opts, []), Keyword.get(opts, :provider_opts, []))

      # No response_format for tool-calling — keeps the real (OpenAI/Ollama)
      # provider instead of redirecting local base URLs to the structured-output
      # Appliance provider, which does not do tool-calling.
      {provider, provider_opts} =
        resolve_provider_and_opts(
          Keyword.get(opts, :provider) || config(:provider) || llm_core_native(),
          provider_opts,
          nil
        )

      provider_call_opts =
        provider_opts
        |> Keyword.put(:tools, Keyword.get(opts, :tools, []))
        |> maybe_put_opt(:tool_choice, opts[:tool_choice])
        |> maybe_put_opt(:max_tokens, opts[:max_tokens])

      case safe_dispatch(provider, messages, provider_call_opts) do
        {:ok, {:ok, %LlmCore.LLM.Response{} = response}} -> {:ok, response}
        {:ok, {:error, error}} -> {:error, error}
        {:error, error} -> {:error, error}
      end
    end

    defp maybe_put_opt(opts, _key, nil), do: opts
    defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

    def max_context_tokens(opts \\ []) do
      provider_opts =
        Keyword.merge(config(:provider_opts, []), Keyword.get(opts, :provider_opts, []))

      {provider, provider_opts} =
        resolve_provider_and_opts(
          Keyword.get(opts, :provider) || config(:provider) || llm_core_native(),
          provider_opts,
          :structured_output
        )

      provider_opts[:max_context] ||
        provider_capability(provider, :max_context) ||
        local_provider_fallback_max_context(provider)
    end

    def prompt_budget_tokens(opts \\ []) do
      provider_opts =
        Keyword.merge(config(:provider_opts, []), Keyword.get(opts, :provider_opts, []))

      {provider, provider_opts} =
        resolve_provider_and_opts(
          Keyword.get(opts, :provider) || config(:provider) || llm_core_native(),
          provider_opts,
          :structured_output
        )

      max_context_tokens =
        provider_opts[:max_context] ||
          provider_capability(provider, :max_context) ||
          local_provider_fallback_max_context(provider)

      output_reserve_tokens =
        Keyword.get(opts, :max_tokens) ||
          provider_opts[:max_tokens] ||
          local_provider_output_reserve(provider)

      case {max_context_tokens, output_reserve_tokens} do
        {max_context, reserve}
        when is_integer(max_context) and max_context > 0 and is_integer(reserve) and reserve > 0 ->
          max(max_context - reserve, div(max_context, 2))

        {max_context, _reserve} when is_integer(max_context) and max_context > 0 ->
          max_context

        _other ->
          nil
      end
    end

    defp prompt_messages(%{contract_version: "reflect.v1"} = prompt),
      do: Foresight.Prompts.Reflect.V1.messages(prompt)

    defp prompt_messages(%{contract_version: "reflect.plan.v1"} = prompt),
      do: Foresight.Prompts.Reflect.Plan.V1.messages(prompt)

    defp prompt_messages(prompt) when is_binary(prompt), do: prompt
    defp prompt_messages(prompt) when is_list(prompt), do: prompt
    defp prompt_messages(prompt), do: inspect(prompt)

    defp schema_for(Foresight.Prompts.ReflectResponse), do: Foresight.Prompts.Reflect.V1.schema()

    defp schema_for(Foresight.Prompts.ReflectPlanResponse),
      do: Foresight.Prompts.Reflect.Plan.V1.schema()

    defp schema_for(_module) do
      %{
        type: "object",
        additionalProperties: true
      }
    end

    defp config(key, default \\ nil) do
      Foresight.Config.get(:engine, key, default)
    end

    defp resolve_provider_and_opts(provider, provider_opts, response_format) do
      provider = normalize_provider(provider, llm_core_native())
      provider = maybe_redirect_local_openai(provider, provider_opts, response_format)
      provider_opts = normalize_provider_opts(provider, provider_opts, response_format)

      {provider, provider_opts}
    end

    defp normalize_provider(nil, default), do: normalize_provider(default, llm_core_native())

    defp normalize_provider(provider, _default) when is_atom(provider), do: provider

    defp normalize_provider(provider, default) when is_binary(provider) do
      case provider do
        "native" ->
          :"Elixir.LlmCore.LLM.Native"

        "openai" ->
          :"Elixir.LlmCore.LLM.OpenAI"

        "ollama" ->
          :"Elixir.LlmCore.LLM.Ollama"

        "appliance" ->
          :"Elixir.LlmCore.LLM.Appliance"

        provider_name ->
          provider_name |> Macro.camelize() |> then(&Module.concat(LlmCore.LLM, &1))
      end
      |> ensure_loaded_provider(default)
    end

    defp normalize_provider(provider, _default), do: provider

    defp ensure_loaded_provider(provider, default) when is_atom(provider) do
      if Code.ensure_loaded?(provider), do: provider, else: default
    end

    defp normalize_provider_opts(provider, provider_opts, _response_format)
         when provider in [:"Elixir.LlmCore.LLM.Appliance", LlmCore.LLM.Appliance] do
      Keyword.update(provider_opts, :base_url, nil, &strip_v1_suffix/1)
    end

    defp normalize_provider_opts(_provider, provider_opts, _response_format), do: provider_opts

    defp maybe_redirect_local_openai(provider, provider_opts, response_format)
         when provider in [:"Elixir.LlmCore.LLM.OpenAI", LlmCore.LLM.OpenAI] and
                not is_nil(response_format) do
      if local_openai_compatible_base_url?(provider_opts[:base_url]) do
        :"Elixir.LlmCore.LLM.Appliance"
      else
        provider
      end
    end

    defp maybe_redirect_local_openai(provider, _provider_opts, _response_format), do: provider

    defp local_openai_compatible_base_url?(base_url) when is_binary(base_url) do
      case URI.parse(base_url) do
        %URI{host: host} when host in ["127.0.0.1", "localhost"] -> true
        _other -> false
      end
    end

    defp local_openai_compatible_base_url?(_base_url), do: false

    defp strip_v1_suffix(base_url) when is_binary(base_url) do
      String.replace_suffix(base_url, "/v1", "")
    end

    defp strip_v1_suffix(base_url), do: base_url

    defp provider_capability(provider, capability) do
      if function_exported?(provider, :capabilities, 0) do
        provider.capabilities()
        |> Map.get(capability)
      end
    end

    defp local_provider_fallback_max_context(provider) do
      if function_exported?(provider, :provider_type, 0) and provider.provider_type() == :local do
        @default_local_max_context
      end
    end

    defp local_provider_output_reserve(provider) do
      if function_exported?(provider, :provider_type, 0) and provider.provider_type() == :local do
        Application.get_env(:llm_core, :appliance_max_tokens, @default_local_output_reserve)
      end
    end

    defp to_struct(module, %{} = value) do
      allowed_keys = module.__struct__() |> Map.keys() |> Enum.reject(&(&1 == :__struct__))

      attrs =
        Enum.reduce(allowed_keys, %{}, fn key, acc ->
          string_key = Atom.to_string(key)

          case Map.fetch(value, string_key) do
            {:ok, field_value} -> Map.put(acc, key, field_value)
            :error -> acc
          end
        end)

      struct(module, attrs)
    end

    defp llm_core_native, do: :"Elixir.LlmCore.LLM.Native"
    defp provider_module, do: :"Elixir.LlmCore.LLM.Provider"
    defp structured_module, do: :"Elixir.LlmCore.Structured"

    defp safe_dispatch(provider, prompt_input, provider_opts) do
      {:ok,
       apply(provider_module(), :dispatch, [
         provider,
         prompt_input,
         provider_opts
       ])}
    rescue
      error ->
        {:error, provider_dispatch_error(provider, error, __STACKTRACE__)}
    catch
      kind, reason ->
        {:error, provider_dispatch_error(provider, {kind, reason}, __STACKTRACE__)}
    end

    defp safe_process_response(provider, dispatch_result, response_format) do
      apply(structured_module(), :process, [dispatch_result, response_format])
    rescue
      error ->
        {:error, provider_dispatch_error(provider, error, __STACKTRACE__)}
    catch
      kind, reason ->
        {:error, provider_dispatch_error(provider, {kind, reason}, __STACKTRACE__)}
    end

    defp provider_dispatch_error(provider, %_{} = error, stacktrace) do
      LlmError.new(:provider_error,
        message: Exception.message(error),
        provider: provider,
        details: %{
          error: inspect(error.__struct__),
          stacktrace: Exception.format_stacktrace(stacktrace)
        }
      )
    end

    defp provider_dispatch_error(provider, reason, stacktrace) do
      LlmError.new(:provider_error,
        message: inspect(reason),
        provider: provider,
        details: %{
          stacktrace: Exception.format_stacktrace(stacktrace)
        }
      )
    end
  end
else
  defmodule Foresight.LLMs.LlmCore do
    @moduledoc false

    @behaviour Foresight.LLM

    @message "Foresight.LLMs.LlmCore requires the optional :llm_core dependency. " <>
               "Add {:llm_core, \">= 0.5.0\"} to your deps, or configure a different " <>
               "engine[:llm] module."

    @impl true
    def complete_structured(_prompt, _messages, _response_module, _opts),
      do: {:error, Foresight.Error.new(:unavailable, %{message: @message})}

    @impl true
    def complete_json_schema(_prompt, _messages, _schema, _opts),
      do: {:error, Foresight.Error.new(:unavailable, %{message: @message})}

    # complete_with_tools is deliberately NOT defined. It is an optional callback, and
    # Foresight.LLM.supports_tool_calling?/1 dispatches on function_exported?/2 — so
    # omitting it makes reflect fall back to the fixed pipeline rather than attempt an
    # agentic loop against a backend that is not installed.
  end
end
