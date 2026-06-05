defmodule TrackConn.Stability do
  @moduledoc """
  Turns a rolling buffer of high-rate ping samples into the "stability" stats a
  gamer cares about — jitter, latency spikes, tail latency, and brief loss — the
  things the 5-second smoothed verdict deliberately hides.

  A sample is either `{:ok, rtt_ms}` (a reply) or `:loss` (no reply). Functions
  here are pure so they're easy to unit-test; `TrackConn.SpikeMonitor` feeds them
  a continuous stream collected ~5×/second.
  """

  alias TrackConn.Aggregate

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

    %{
      sample_count: sent,
      loss_pct: if(sent > 0, do: (sent - received) * 100.0 / sent, else: 0.0),
      rtt_ms: round1(Aggregate.median(rtts)),
      jitter_ms: round1(jitter(rtts)),
      max_rtt_ms: round1(max_of(rtts)),
      p95_ms: round1(percentile(rtts, 95)),
      p99_ms: round1(percentile(rtts, 99)),
      spike_count: spike_count(rtts)
    }
  end

  @doc "Stats shape with no data yet."
  def empty do
    %{
      sample_count: 0,
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
  `baseline` median (`nil` while warming up — no spike detection until we know
  what "normal" is). Returns event attrs (no timestamp/host — the caller stamps
  those). A burst can yield a latency event, a loss event, or both.
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
      if lost > 0 and sent > 0 do
        [%{kind: :loss, loss_pct: round1(lost * 100.0 / sent), samples: sent}]
      else
        []
      end

    latency ++ loss
  end

  defp spiking?(times, baseline) do
    Enum.any?(times, fn r -> r > baseline * @spike_ratio and r - baseline >= @spike_floor_ms end)
  end

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
    Enum.count(rtts, fn r -> r > m * @spike_ratio and r - m >= @spike_floor_ms end)
  end

  @doc "Nearest-rank percentile (0–100). `nil` for an empty list."
  def percentile([], _p), do: nil

  def percentile(rtts, p) do
    sorted = Enum.sort(rtts)
    idx = min(length(sorted) - 1, round(p / 100 * (length(sorted) - 1)))
    Enum.at(sorted, idx)
  end

  defp max_of([]), do: nil
  defp max_of(list), do: Enum.max(list)

  defp round1(nil), do: nil
  defp round1(n), do: Float.round(n / 1, 1)
end
