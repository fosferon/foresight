# Live Mode C isolation proof.
#
# The in-process suites (mode_c_header_escape_test.exs, mode_c_isolation_probe_test.exs)
# prove the cross-tenant escape is closed in code. This proves it over real HTTP against a
# RUNNING instance, which is the thing a consumer can actually be shown before putting
# their data behind Foresight.
#
# Usage:
#   FORESIGHT_URL=http://localhost:4001 \
#   FORESIGHT_SERVICE_KEY=... \
#   VICTIM_TENANT=tenant-victim \
#   elixir scripts/mode_c_isolation_proof.exs
#
# Exits non-zero if ANY attack succeeds. Read-only against the victim: it only ever tries
# to READ, never to write, so a false negative cannot damage data.

Mix.install([{:req, "~> 0.5"}])

base_url = System.get_env("FORESIGHT_URL", "http://localhost:4001")
service_key = System.get_env("FORESIGHT_SERVICE_KEY")
victim = System.get_env("VICTIM_TENANT", "tenant-victim")
victim_prefix = System.get_env("VICTIM_PREFIX", String.replace(victim, "-", "_"))
victim_role = System.get_env("VICTIM_ROLE", "#{victim_prefix}_role")

defmodule Proof do
  def attempt(name, url, headers, expectation) do
    {status, body} =
      case Req.post(url,
             headers: headers,
             json: %{query: "vault code"},
             retry: false,
             receive_timeout: 15_000
           ) do
        {:ok, resp} -> {resp.status, resp.body}
        {:error, err} -> {:error, inspect(err)}
      end

    # A request is only truly blocked if it did not return victim data, whatever its
    # status code. Checking the canary directly means a 200 that leaks cannot pass.
    leaked? = inspect(body) =~ "VICTIM SECRET"
    blocked? = expectation.(status) and not leaked?

    IO.puts([
      if(blocked?, do: "  BLOCKED  ", else: "  ESCAPED  "),
      String.pad_trailing(name, 52),
      "status=#{inspect(status)}"
    ])

    unless blocked? do
      IO.puts("             LEAKED CANARY: #{leaked?}")
      IO.puts("             response: #{inspect(body) |> String.slice(0, 300)}")
    end

    blocked?
  end

  def rejected?(status) when status in [401, 403], do: true
  def rejected?(_status), do: false

  # A forged-header attack "fails safe" if it is rejected outright, OR if it is silently
  # downgraded to a scope that is not the victim's (i.e. it did not reach victim data).
  def not_victim_scoped?(status), do: status in [401, 403, 404]
end

IO.puts("""

Mode C live isolation proof
  target:  #{base_url}
  victim:  #{victim} (prefix #{victim_prefix}, role #{victim_role})
  service key: #{if service_key, do: "provided", else: "ABSENT — service-key attack skipped"}
""")

victim_bank = System.get_env("VICTIM_BANK", "victim-bank")
recall_url = "#{base_url}/v1/default/banks/#{victim_bank}/memories/recall"

results = [
  Proof.attempt(
    "bare bearer + forged tenant/prefix/role",
    recall_url,
    [
      {"authorization", "Bearer definitely-not-a-real-key"},
      {"x-foresight-tenant-id", victim},
      {"x-foresight-prefix", victim_prefix},
      {"x-foresight-role", victim_role}
    ],
    &Proof.rejected?/1
  ),
  Proof.attempt(
    "empty bearer + forged headers",
    recall_url,
    [
      {"authorization", "Bearer "},
      {"x-foresight-tenant-id", victim},
      {"x-foresight-role", victim_role}
    ],
    &Proof.rejected?/1
  ),
  Proof.attempt(
    "no bearer at all + forged headers",
    recall_url,
    [
      {"x-foresight-tenant-id", victim},
      {"x-foresight-prefix", victim_prefix},
      {"x-foresight-role", victim_role}
    ],
    &Proof.not_victim_scoped?/1
  ),
  Proof.attempt(
    "forged prefix only (no tenant id)",
    recall_url,
    [
      {"authorization", "Bearer definitely-not-a-real-key"},
      {"x-foresight-prefix", victim_prefix}
    ],
    &Proof.rejected?/1
  ),
  Proof.attempt(
    "unknown tenant id with a plausible key shape",
    recall_url,
    [
      {"authorization", "Bearer sk-0000000000000000000000000000"},
      {"x-foresight-tenant-id", victim}
    ],
    &Proof.rejected?/1
  )
]

# Self-check: the legitimate credential MUST read the canary. Without this, a proof that
# silently pointed at the wrong bank, or at a tenant holding no data, would report a clean
# sweep while testing nothing at all.
legit_key = System.get_env("VICTIM_API_KEY")

self_check_ok? =
  if legit_key do
    reachable? =
      not Proof.attempt(
        "SELF-CHECK: legitimate credential must reach the canary",
        recall_url,
        [{"authorization", "Bearer #{legit_key}"}, {"x-foresight-tenant-id", victim}],
        fn _status -> true end
      )

    IO.puts(
      if reachable?,
        do: "  (self-check OK — the canary is present and the detector fires)",
        else: "  (self-check FAILED — the canary was never readable, so the sweep proves nothing)"
    )

    reachable?
  else
    IO.puts("\n  SELF-CHECK SKIPPED — set VICTIM_API_KEY to prove the detector actually fires.")
    false
  end

escaped = Enum.count(results, &(&1 == false))

IO.puts("""

#{length(results) - escaped}/#{length(results)} attacks blocked.
""")

cond do
  escaped > 0 ->
    IO.puts("FAIL — #{escaped} attack(s) reached victim scope. Do not put real data behind this.")
    System.halt(1)

  not self_check_ok? ->
    IO.puts("INCONCLUSIVE — every attack was blocked, but the self-check did not confirm the")
    IO.puts("canary was readable at all. Re-run with VICTIM_API_KEY set.")
    System.halt(2)

  true ->
    IO.puts("PASS — no forged-header path reached the victim tenant, and the canary was")
    IO.puts("provably readable with the legitimate credential.")
end
