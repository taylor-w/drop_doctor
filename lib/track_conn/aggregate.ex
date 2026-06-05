defmodule TrackConn.Aggregate do
  @moduledoc """
  Turns a rolling window of recent raw sweeps into a single, smoothed sweep for
  the diagnosis — the Tier-1 "credibility" layer.

  The problem: a single noisy reading (a transient blip, OS scheduler jitter, a
  momentary Wi-Fi hiccup) shouldn't flip the verdict to red. A tool that cries
  wolf is worse than useless.

  The fix: judge each segment on the **median** across the window, not the
  latest sample. One bad reading among five barely moves the median, so spikes
  are ignored — but a *sustained* problem (several bad readings) does move it,
  and the verdict changes. The window size sets how long a fault must persist
  before it's believed. This gives amplitude-based debouncing for free.

  Returns results in the exact shape `Diagnosis.analyze/1` expects, with the
  metric fields replaced by their smoothed values and the latest raw output and
  `:def` preserved for display.
  """

  @doc """
  `window` is a list of raw sweeps (newest first), each `%{key => result}`.
  Returns a single smoothed sweep `%{key => result}`.
  """
  def summarize([latest_sweep | _] = window) do
    latest_sweep
    |> Map.keys()
    |> Map.new(fn key ->
      series = window |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1)
      {key, smooth(series)}
    end)
  end

  def summarize([]), do: %{}

  # series is newest-first; the head is the most recent reading whose def/raw we keep
  defp smooth([latest | _] = series) do
    case latest.def.kind do
      :ping -> smooth_ping(latest, series)
      :dns -> smooth_timed(latest, series)
      :http -> smooth_timed(latest, series)
      _ -> latest
    end
  end

  defp smooth_ping(latest, series) do
    loss = median(for s <- series, is_number(s[:loss_pct]), do: s.loss_pct)
    rtt = median(for s <- series, is_number(s[:rtt_ms]), do: s.rtt_ms)

    Map.merge(latest, %{
      loss_pct: loss || 100.0,
      rtt_ms: rtt,
      ok?: (loss || 100.0) < 100.0
    })
  end

  defp smooth_timed(latest, series) do
    ms = median(for s <- series, is_number(s[:ms]), do: s.ms)
    # ok? when more than half the recent readings succeeded
    oks = Enum.count(series, & &1[:ok?])
    Map.merge(latest, %{ms: ms, ok?: oks * 2 >= length(series)})
  end

  @doc "Median of a list of numbers; nil for an empty list."
  def median([]), do: nil

  def median(nums) do
    sorted = Enum.sort(nums)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end
end
