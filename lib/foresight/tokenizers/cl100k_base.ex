defmodule Foresight.Tokenizers.Cl100kBase do
  @moduledoc false

  @default_identifier "Xenova/text-embedding-ada-002"
  @cache_key {__MODULE__, :tokenizer}

  @spec load(keyword()) :: {:ok, struct()} | {:error, term()}
  def load(opts \\ []) do
    case :persistent_term.get(@cache_key, :undefined) do
      :undefined ->
        opts
        |> resolved_options()
        |> load_tokenizer()
        |> case do
          {:ok, tokenizer} = ok ->
            :persistent_term.put(@cache_key, {tokenizer_cache_fingerprint(opts), tokenizer})
            ok

          error ->
            error
        end

      {fingerprint, tokenizer} ->
        if fingerprint == tokenizer_cache_fingerprint(opts) do
          {:ok, tokenizer}
        else
          opts
          |> resolved_options()
          |> load_tokenizer()
          |> case do
            {:ok, tokenizer} = ok ->
              :persistent_term.put(@cache_key, {tokenizer_cache_fingerprint(opts), tokenizer})
              ok

            error ->
              error
          end
        end
    end
  end

  @spec encode(String.t(), keyword()) :: {:ok, [non_neg_integer()]} | {:error, term()}
  def encode(text, opts \\ []) when is_binary(text) do
    with {:ok, tokenizer} <- load(opts),
         {:ok, encoding} <-
           Tokenizers.Tokenizer.encode(tokenizer, text, add_special_tokens: false) do
      {:ok, Tokenizers.Encoding.get_ids(encoding)}
    end
  end

  @spec count(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(text, opts \\ []) when is_binary(text) do
    with {:ok, tokenizer} <- load(opts),
         {:ok, encoding} <-
           Tokenizers.Tokenizer.encode(tokenizer, text, add_special_tokens: false) do
      {:ok, Tokenizers.Encoding.get_length(encoding)}
    end
  end

  defp load_tokenizer(opts) do
    case opts[:path] do
      nil ->
        Tokenizers.Tokenizer.from_pretrained(opts[:identifier],
          use_cache: opts[:use_cache]
        )

      path ->
        Tokenizers.Tokenizer.from_file(path)
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp resolved_options(opts) do
    config =
      :foresight
      |> Application.get_env(:tokenizer, [])
      |> Enum.into(%{})

    %{
      identifier:
        Keyword.get(opts, :identifier) ||
          System.get_env("FORESIGHT_CL100K_TOKENIZER_ID") ||
          config[:identifier] ||
          @default_identifier,
      path:
        Keyword.get(opts, :path) ||
          System.get_env("FORESIGHT_CL100K_TOKENIZER_PATH") ||
          config[:path],
      use_cache: Keyword.get(opts, :use_cache, config[:use_cache] || true)
    }
  end

  defp tokenizer_cache_fingerprint(opts) do
    opts = resolved_options(opts)
    {opts.path, opts.identifier, opts.use_cache}
  end
end
