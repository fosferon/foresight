defmodule Foresight.HTTP.RecordedFixtureManifestTest do
  use ExUnit.Case, async: true

  @moduletag :tier2

  @fixture_root Path.expand("../../../priv/foresight/fixtures/recorded_floor_contract", __DIR__)
  @manifest_path Path.join(@fixture_root, "manifest.json")

  test "recorded hindsight fixture manifest is present and decodable" do
    manifest = @manifest_path |> File.read!() |> Jason.decode!()

    assert get_in(manifest, ["authority", "version"]) == "0.7.1"
    assert is_list(manifest["fixtures"])
    assert manifest["fixtures"] != []

    Enum.each(manifest["fixtures"], fn fixture ->
      assert fixture["status"] in [200, 201, 410]

      fixture
      |> Map.fetch!("name")
      |> then(&Path.join(@fixture_root, &1))
      |> File.read!()
      |> Jason.decode!()
    end)
  end
end
