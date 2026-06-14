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
       key: :test,
       host: "127.0.0.1",
       count: 3,
       interval: 0.2,
       persist: false,
       burst_fun: &fake_burst/2}
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

  # A burst_fun that reports the interval it was actually asked to probe at, so we
  # can observe the adaptive-resolution behaviour from the outside.
  defp reporting_burst(parent, result) do
    fn _host, opts ->
      send(parent, {:interval, Keyword.get(opts, :interval)})
      Process.sleep(5)
      result
    end
  end

  test "relaxes the sampling interval after a calm streak, staying gap-free" do
    calm = %{times: [10.0, 11.0, 10.5], sent: 3, received: 3, raw: "calm"}

    start_supervised!(
      {SpikeMonitor,
       key: :calm,
       host: "127.0.0.1",
       count: 3,
       interval: 0.2,
       calm_interval: 0.5,
       calm_streak: 2,
       persist: false,
       burst_fun: reporting_burst(self(), calm)},
      id: :calm
    )

    # Early bursts probe at the fast spacing...
    assert_receive {:interval, 0.2}, 500
    # ...then, once the calm streak is met, relax to the calm spacing.
    assert_receive {:interval, 0.5}, 1_000
  end

  test "keeps the fast interval while the link is lossy" do
    lossy = %{times: [10.0, 11.0], sent: 3, received: 2, raw: "1 lost"}

    start_supervised!(
      {SpikeMonitor,
       key: :lossy,
       host: "127.0.0.1",
       count: 3,
       interval: 0.2,
       calm_interval: 0.5,
       calm_streak: 2,
       persist: false,
       burst_fun: reporting_burst(self(), lossy)},
      id: :lossy
    )

    assert_receive {:interval, 0.2}, 500
    # Several bursts later it must still be fast — loss resets the calm streak.
    Process.sleep(100)
    refute_received {:interval, 0.5}
  end

  test "keeps the fast interval while jitter is high, even with full delivery" do
    # Every packet replied (no loss, no spike event), but the round-trips swing
    # wildly: ~90ms of jitter. Calmness is judged on the burst's own jitter, so
    # this must never relax — proves we sense per-burst, not over the window.
    jittery = %{times: [10.0, 100.0, 10.0], sent: 3, received: 3, raw: "jittery"}

    start_supervised!(
      {SpikeMonitor,
       key: :jittery,
       host: "127.0.0.1",
       count: 3,
       interval: 0.2,
       calm_interval: 0.5,
       calm_streak: 2,
       persist: false,
       burst_fun: reporting_burst(self(), jittery)},
      id: :jittery
    )

    assert_receive {:interval, 0.2}, 500
    Process.sleep(100)
    refute_received {:interval, 0.5}
  end
end
