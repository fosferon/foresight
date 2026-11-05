defmodule Foresight.TestSupport.HealthyChecker do
  @moduledoc false

  def check(_config), do: %{"status" => "healthy", "database" => "connected"}
end

defmodule Foresight.TestSupport.UnhealthyChecker do
  @moduledoc false

  def check(_config), do: %{"status" => "unhealthy", "database" => "error", "error" => "boom"}
end
