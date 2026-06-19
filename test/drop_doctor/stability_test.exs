defmodule DropDoctor.StabilityTest do
  use ExUnit.Case, async: true
  alias DropDoctor.Stability

  defp oks(rtts), do: Enum.map(rtts, &{:ok, &1})

  describe "spike?/2 — the single shared spike rule" do
    test "true only when > 2.5x baseline AND >= 30ms above it" do
      assert Stability.spike?(60.0, 20.0)
      # 4x the norm but only 9ms over the 3ms baseline — fails the absolute floor
      refute Stability.spike?(12.0, 3.0)
      # 45ms over but under 2.5x the 40ms baseline — fails the ratio
      refute Stability.spike?(85.0, 40.0)
    end

    test "non-numbers never spike" do
      refute Stability.spike?(nil, 20.0)
      refute Stability.spike?(100.0, nil)
    end
  end

  describe "summarize/1" do
    test "empty buffer is all-nil / zero, not a crash" do
      s = Stability.summarize([])
      assert s.sample_count == 0
      assert s.loss_pct == 0.0
      assert s.jitter_ms == nil
      assert s.spike_count == 0
    end

    test "steady low-latency stream: tiny jitter, no spikes" do
      s = Stability.summarize(oks([12.0, 12.1, 11.9, 12.0, 12.2, 11.8]))
      assert s.loss_pct == 0.0
      assert s.spike_count == 0
      assert s.jitter_ms < 1.0
      assert s.max_rtt_ms == 12.2
    end

    test "a buried spike is caught even when the average looks fine" do
      # one 180ms spike among otherwise-12ms samples — average barely moves,
      # but the spike must be surfaced.
      s = Stability.summarize(oks([12.0, 11.0, 13.0, 180.0, 12.0, 11.0, 12.0]))
      assert s.spike_count == 1
      assert s.max_rtt_ms == 180.0
      # jitter jumps because of the big consecutive deltas around the spike
      assert s.jitter_ms > 40.0
    end

    test "loss is counted from :loss samples" do
      s = Stability.summarize(oks([12.0, 12.0]) ++ [:loss, :loss])
      assert s.sample_count == 4
      assert s.loss_pct == 50.0
    end
  end

  describe "jitter/1 (IPDV)" do
    test "needs at least two samples" do
      assert Stability.jitter([12.0]) == nil
    end

    test "is the mean absolute consecutive delta" do
      # deltas: |20-10|, |10-20| = 10, 10 -> mean 10.0
      assert Stability.jitter([10.0, 20.0, 10.0]) == 10.0
    end
  end

  describe "burst_events/2" do
    test "no baseline yet (warming up) -> no latency event" do
      burst = %{times: [10.0, 200.0, 11.0], sent: 3, received: 3}
      assert Stability.burst_events(nil, burst) == []
    end

    test "a spike above the baseline is reported once per burst" do
      burst = %{times: [12.0, 180.0, 11.0], sent: 3, received: 3}

      assert [%{kind: :latency, peak_ms: 180.0, baseline_ms: 12.0, samples: 3}] =
               Stability.burst_events(12.0, burst)
    end

    test "small wobble within the floor is not a spike" do
      burst = %{times: [12.0, 20.0, 11.0], sent: 3, received: 3}
      assert Stability.burst_events(12.0, burst) == []
    end

    test "packet loss is its own event" do
      burst = %{times: [12.0, 11.0], sent: 4, received: 2}
      assert [%{kind: :loss, loss_pct: 50.0, samples: 4}] = Stability.burst_events(12.0, burst)
    end

    test "no baseline yet -> loss is NOT an event (unreachable target, not a loss burst)" do
      # A host that has never replied (no baseline) shouldn't manufacture endless
      # '100% loss' bursts — that's an ICMP-filtered/unreachable target, which the
      # 5s sweep handles, not an intermittent stutter.
      burst = %{times: [], sent: 10, received: 0}
      assert Stability.burst_events(nil, burst) == []
    end

    test "a burst can report both a spike and loss" do
      burst = %{times: [12.0, 190.0], sent: 4, received: 2}
      kinds = Stability.burst_events(12.0, burst) |> Enum.map(& &1.kind)
      assert :latency in kinds and :loss in kinds
    end
  end

  describe "percentile/2" do
    test "surfaces tail latency (nearest-rank)" do
      # 98 steady samples + 2 bad ones at the very top of the distribution
      rtts = List.duplicate(10.0, 98) ++ [400.0, 500.0]
      assert Stability.percentile(rtts, 50) == 10.0
      assert Stability.percentile(rtts, 99) == 400.0
      assert Stability.percentile(rtts, 100) == 500.0
    end

    test "empty list is nil" do
      assert Stability.percentile([], 95) == nil
    end
  end
end
