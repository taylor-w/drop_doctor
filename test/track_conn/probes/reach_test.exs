defmodule TrackConn.Probes.ReachTest do
  use ExUnit.Case, async: true

  alias TrackConn.Probes.Reach

  # Build a ping fun (host, opts) -> ping_result from a map of host => {rtt, loss}.
  # A closure copies into the async-stream tasks, so injection works across the
  # processes Reach fans out to (a module + process-dictionary would not).
  defp pinger(scripted) do
    fn host, _opts ->
      case Map.get(scripted, host) do
        {rtt, loss} ->
          %{ok?: true, rtt_ms: rtt, max_rtt_ms: rtt, jitter_ms: 1.0, loss_pct: loss,
            sent: 3, received: 3, raw: "reply from #{host}", error: nil}

        nil ->
          %{ok?: false, rtt_ms: nil, max_rtt_ms: nil, jitter_ms: nil, loss_pct: 100.0,
            sent: 3, received: 0, raw: "no reply from #{host}", error: "no reply"}
      end
    end
  end

  defp run(anchors, scripted, opts \\ []) do
    Reach.run("ignored", Keyword.merge([anchors: anchors, ping: pinger(scripted)], opts))
  end

  test "reachable if ANY anchor answers ICMP — a single filtered IP can't fake an outage" do
    # 1.1.1.1 filtered (absent), 8.8.8.8 answers.
    r = run(["1.1.1.1", "8.8.8.8", "9.9.9.9"], %{"8.8.8.8" => {14.0, 0.0}})

    assert r.ok?
    assert r.loss_pct == 0.0
    assert r.rtt_ms == 14.0
    assert r.raw =~ "8.8.8.8"
  end

  test "picks the healthiest responder (lowest loss, then latency)" do
    r = run(["1.1.1.1", "8.8.8.8"], %{"1.1.1.1" => {30.0, 0.0}, "8.8.8.8" => {12.0, 0.0}})
    assert r.rtt_ms == 12.0
  end

  test "a clean anchor beats a faster but lossy one" do
    r = run(["1.1.1.1", "8.8.8.8"], %{"1.1.1.1" => {5.0, 50.0}, "8.8.8.8" => {20.0, 0.0}})
    assert r.rtt_ms == 20.0
    assert r.loss_pct == 0.0
  end

  test "ICMP blocked everywhere but TCP connects -> reachable via TCP fallback" do
    tcp = fn
      "8.8.8.8" -> {:ok, 22}
      _ -> :error
    end

    r = run(["1.1.1.1", "8.8.8.8", "9.9.9.9"], %{}, tcp: tcp)

    assert r.ok?
    assert r.loss_pct == 0.0
    assert r.rtt_ms == 22.0
    assert r.raw =~ "TCP"
    assert r.raw =~ "8.8.8.8"
  end

  test "nothing answers ICMP or TCP -> genuinely down" do
    r = run(["1.1.1.1", "8.8.8.8"], %{}, tcp: fn _ -> :error end)

    refute r.ok?
    assert r.loss_pct == 100.0
    assert r.rtt_ms == nil
    assert r.error == "no reply"
  end

  test "router that blocks ICMP but answers TCP :53 -> reachable, names the port" do
    # The common home-router case: ping times out, but a TCP connect to DNS/web
    # admin completes, so we can still measure (and prove) it's reachable.
    tcp = fn
      "192.168.1.1" -> {:ok, 2, 53}
      _ -> :error
    end

    r =
      Reach.run("192.168.1.1",
        anchors: ["192.168.1.1"],
        tcp_ports: [53, 80, 443],
        label: "your router",
        ping: pinger(%{}),
        tcp: tcp
      )

    assert r.ok?
    assert r.rtt_ms == 2.0
    assert r.loss_pct == 0.0
    assert r.raw =~ "your router"
    assert r.raw =~ "192.168.1.1:53"
  end

  test "result is ping-shaped (keys the diagnosis/aggregate rely on)" do
    r = run(["1.1.1.1"], %{"1.1.1.1" => {10.0, 0.0}})

    for k <- [:ok?, :rtt_ms, :loss_pct, :max_rtt_ms, :jitter_ms, :raw] do
      assert Map.has_key?(r, k)
    end
  end
end
