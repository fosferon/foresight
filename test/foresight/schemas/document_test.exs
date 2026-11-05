defmodule Foresight.Schemas.DocumentTest do
  use ExUnit.Case, async: true

  alias Foresight.Schemas.Document

  test "declares the (bank_id, external_id) unique constraint" do
    # Without it a concurrent first insert of the same document id surfaced as a raised
    # Ecto.ConstraintError (HTTP 500) instead of a changeset error.
    changeset = Document.changeset(%Document{}, %{bank_id: "bank", external_id: "doc-1"})

    assert [%{type: :unique, constraint: "documents_bank_external_id_idx"}] =
             changeset.constraints
  end
end
