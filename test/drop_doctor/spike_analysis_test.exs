defmodule DropDoctor.SpikeAnalysisTest do
  use ExUnit.Case, async: true

  alias DropDoctor.Measurements.SpikeEvent
  alias DropDoctor.SpikeAnalysis

  defp ev(segment, %DateTime{} = at, peak \\ 60.0) do
    %SpikeEvent{segment: segment, host: "h", kind: "latency", occurred_at: at, peak_ms: peak}
  end

  # An internet event carrying a corroboration verdict from the alternate anchor.
  defp inet(at, corroborated) do
    %SpikeEvent{
      segment: "internet",
      host: "h",
      kind: "latency",
      occurred_at: at,
      peak_ms: 60.0,
      corroborated: corroborated
    }
  end

  defp source_for(annotated, segment, at) do
    Enum.find(annotated, &(&1.segment == segment and &1.occurred_at == at)).source
  end

  test "an internet spike with no concurrent router spike is attributed to the ISP" do
    events = [ev("internet", ~U[2026-06-16 12:00:00Z])]
    [e] = SpikeAnalysis.annotate(events)

    assert e.source == :isp
    refute e.co_occurring?
    refute e.artifact?
  end

  test "router + internet spikes at the same instant are both local (common-mode), not ISP" do
    t = ~U[2026-06-16 12:00:00Z]
    annotated = SpikeAnalysis.annotate([ev("internet", t), ev("router", t)])

    assert source_for(annotated, "internet", t) == :local
    assert source_for(annotated, "router", t) == :local
    assert Enum.all?(annotated, & &1.co_occurring?)
  end

  test "a lone router spike is local — the router is the local hop" do
    [e] = SpikeAnalysis.annotate([ev("router", ~U[2026-06-16 12:00:00Z])])
    assert e.source == :local
  end

  test "co-occurrence respects the window: just outside it stays ISP" do
    inet = ~U[2026-06-16 12:00:00Z]
    router = ~U[2026-06-16 12:00:03Z]

    annotated =
      SpikeAnalysis.annotate([ev("internet", inet), ev("router", router)], window_ms: 2_000)

    assert source_for(annotated, "internet", inet) == :isp

    # widen the window and the same pair now reads as one local disturbance
    wider = SpikeAnalysis.annotate([ev("internet", inet), ev("router", router)], window_ms: 5_000)
    assert source_for(wider, "internet", inet) == :local
  end

  test "a multi-second spike on both segments at once is flagged a host freeze, not the network" do
    t = ~U[2026-06-16 12:00:00Z]
    annotated = SpikeAnalysis.annotate([ev("internet", t, 2048.0), ev("router", t, 2027.0)])

    assert source_for(annotated, "internet", t) == :host_freeze
    assert source_for(annotated, "router", t) == :host_freeze
    assert Enum.all?(annotated, & &1.artifact?)
  end

  test "a large but isolated internet spike is still the ISP — size alone isn't a freeze" do
    [e] = SpikeAnalysis.annotate([ev("internet", ~U[2026-06-16 12:00:00Z], 2000.0)])
    assert e.source == :isp
    refute e.artifact?
  end

  test "summarize counts events by source" do
    t = ~U[2026-06-16 12:00:00Z]

    annotated =
      SpikeAnalysis.annotate([
        ev("internet", ~U[2026-06-16 12:01:00Z]),
        ev("internet", t, 1500.0),
        ev("router", t, 1500.0)
      ])

    assert SpikeAnalysis.summarize(annotated) == %{
             isp: 1,
             isp_unconfirmed: 0,
             local: 0,
             host_freeze: 2,
             total: 3
           }
  end

  describe "second-anchor corroboration of internet spikes" do
    test "corroborated by the alt anchor -> confident ISP" do
      [e] = SpikeAnalysis.annotate([inet(~U[2026-06-16 12:00:00Z], true)])
      assert e.source == :isp
    end

    test "alt anchor stayed clean -> one route, not confidently your ISP" do
      [e] = SpikeAnalysis.annotate([inet(~U[2026-06-16 12:00:00Z], false)])
      assert e.source == :isp_unconfirmed
    end

    test "couldn't corroborate (nil) -> falls back to ISP (prior behaviour)" do
      [e] = SpikeAnalysis.annotate([inet(~U[2026-06-16 12:00:00Z], nil)])
      assert e.source == :isp
    end

    test "a router twin still wins over corroboration -> local, not ISP" do
      t = ~U[2026-06-16 12:00:00Z]
      annotated = SpikeAnalysis.annotate([inet(t, true), ev("router", t)])
      assert source_for(annotated, "internet", t) == :local
    end
  end

  test "annotate is order-independent and leaves an empty list empty" do
    assert SpikeAnalysis.annotate([]) == []
  end
end
