defmodule Foresight.ML.PythonLocalWorker do
  @moduledoc false

  use GenServer

  @default_name __MODULE__
  @warmup_text "foresight warmup"

  def start_link(opts) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def dimension(opts \\ []) do
    call(:embedding_dimension, [], opts)
  end

  def embed(text, opts \\ []) when is_binary(text) do
    call(:embed, [text], opts)
  end

  def embed_many(texts, opts \\ []) when is_list(texts) do
    call(:embed_many, [texts], opts)
  end

  def rerank(query, candidates, opts \\ []) when is_binary(query) and is_list(candidates) do
    call(:rerank, [query, Enum.map(candidates, &Map.get(&1, "content", ""))], opts)
  end

  def warmup(opts \\ []) do
    call(:warmup, [], opts)
  end

  @doc """
  Extract a single explicit/absolute date from `query` via the Python `dateparser`
  layer (200+ languages, incl. Greek). `reference_iso` anchors relative expressions.
  Returns `{:ok, "YYYY-MM-DD"}`, `{:ok, nil}` (no date found), or `{:error, reason}`
  (e.g. `:ml_worker_unavailable` when no local ML worker is running — callers fall
  back to the native period analyzer). Call once per recall, never per candidate.
  """
  def analyze_query(query, reference_iso, opts \\ [])
      when is_binary(query) and is_binary(reference_iso) do
    call(:analyze_query, [query, reference_iso], opts)
  end

  @doc """
  Report the actual torch device each model loaded on (e.g. "mps:0", "cuda:0", "cpu"),
  so callers can verify GPU execution instead of assuming it.
  """
  def device_info(opts \\ []) do
    call(:device_info, [], opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    python_path =
      Keyword.get_lazy(opts, :python_path, fn ->
        Path.join(:code.priv_dir(:foresight), "python")
      end)

    python_executable =
      Keyword.get(opts, :python_executable) ||
        System.get_env("FORESIGHT_ML_PYTHON") ||
        "python3"

    start_opts = [
      {:python_path, to_charlist(python_path)},
      {:python, to_charlist(python_executable)}
    ]

    case :python.start(start_opts) do
      {:ok, python} ->
        state = %{
          python: python,
          embedder_model_id:
            Keyword.get(opts, :model_id, ml_config(:model_id) || "BAAI/bge-small-en-v1.5"),
          reranker_model_id:
            Keyword.get(
              opts,
              :reranker_model_id,
              ml_config(:reranker_model_id) || "cross-encoder/ms-marco-MiniLM-L-6-v2"
            ),
          force_cpu: Keyword.get(opts, :force_cpu, ml_config(:force_cpu, false)),
          trust_remote_code:
            Keyword.get(opts, :trust_remote_code, ml_config(:trust_remote_code, false))
        }

        case maybe_warmup_models(
               state,
               Keyword.get(opts, :preload_models, ml_config(:preload_models, false))
             ) do
          :ok -> {:ok, state}
          {:error, reason} -> {:stop, {:python_warmup_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:python_start_failed, reason}}
    end
  end

  @impl true
  def handle_call({action, args, overrides}, _from, state) do
    {:reply, invoke_python(action, args, Map.merge(state, overrides)), state}
  end

  @doc false
  # Per-call model selection. The embedding profile passes the bank's `embed_model`
  # as `:model_id` on every `dimension`/`embed`/`embed_many` call; a bank pinned to a
  # model other than the engine default must reach the Python worker with that
  # model, or `EmbeddingProfile.resolve` sees the engine dimension and rejects the
  # bank's `embedding_dim`. The worker state only supplies the defaults.
  @spec model_overrides(keyword()) :: %{
          optional(:embedder_model_id) => String.t(),
          optional(:reranker_model_id) => String.t()
        }
  def model_overrides(opts) when is_list(opts) do
    %{}
    |> maybe_override(:embedder_model_id, Keyword.get(opts, :model_id))
    |> maybe_override(:reranker_model_id, Keyword.get(opts, :reranker_model_id))
  end

  defp maybe_override(overrides, key, value) when is_binary(value) and value != "",
    do: Map.put(overrides, key, value)

  defp maybe_override(overrides, _key, _value), do: overrides

  @impl true
  def handle_info({:EXIT, port, reason}, %{python: port} = state) do
    # The Python port died. Stop so the supervisor restarts us with a fresh port,
    # and so terminate/2 reaps the OS process instead of orphaning it.
    {:stop, {:python_died, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{python: python}) when not is_nil(python) do
    :python.stop(python)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # The ML worker must be started by the supervision tree. We never lazily spawn one
  # here: an unsupervised, caller-linked worker would die with the request/job that
  # started it (killing an in-flight port), and would race the supervisor for the
  # registered name (a lost race exhausts restart intensity and takes the app down).
  defp call(action, args, opts) do
    name = Keyword.get(opts, :name, ml_config(:python_worker_name, @default_name))
    timeout = Keyword.get(opts, :timeout, 300_000)

    if Process.whereis(name) do
      GenServer.call(name, {action, args, model_overrides(opts)}, timeout)
    else
      {:error, :ml_worker_unavailable}
    end
  end

  defp to_python_term(value) when is_list(value), do: Enum.map(value, &to_python_term/1)
  defp to_python_term(value), do: value

  defp maybe_warmup_models(_state, false), do: :ok

  defp maybe_warmup_models(state, true) do
    with {:ok, _dimension} <- invoke_python(:embedding_dimension, [], state),
         {:ok, _scores} <- invoke_python(:rerank, [@warmup_text, [@warmup_text]], state),
         {:ok, _token_count} <- Foresight.Budget.count_tokens(@warmup_text) do
      :ok
    end
  end

  defp invoke_python(action, args, state) do
    try do
      state.python
      |> :python.call(
        :sentence_transformers_worker,
        action,
        Enum.map(args, &to_python_term/1) ++
          [
            state.embedder_model_id,
            state.reranker_model_id,
            state.force_cpu,
            state.trust_remote_code
          ]
      )
      |> normalize_python_response()
    catch
      :exit, reason ->
        {:error, "Python ML worker exited: #{inspect(reason)}"}
    end
  end

  defp normalize_python_response({status, value}) when status in [:ok, "ok", ~c"ok"] do
    {:ok, normalize_python_value(value)}
  end

  defp normalize_python_response({status, reason})
       when status in [:error, "error", ~c"error"] do
    {:error, normalize_python_string(reason)}
  end

  defp normalize_python_response(other),
    do: {:error, "Unexpected Python ML response: #{inspect(other)}"}

  defp normalize_python_value(value) when is_list(value) do
    cond do
      Keyword.keyword?(value) ->
        Enum.into(value, %{}, fn {key, item} ->
          {normalize_python_key(key), normalize_python_value(item)}
        end)

      Enum.all?(value, &is_integer/1) ->
        List.to_string(value)

      true ->
        Enum.map(value, &normalize_python_value/1)
    end
  end

  defp normalize_python_value(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {normalize_python_key(key), normalize_python_value(item)}
    end)
  end

  defp normalize_python_value(value), do: value

  defp normalize_python_key(key) when is_binary(key), do: key
  defp normalize_python_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_python_key(key) when is_list(key), do: List.to_string(key)
  defp normalize_python_key(key), do: to_string(key)

  defp normalize_python_string(value) when is_binary(value), do: value
  defp normalize_python_string(value) when is_list(value), do: List.to_string(value)
  defp normalize_python_string(value), do: to_string(value)

  defp ml_config(key, default \\ nil) do
    case Application.get_env(:foresight, :ml, []) do
      config when is_list(config) -> Keyword.get(config, key, default)
      config when is_map(config) -> Map.get(config, key, default)
      _other -> default
    end
  end
end
