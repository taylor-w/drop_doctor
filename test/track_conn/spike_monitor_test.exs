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
