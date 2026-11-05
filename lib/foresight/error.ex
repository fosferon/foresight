defmodule Foresight.Error do
  @moduledoc """
  The error currency of the library.

  Every failure surfaces as a `t:t/0` struct — `{:error, %Foresight.Error{}}`
  from API calls, or a raised exception in non-taggable contexts — carrying a
  machine-readable `reason`, an optional `detail`, and a `context` map for
  debugging.
  """

  @enforce_keys [:reason]
  defexception [:reason, :detail, context: %{}]

  @type t :: %__MODULE__{
          reason: atom(),
          detail: term(),
          context: map()
        }

  @spec new(atom(), term(), map()) :: t()
  def new(reason, detail \\ nil, context \\ %{}) when is_atom(reason) and is_map(context) do
    %__MODULE__{reason: reason, detail: detail, context: context}
  end

  @impl true
  def message(%__MODULE__{reason: reason, detail: nil}) do
    Atom.to_string(reason)
  end

  def message(%__MODULE__{reason: reason, detail: detail}) do
    "#{reason}: #{inspect(detail)}"
  end
end
