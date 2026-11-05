defmodule Foresight.PublicRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :foresight,
    adapter: Ecto.Adapters.Postgres
end
