defmodule TrackConn.SpikeMonitorTest do
  # async: false — registers a named process and uses the shared ProbeSupervisor.
  use ExUnit.Case, async: false
  alias TrackConn.SpikeMonitor

  # A fake burst: returns canned samples after a short delay so the sampling
  # loop runs at a sane pace instead of spinning hot.
  defp fake_burst(_host, _opts) do
    Process.sleep(20)
    %{times: [10.0, 12.0, 11.0], sent: 3, received: 3, raw: "fake"}
  end

  setup do
    start_supervised!(
      {SpikeMonitor,
       key: :test, host: "127.0.0.1", count: 3, interval: 0.2, burst_fun: &fake_burst/2}
    )

    :ok
  end

  test "samples continuously, and pause/resume stops and restarts it" do
    assert SpikeMonitor.running?(:test)

    # a few bursts accumulate
    Process.sleep(80)
    n1 = SpikeMonitor.stats(:test).sample_count
    assert n1 > 0

    # pause: a cast ordered before this call, so it's already applied
    SpikeMonitor.pause(:test)
    refute SpikeMonitor.running?(:test)

    # let any in-flight burst settle, then confirm the count stops growing
    Process.sleep(80)
    n2 = SpikeMonitor.stats(:test).sample_count
    Process.sleep(80)
    assert SpikeMonitor.stats(:test).sample_count == n2

    # resume: sampling picks back up
    SpikeMonitor.resume(:test)
    assert SpikeMonitor.running?(:test)
    Process.sleep(80)
    assert SpikeMonitor.stats(:test).sample_count > n2
  end
end
