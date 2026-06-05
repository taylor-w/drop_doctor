defmodule TrackConn.SweeperTest do
  use ExUnit.Case, async: true
  alias TrackConn.Sweeper
  alias TrackConn.Test.FakeProbes

  defp ladder do
    [
      %{key: :router, label: "r", kind: :ping, target: "192.168.1.1", about: ""},
      %{key: :internet, label: "i", kind: :ping, target: "1.1.1.1", about: ""},
      %{key: :dns, label: "d", kind: :dns, target: "h", about: ""},
      %{key: :web, label: "w", kind: :http, target: "http://x", about: ""}
    ]
  end

  test "runs every probe via the injected registry and keys by segment" do
    result = Sweeper.run(ladder(), probes: FakeProbes.healthy())

    assert Map.keys(result) |> Enum.sort() == [:dns, :internet, :router, :web]
    assert result.router.ok?
    assert result.router.def.key == :router
    assert result.web.status == 200
  end

  test "a hung probe yields a timeout result instead of stalling the sweep" do
    registry = %{
      ping: FakeProbes.SlowPing,
      dns: FakeProbes.HealthyDns,
      http: FakeProbes.HealthyHttp
    }

    result = Sweeper.run(ladder(), probes: registry, timeout: 100)

    # ping segments time out -> failure-shaped, but dns/http still succeed
    refute result.router.ok?
    assert result.router.loss_pct == 100.0
    assert result.router.error == "timeout"
    assert result.dns.ok?
    assert result.web.ok?
  end
end
