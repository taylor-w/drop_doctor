defmodule TrackConn.SpikeMonitorTest do
  # async: false — registers a named process and uses the shared ProbeSupervisor.
  use ExUnit.Case, async: false
  alias TrackConn.SpikeMonitor

  # A fake stream source: spawns a process that feeds canned ping lines to the
  # monitor on a steady cadence until it's killed (which is how the monitor stops
  # sampling). Mirrors the real `Ping.stream/3` contract — the returned pid is the
  # reader the monitor monitors, and it sends `{:stream_line, self(), line}`.
  defp fake_stream(lines) do
    fn owner, _host, _opts ->
      spawn(fn -> feed(owner, lines) end)
    end
  end

  defp feed(owner, lines) do
    Enum.each(lines, fn line ->
      send(owner, {:stream_line, self(), line})
      Process.sleep(10)
    end)

    feed(owner, lines)
  end

  @reply "64 bytes from 1.1.1.1: icmp_seq=1 ttl=55 time=12.3 ms"

  setup do
    start_supervised!(
      {SpikeMonitor,
       key: :test,
       host: "127.0.0.1",
       count: 3,
       window: 500,
       persist: false,
       stream_fun: fake_stream([@reply, @reply, @reply])}
    )

    :ok
  end

  test "samples continuously, and pause/resume stops and restarts it" do
    assert SpikeMonitor.running?(:test)

    # a few flushed batches accumulate
    Process.sleep(120)
    n1 = SpikeMonitor.stats(:test).sample_count
    assert n1 > 0

    # pause: a cast ordered before this call, so it's already applied
    SpikeMonitor.pause(:test)
    refute SpikeMonitor.running?(:test)

    # the stream is killed, so the sample count stops growing
    Process.sleep(80)
    n2 = SpikeMonitor.stats(:test).sample_count
    Process.sleep(80)
    assert SpikeMonitor.stats(:test).sample_count == n2

    # resume: sampling picks back up
    SpikeMonitor.resume(:test)
    assert SpikeMonitor.running?(:test)
    Process.sleep(120)
    assert SpikeMonitor.stats(:test).sample_count > n2
  end

  test "reset clears the rolling buffer while sampling continues" do
    Process.sleep(120)
    assert SpikeMonitor.stats(:test).sample_count > 0

    SpikeMonitor.reset(:test)
    # immediately after reset the buffer is empty
    assert SpikeMonitor.stats(:test).sample_count == 0

    # ...and it refills on its own
    Process.sleep(120)
    assert SpikeMonitor.stats(:test).sample_count > 0
  end

  describe "alt_verdict/2 — second-anchor corroboration decision" do
    test "alt clean -> false (one route, not provider-wide)" do
      assert SpikeMonitor.alt_verdict(%{rtt_ms: 20.0, loss_pct: 0.0, max_rtt_ms: 24.0}, 20.0) ==
               false
    end

    test "alt also losing packets -> true (provider-wide)" do
      assert SpikeMonitor.alt_verdict(%{rtt_ms: 21.0, loss_pct: 33.0, max_rtt_ms: 25.0}, 20.0) ==
               true
    end

    test "alt also spiking well above the norm -> true" do
      assert SpikeMonitor.alt_verdict(%{rtt_ms: 22.0, loss_pct: 0.0, max_rtt_ms: 180.0}, 20.0) ==
               true
    end

    test "alt also fully down (100% loss) -> true (both providers lost packets → provider-wide)" do
      # Total loss must corroborate at least as strongly as partial loss; the old
      # ordering let the rtt_ms-nil guard fire first and mislabel this as nil.
      assert SpikeMonitor.alt_verdict(%{rtt_ms: nil, loss_pct: 100.0, max_rtt_ms: nil}, 20.0) ==
               true
    end

    test "alt gave no measurement at all -> nil (can't corroborate)" do
      assert SpikeMonitor.alt_verdict(%{rtt_ms: nil, loss_pct: nil, max_rtt_ms: nil}, 20.0) == nil
    end
  end

  test "switches to TCP sampling when the host never answers ICMP" do
    # The ICMP stream only ever times out; the TCP stream answers. After the
    # ICMP give-up threshold the monitor should swap and start collecting samples.
    icmp = fn owner, _host, _opts -> spawn(fn -> feed(owner, ["Request timed out."]) end) end
    tcp = fn owner, _host, _opts -> spawn(fn -> feed(owner, ["reply time=5 ms"]) end) end

    start_supervised!(
      {SpikeMonitor,
       key: :tcpswitch,
       host: "127.0.0.1",
       count: 5,
       window: 500,
       persist: false,
       tcp_ports: [1],
       stream_fun: icmp,
       tcp_stream_fun: tcp},
      id: :tcpswitch
    )

    # ICMP yields only loss (received stays 0); once it gives up and swaps to the
    # TCP stream, real replies start landing.
    assert eventually(fn -> SpikeMonitor.stats(:tcpswitch).received > 0 end)
    assert SpikeMonitor.stats(:tcpswitch).rtt_ms == 5.0
    assert SpikeMonitor.stats(:tcpswitch).mode == :tcp
  end

  test "a host that has answered ICMP is never downgraded to TCP, even after going silent" do
    # One real reply (so icmp_seen latches), then permanent silence. Past the
    # give-up threshold the window is all-loss, but because the host proved it
    # answers ICMP it must keep trying ICMP and never adopt the TCP stream — so a
    # transient outage can't permanently downgrade a normally-ICMP anchor.
    reply_then_silent = fn owner, _host, _opts ->
      spawn(fn ->
        send(owner, {:stream_line, self(), @reply})
        Process.sleep(10)
        feed(owner, ["Request timed out."])
      end)
    end

    tcp = fn owner, _host, _opts -> spawn(fn -> feed(owner, ["reply time=5 ms"]) end) end

    start_supervised!(
      {SpikeMonitor,
       key: :sticky,
       host: "127.0.0.1",
       count: 2,
       window: 60,
       persist: false,
       tcp_ports: [1],
       stream_fun: reply_then_silent,
       tcp_stream_fun: tcp},
      id: :sticky
    )

    # Well past @icmp_giveup worth of silent samples; the TCP stream's 5.0ms
    # replies must never appear because we never switch.
    Process.sleep(1200)
    assert SpikeMonitor.stats(:sticky).mode == :icmp
    refute SpikeMonitor.stats(:sticky).rtt_ms == 5.0
  end

  test "broadcast stats carry the probe mode (so the UI can tell ICMP from TCP)" do
    Process.sleep(120)
    assert SpikeMonitor.stats(:test).mode == :icmp
  end

  describe "loggable_events/2 — TCP-mode loss suppression" do
    test "TCP mode drops loss events but keeps latency spikes" do
      events = [%{kind: :latency, peak_ms: 120.0}, %{kind: :loss, loss_pct: 10.0}]

      assert SpikeMonitor.loggable_events(%{probe_mode: :tcp}, events) == [
               %{kind: :latency, peak_ms: 120.0}
             ]
    end

    test "ICMP mode keeps everything" do
      events = [%{kind: :latency, peak_ms: 120.0}, %{kind: :loss, loss_pct: 10.0}]
      assert SpikeMonitor.loggable_events(%{probe_mode: :icmp}, events) == events
    end
  end

  defp eventually(fun, tries \\ 60) do
    Enum.reduce_while(1..tries, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end

  test "timeout lines in the stream surface as packet loss" do
    timeout = "Request timed out."

    start_supervised!(
      {SpikeMonitor,
       key: :lossy,
       host: "127.0.0.1",
       count: 4,
       window: 500,
       persist: false,
       stream_fun: fake_stream([@reply, @reply, @reply, timeout])},
      id: :lossy
    )

    Process.sleep(150)
    stats = SpikeMonitor.stats(:lossy)
    assert stats.sample_count > 0
    assert stats.loss_pct > 0.0
  end
end
