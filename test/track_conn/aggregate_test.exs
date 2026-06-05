defmodule TrackConn.AggregateTest do
  use ExUnit.Case, async: true
  alias TrackConn.Aggregate

  defp router_def, do: %{key: :router, label: "r", kind: :ping, target: "192.168.1.1", about: ""}
  defp dns_def, do: %{key: :dns, label: "d", kind: :dns, target: "h", about: ""}

  defp ping(loss, rtt),
    do: %{ok?: loss < 100, loss_pct: loss, rtt_ms: rtt, raw: "x", def: router_def()}

  defp sweep(loss, rtt), do: %{router: ping(loss, rtt)}

  describe "median" do
    test "odd count" do
      assert Aggregate.median([3, 1, 2]) == 2
    end

    test "even count averages the middle two" do
      assert Aggregate.median([1, 2, 3, 4]) == 2.5
    end

    test "empty is nil" do
      assert Aggregate.median([]) == nil
    end
  end

  describe "summarize debounces noise (Tier 1 credibility)" do
    test "a single 100% loss spike among healthy readings is ignored" do
      # newest first: one bad reading, four good
      window = [sweep(100.0, nil), sweep(0.0, 5), sweep(0.0, 6), sweep(0.0, 4), sweep(0.0, 5)]
      result = Aggregate.summarize(window)

      # median loss across [100,0,0,0,0] = 0 -> still considered up
      assert result.router.loss_pct == 0.0
      assert result.router.ok?
    end

    test "sustained loss does move the verdict" do
      window = [
        sweep(100.0, nil),
        sweep(100.0, nil),
        sweep(100.0, nil),
        sweep(0.0, 5),
        sweep(0.0, 5)
      ]

      result = Aggregate.summarize(window)

      # median of [100,100,100,0,0] = 100 -> down
      assert result.router.loss_pct == 100.0
      refute result.router.ok?
    end

    test "rtt is smoothed to the median, not the latest spike" do
      window = [sweep(0.0, 500), sweep(0.0, 5), sweep(0.0, 6), sweep(0.0, 4), sweep(0.0, 5)]
      result = Aggregate.summarize(window)
      assert result.router.rtt_ms == 5
    end

    test "preserves latest raw and def for display" do
      window = [Map.put(sweep(0.0, 5), :router, %{ping(0.0, 5) | raw: "latest"})]
      result = Aggregate.summarize(window)
      assert result.router.raw == "latest"
      assert result.router.def.kind == :ping
    end
  end

  describe "summarize for timed probes" do
    test "ok? requires a majority of recent readings to succeed" do
      d = fn ok, ms -> %{ok?: ok, ms: ms, address: "a", raw: "x", def: dns_def()} end
      window = [%{dns: d.(false, nil)}, %{dns: d.(true, 20)}, %{dns: d.(true, 22)}]
      result = Aggregate.summarize(window)
      # 2 of 3 ok -> ok
      assert result.dns.ok?
      assert result.dns.ms == 21.0
    end
  end
end
