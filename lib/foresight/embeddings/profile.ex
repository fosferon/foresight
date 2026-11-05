defmodule Foresight.Embeddings.Profile do
  @moduledoc false

  alias Foresight.Error
  alias Foresight.Schemas.MemoryUnit

  @vector_fields %{
    384 => :embedding_384,
    1024 => :embedding_1024,
    1536 => :embedding_1536,
    3072 => :embedding_3072
  }

  # Columns stored as pgvector `halfvec` rather than `vector`: HNSW over plain vectors
  # stops at 2000 dimensions, so 3072 (text-embedding-3-large at full width) is
  # 16-bit. Every query against such a column must cast its parameter to halfvec.
  @half_fields [:embedding_3072]

  @spec resolve(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def resolve(resolved_config, opts) when is_map(resolved_config) do
    embedder = Keyword.fetch!(opts, :embedder)
    runtime_config = Keyword.get(opts, :runtime_config, %{})
    requested_model_id = requested_model_id(resolved_config, runtime_config, embedder)

    with {:ok, embedder_dim} <-
           embedder.dimension(embedder_opts(requested_model_id, resolved_config["embedding_dim"])),
         {:ok, configured_dim} <-
           normalize_dimension(resolved_config["embedding_dim"], embedder_dim) do
      if configured_dim == embedder_dim do
        case Map.fetch(@vector_fields, configured_dim) do
          {:ok, vector_field} ->
            {:ok,
             %{
               "model_id" => requested_model_id,
               "embedding_dim" => configured_dim,
               "vector_field" => vector_field
             }}

          :error ->
            {:error,
             Error.new(:invalid_request, %{
               message: "unsupported embedding dimension #{configured_dim}"
             })}
        end
      else
        {:error,
         Error.new(:invalid_request, %{
           message:
             "configured embedding_dim #{configured_dim} does not match active embedder dimension #{embedder_dim}"
         })}
      end
    end
  end

  @spec changed?(map(), map()) :: boolean()
  def changed?(left, right) when is_map(left) and is_map(right) do
    left["model_id"] != right["model_id"] or left["embedding_dim"] != right["embedding_dim"]
  end

  @spec stale?(map(), map()) :: boolean()
  def stale?(unit, profile) when is_map(unit) and is_map(profile) do
    unit.embedded_by != profile["model_id"] or
      unit.embedded_dim != profile["embedding_dim"] or
      missing_vector?(unit, profile)
  end

  @spec vector_field(pos_integer()) :: atom()
  def vector_field(dimension) when is_integer(dimension) do
    Map.fetch!(@vector_fields, dimension)
  end

  @doc "Every memory-unit vector column, for building an attrs map that clears the rest."
  @spec vector_fields() :: [atom()]
  def vector_fields, do: @vector_fields |> Map.values() |> Enum.sort()

  @doc "Whether `field` is stored as pgvector `halfvec` (16-bit) rather than `vector`."
  @spec half?(atom()) :: boolean()
  def half?(field) when is_atom(field), do: field in @half_fields

  @doc "The SQL type a query parameter must be cast to when compared with `field`."
  @spec sql_type(atom()) :: String.t()
  def sql_type(field) when is_atom(field), do: if(half?(field), do: "halfvec", else: "vector")

  @doc """
  Wrap raw floats as the pgvector struct matching the column they are stored in
  (`Pgvector.HalfVector` for halfvec columns, `Pgvector` otherwise). Accepts the
  column name or the dimension.
  """
  @spec to_vector(atom() | pos_integer(), [number()]) :: Pgvector.t() | Pgvector.HalfVector.t()
  def to_vector(dimension, values) when is_integer(dimension),
    do: to_vector(vector_field(dimension), values)

  def to_vector(field, values) when is_atom(field) and is_list(values) do
    if half?(field), do: Pgvector.HalfVector.new(values), else: Pgvector.new(values)
  end

  @spec vector(MemoryUnit.t() | map()) :: Pgvector.t() | Pgvector.HalfVector.t() | nil
  def vector(%MemoryUnit{} = unit) do
    case unit.embedded_dim do
      384 -> unit.embedding_384
      1024 -> unit.embedding_1024
      1536 -> unit.embedding_1536
      3072 -> unit.embedding_3072
      _other -> nil
    end
  end

  def vector(unit) when is_map(unit) do
    case unit["embedded_dim"] || unit[:embedded_dim] do
      384 -> unit["embedding_384"] || unit[:embedding_384]
      1024 -> unit["embedding_1024"] || unit[:embedding_1024]
      1536 -> unit["embedding_1536"] || unit[:embedding_1536]
      3072 -> unit["embedding_3072"] || unit[:embedding_3072]
      _other -> nil
    end
  end

  @spec embedder_opts(map()) :: keyword()
  def embedder_opts(profile) when is_map(profile) do
    embedder_opts(profile["model_id"], profile["embedding_dim"])
  end

  defp normalize_dimension(nil, embedder_dim), do: {:ok, embedder_dim}
  defp normalize_dimension("", embedder_dim), do: {:ok, embedder_dim}

  defp normalize_dimension(value, _embedder_dim) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_dimension(value, embedder_dim) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> normalize_dimension(nil, embedder_dim)
    end
  end

  defp normalize_dimension(_value, embedder_dim), do: {:ok, embedder_dim}

  defp requested_model_id(resolved_config, runtime_config, embedder) do
    resolved_config["embed_model"] ||
      app_ml_model_id() ||
      get_in(runtime_config, [:ml, :model_id]) ||
      inspect(embedder)
  end

  defp embedder_opts(model_id, embedding_dim) do
    [model_id: model_id, embedding_dim: embedding_dim]
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp missing_vector?(unit, profile) do
    case profile["vector_field"] do
      :embedding_384 -> is_nil(unit.embedding_384)
      :embedding_1024 -> is_nil(unit.embedding_1024)
      :embedding_1536 -> is_nil(unit.embedding_1536)
      :embedding_3072 -> is_nil(unit.embedding_3072)
      _other -> true
    end
  end

  defp app_ml_model_id do
    case Application.get_env(:foresight, :ml, []) do
      config when is_list(config) -> Keyword.get(config, :model_id)
      config when is_map(config) -> Map.get(config, :model_id)
      _other -> nil
    end
  end
end
