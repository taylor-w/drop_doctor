defmodule DropDoctor.Stability do
  @moduledoc """
  Turns a rolling buffer of high-rate ping samples into the "stability" stats a
  gamer cares about — jitter, latency spikes, tail latency, and brief loss — the
  things the 5-second smoothed verdict deliberately hides.

  A sample is either `{:ok, rtt_ms}` (a reply) or `:loss` (no reply). Functions
  here are pure so they're easy to unit-test; `DropDoctor.SpikeMonitor` feeds them
  a continuous stream collected ~5×/second.
  """

  alias DropDoctor.Aggregate

  # A "spike" is an RTT well above the recent norm: more than 2.5× the median AND
  # at least 30ms above it (so a jump from 12→40ms counts, but 1→4ms doesn't).
  @spike_ratio 2.5
  @spike_floor_ms 30

  @doc "Summarize a sample buffer (`[{:ok, ms} | :loss]`) into a stats map."
  def summarize([]), do: empty()

  def summarize(samples) do
    rtts = for {:ok, ms} <- samples, do: ms
    sent = length(samples)
    received = length(rtts)
    # Sort once and derive median / percentiles / max from the sorted list — this
    # is the busiest resident path (every ~2s per host), and the previous shape
    # sorted the window ~4× per call. Jitter stays on the *arrival* order.
    sorted = Enum.sort(rtts)
    med = median_sorted(sorted)

    %{
      sample_count: sent,
      received: received,
      loss_pct: if(sent > 0, do: (sent - received) * 100.0 / sent, else: 0.0),
      rtt_ms: round1(med),
      jitter_ms: round1(jitter(rtts)),
      max_rtt_ms: round1(List.last(sorted)),
      p95_ms: round1(percentile_sorted(sorted, 95)),
      p99_ms: round1(percentile_sorted(sorted, 99)),
      spike_count: count_spikes(rtts, med)
    }
  end

  # Median of an already-sorted list — same rule as `DropDoctor.Aggregate.median/1`
  # (mean of the two middles on even length), without re-sorting.
  defp median_sorted([]), do: nil

  defp median_sorted(sorted) do
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  # Nearest-rank percentile of an already-sorted list (same rule as percentile/2).
  defp percentile_sorted([], _p), do: nil

  defp percentile_sorted(sorted, p) do
    idx = min(length(sorted) - 1, round(p / 100 * (length(sorted) - 1)))
    Enum.at(sorted, idx)
  end

  defp count_spikes(rtts, _med) when length(rtts) < 3, do: 0
  defp count_spikes(rtts, med), do: Enum.count(rtts, &spike?(&1, med))

  @doc "Stats shape with no data yet."
  def empty do
    %{
      sample_count: 0,
      received: 0,
      loss_pct: 0.0,
      rtt_ms: nil,
      jitter_ms: nil,
      max_rtt_ms: nil,
      p95_ms: nil,
      p99_ms: nil,
      spike_count: 0
    }
  end

  @doc """
  Detect discrete instability events in a single burst, given the recent
  `baseline` median (`nil` while warming up — no event detection until we know
  what "normal" is). Returns event attrs (no timestamp/host — the caller stamps
  those). A burst can yield a latency event, a loss event, or both.

  Both kinds require a numeric `baseline`: an event is a *deviation* from a
  working norm. A host that has never replied (no baseline) is unreachable, not
  intermittently lossy — surfacing that is the 5-second sweep's job (and its
  cross-layer corroboration), so we don't manufacture endless "100% loss bursts"
  for an ICMP-filtered target that real traffic is sailing past.
  """
  def burst_events(baseline, %{times: times, sent: sent, received: received}) do
    lost = max(sent - received, 0)

    latency =
      if is_number(baseline) and times != [] and spiking?(times, baseline) do
        [
          %{
            kind: :latency,
            peak_ms: round1(Enum.max(times)),
            baseline_ms: round1(baseline),
            samples: sent
          }
        ]
      else
        []
      end

    loss =
      if is_number(baseline) and lost > 0 and sent > 0 do
        [%{kind: :loss, loss_pct: round1(lost * 100.0 / sent), samples: sent}]
      else
        []
      end

    latency ++ loss
  end

  @doc """
  The single shared spike rule: `value` is a spike relative to `baseline` when it
  is more than 2.5× the baseline AND at least 30ms above it. Used by burst
  detection, the window spike count, and the cross-anchor corroboration check
  (`DropDoctor.SpikeMonitor.alt_verdict/2`) so all three agree on what a spike is.
  Returns false unless both arguments are numbers.
  """
  def spike?(value, baseline) when is_number(value) and is_number(baseline),
    do: value > baseline * @spike_ratio and value - baseline >= @spike_floor_ms

  def spike?(_value, _baseline), do: false

  defp spiking?(times, baseline), do: Enum.any?(times, &spike?(&1, baseline))

  @doc """
  Jitter as IPDV: the mean absolute difference between consecutive round-trips.
  This is the real measure of "how steady is the connection" — the thing that
  causes rubber-banding — not the average latency.
  """
  def jitter(rtts) when length(rtts) < 2, do: nil

  def jitter(rtts) do
    diffs =
      rtts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> abs(b - a) end)

    Enum.sum(diffs) / length(diffs)
  end

  @doc "How many samples in the window qualify as latency spikes."
  def spike_count(rtts) when length(rtts) < 3, do: 0

  def spike_count(rtts) do
    m = Aggregate.median(rtts)
    Enum.count(rtts, &spike?(&1, m))
  end

  @doc "Nearest-rank percentile (0–100). `nil` for an empty list."
  def percentile([], _p), do: nil

  def percentile(rtts, p) do
    sorted = Enum.sort(rtts)
    idx = min(length(sorted) - 1, round(p / 100 * (length(sorted) - 1)))
    Enum.at(sorted, idx)
  end

  defp round1(nil), do: nil
  defp round1(n), do: Float.round(n / 1, 1)
end
