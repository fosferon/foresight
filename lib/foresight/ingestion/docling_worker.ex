defmodule Foresight.Ingestion.DoclingWorker do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def parse_with_metadata(path, opts \\ []) when is_binary(path) do
    name = Keyword.get(opts, :name, __MODULE__)
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(name, {:parse_with_metadata, path}, timeout)
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
        System.get_env("FORESIGHT_DOCLING_PYTHON") ||
        "python3"

    start_opts = [
      {:python_path, to_charlist(python_path)},
      {:python, to_charlist(python_executable)}
    ]

    case :python.start(start_opts) do
      {:ok, python} ->
        {:ok, %{python: python}}

      {:error, reason} ->
        {:stop, {:python_start_failed, reason}}
    end
  end

  @impl true
  def handle_call({:parse_with_metadata, path}, _from, state) do
    try do
      reply =
        state.python
        |> :python.call(:docling_wrapper, :parse_with_metadata, [to_charlist(path)])
        |> normalize_python_response()

      {:reply, reply, state}
    catch
      :exit, reason ->
        # The Python port died. Reply with the error, then STOP so the supervisor
        # restarts us with a fresh port — do not keep a dead port in state (which
        # would fail every subsequent request forever while /health stays green).
        {:stop, {:python_died, reason}, {:error, "Docling worker exited: #{inspect(reason)}"},
         state}
    end
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{python: port} = state) do
    {:stop, {:python_died, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{python: python}) when not is_nil(python) do
    :python.stop(python)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  def normalize_python_response({status, metadata})
      when status in [:ok, "ok", ~c"ok"] and is_map(metadata) do
    {:ok,
     %{
       markdown:
         metadata
         |> fetch_python_value("markdown")
         |> normalize_python_string(),
       metadata:
         metadata
         |> fetch_python_value("metadata")
         |> normalize_python_value(),
       chunks:
         metadata
         |> fetch_python_value("chunks")
         |> normalize_python_chunks()
     }}
  end

  def normalize_python_response({status, markdown})
      when status in [:ok, "ok", ~c"ok"] and is_binary(markdown),
      do: {:ok, markdown}

  def normalize_python_response({status, markdown})
      when status in [:ok, "ok", ~c"ok"] and is_list(markdown),
      do: {:ok, normalize_python_string(markdown)}

  def normalize_python_response({status, reason})
      when status in [:error, "error", ~c"error"],
      do: {:error, normalize_python_string(reason)}

  def normalize_python_response(other),
    do: {:error, "Unexpected Docling response: #{inspect(other)}"}

  defp fetch_python_value(map, key) do
    Map.get(map, key) || Map.get(map, String.to_charlist(key)) ||
      Map.get(map, String.to_atom(key))
  end

  defp normalize_python_value(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      {normalize_python_key(key), normalize_python_value(item)}
    end)
  end

  # An empty list is ambiguous — Keyword.keyword?([]) is true — but a Python [] is a
  # list (e.g. an empty section_path), never a dict, so keep it a list not a %{}.
  defp normalize_python_value([]), do: []

  defp normalize_python_value(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.into(%{}, fn {key, item} ->
        {normalize_python_key(key), normalize_python_value(item)}
      end)
    else
      case maybe_charlist(value) do
        {:ok, string} -> string
        :error -> Enum.map(value, &normalize_python_value/1)
      end
    end
  end

  defp normalize_python_value(value), do: value

  defp normalize_python_chunks(nil), do: []

  defp normalize_python_chunks(value) do
    case normalize_python_value(value) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _other -> []
    end
  end

  defp normalize_python_key(key) when is_binary(key), do: key
  defp normalize_python_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_python_key(key) when is_list(key), do: to_string(key)
  defp normalize_python_key(key), do: to_string(key)

  defp normalize_python_string(value) when is_binary(value), do: value
  defp normalize_python_string(value) when is_list(value), do: to_string(value)
  defp normalize_python_string(value), do: to_string(value)

  defp maybe_charlist(list) do
    if Enum.all?(list, &is_integer/1), do: {:ok, List.to_string(list)}, else: :error
  end
end
