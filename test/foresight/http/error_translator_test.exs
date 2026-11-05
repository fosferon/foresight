defmodule Foresight.HTTP.ErrorTranslatorTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Foresight.Error
  alias Foresight.HTTP.ErrorTranslator

  test "translates foresight errors into JSON responses" do
    conn =
      conn(:get, "/missing")
      |> ErrorTranslator.send_error(Error.new(:not_found))

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "not_found"}
  end

  # Audit finding: This clause used to be `%LlmError{}` via an alias to the
  # OPTIONAL :llm_core dependency, which is precisely why the library would not compile
  # for a consumer. It is now matched by module atom at runtime — behaviour-preserving,
  # but nothing tested it, and it sits on the REST error surface where a silent change
  # alters API responses for every LLM-provider failure.
  #
  # The struct is built by hand rather than by aliasing LlmCore, so this test keeps
  # working whether or not the optional dependency is installed. That is the whole
  # property under test: the translator must not need llm_core to be present.
  describe "llm provider errors" do
    # Map.merge, not Enum.into: a map carrying __struct__ IS a struct as far as Elixir is
    # concerned, and structs do not implement Collectable.
    defp llm_error(fields) do
      Map.merge(
        %{
          __struct__: :"Elixir.LlmCore.LLM.Error",
          type: :provider_error,
          message: "boom",
          provider: nil,
          details: nil
        },
        Map.new(fields)
      )
    end

    test "maps each provider error type to its documented status" do
      for {type, status} <- [
            connection: 503,
            authentication: 502,
            rate_limit: 503,
            timeout: 504,
            provider_error: 502
          ] do
        conn = conn(:get, "/x") |> ErrorTranslator.send_error(llm_error(type: type))

        assert conn.status == status, "#{type} should map to #{status}, got #{conn.status}"
        assert Jason.decode!(conn.resp_body)["error"] == to_string(type)
      end
    end

    test "carries message and provider through, omitting absent fields" do
      conn =
        conn(:get, "/x")
        |> ErrorTranslator.send_error(
          llm_error(type: :timeout, message: "upstream timed out", provider: :openai)
        )

      assert %{"error" => "timeout", "detail" => detail} = Jason.decode!(conn.resp_body)
      assert detail["message"] == "upstream timed out"
      assert detail["provider"] == "openai"
      # provider was nil in the other cases and must not appear as a null
      refute Map.has_key?(detail, "details")
    end

    test "a Foresight.Error is NOT captured by the llm clause" do
      # Both clauses match a struct; only ordering and the module atom keep them apart.
      conn = conn(:get, "/x") |> ErrorTranslator.send_error(Error.new(:invalid_request))

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_request"
    end

    test "an unrecognised struct still produces a response rather than raising" do
      conn = conn(:get, "/x") |> ErrorTranslator.send_error(%{__struct__: SomethingElse})

      assert conn.status in 400..599
    end
  end
end
