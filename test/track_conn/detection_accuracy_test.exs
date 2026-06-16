defmodule TrackConn.DetectionAccuracyTest do
  @moduledoc """
  Trustworthiness / calibration suite.

  The unit tests (`stability_test.exs`, `probes/ping_test.exs`) prove the math and
  the parsing in isolation. This suite answers a different, higher-level question
  the user actually cares about:

      "Does the detector fire on the network conditions that genuinely break
       streaming and gameplay — and stay quiet on the conditions that don't?"

  Each scenario is named after a real-world condition and asserts BOTH detection
  (no misses) and, where relevant, non-detection (no false alarms). Thresholds are
  calibrated against published guidance:

    * Competitive gaming: ping < 30 ms, jitter < 5 ms ideal (30–50 ms is the
      tolerable ceiling), packet loss ≈ 0 (under 1–2%).
    * Live streaming / real-time video: packet loss < 1% good, > 1–2.5%
      degrades, > 5% breaks up.

  The point of this file is that those numbers are encoded as executable
  assertions, so a regression that desensitises (or over-sensitises) the detector
  fails CI instead of shipping.
  """
  use ExUnit.Case, async: true

  alias TrackConn.Stability

  defp oks(rtts), do: Enum.map(rtts, &{:ok, &1})
  defp mean(rtts), do: Enum.sum(rtts) / length(rtts)

  describe "no false alarms — a healthy link must read as healthy" do
    test "pristine competitive link (12 ms, sub-ms jitter): silent" do
      stream = oks([12.0, 12.1, 11.9, 12.0, 12.2, 11.8, 12.1, 11.9])
      s = Stability.summarize(stream)

      assert s.loss_pct == 0.0
      assert s.spike_count == 0
      # Comfortably below the 5 ms "ideal competitive jitter" line.
      assert s.jitter_ms < 5.0

      # And against a known-good baseline, a fresh batch raises no event.
      batch = %{times: [12.0, 12.1, 11.9, 12.0], sent: 4, received: 4}
      assert Stability.burst_events(12.0, batch) == []
    end

    test "merely-okay link (20–45 ms wobble): no discrete spike event raised" do
      # Moderate latency variation a casual player wouldn't notice. No single
      # sample clears the spike bar (> 2.5x median AND >= 30 ms over it), so we
      # must NOT cry wolf with a latency event...
      times = [20.0, 35.0, 25.0, 40.0, 28.0, 22.0]
      assert Stability.burst_events(median(times), %{times: times, sent: 6, received: 6}) == []
      assert Stability.summarize(oks(times)).spike_count == 0
    end
  end

  describe "real disruptions — must be caught" do
    test "gameplay-breaking latency spike (18 ms → 120 ms): caught as a spike" do
      # The classic rubber-banding cause: one round-trip jumps an order of
      # magnitude. Average barely moves; the spike signal must still fire.
      stream = oks([18.0, 17.0, 19.0, 120.0, 18.0, 17.0, 18.0])
      s = Stability.summarize(stream)

      assert s.spike_count >= 1
      assert s.max_rtt_ms == 120.0
      # The smoothed-average view would shrug: mean stays in the "fine" range.
      assert mean([18.0, 17.0, 19.0, 120.0, 18.0, 17.0, 18.0]) < 40.0

      burst = %{times: [18.0, 17.0, 120.0, 18.0], sent: 4, received: 4}
      assert [%{kind: :latency, peak_ms: 120.0}] = Stability.burst_events(18.0, burst)
    end

    test "brief micro-outage (2 of 10 packets dropped): caught as loss" do
      # A sub-second blackout — the thing the 5 s smoothed sweep is designed to
      # hide and the high-rate sampler exists to catch.
      burst = %{times: List.duplicate(15.0, 8), sent: 10, received: 8}
      assert [%{kind: :loss, loss_pct: 20.0, samples: 10}] = Stability.burst_events(15.0, burst)
    end

    test "streaming-killing sustained loss (~8% over the window): surfaced" do
      # 8% loss is well past the > 5% "video breaks up" line.
      window = oks(List.duplicate(20.0, 92)) ++ List.duplicate(:loss, 8)
      s = Stability.summarize(window)
      assert_in_delta s.loss_pct, 8.0, 0.01
      assert s.loss_pct > 5.0
    end

    test "bufferbloat tail (steady median, ugly p99): surfaced via percentiles" do
      # Encoder/queue buildup: most packets fine, the tail is what stutters the
      # stream. Median looks healthy; p99 tells the truth.
      window = oks(List.duplicate(18.0, 95) ++ [160.0, 180.0, 200.0, 220.0, 240.0])
      s = Stability.summarize(window)
      assert s.rtt_ms == 18.0
      assert s.p99_ms >= 160.0
      assert s.max_rtt_ms == 240.0
    end
  end

  describe "the core claim: high-rate sampler sees what the smoothed verdict hides" do
    test "a window whose AVERAGE looks healthy still exposes a buried spike + loss" do
      # Simulate ~1 minute of 5/s samples: a rock-steady 12 ms link with a single
      # 200 ms spike and a 3-packet micro-drop buried in it. The 5 s monitor
      # averages this into a verdict that looks fine; stability stats must not.
      window =
        oks(List.duplicate(12.0, 146) ++ [200.0]) ++
          List.duplicate(:loss, 3) ++ oks(List.duplicate(12.0, 150))

      s = Stability.summarize(window)
      delivered = for {:ok, ms} <- window, do: ms

      # What a smoothing/averaging view would report: "≈12 ms, looks fine."
      assert_in_delta mean(delivered), 12.6, 1.0

      # What the high-rate stability view reports instead: the spike and the
      # micro-outage are both visible.
      assert s.spike_count >= 1
      assert s.max_rtt_ms == 200.0
      assert s.loss_pct > 0.0
    end
  end

  # local copy of the median used by the detector, to phrase baselines clearly
  defp median(list), do: TrackConn.Aggregate.median(list)
end
