defmodule TrackConn.SpikeAnalysis do
  @moduledoc """
  Cross-references logged spike events across segments to attribute each one to a
  *source* — your ISP versus something local (your machine / Wi-Fi / host
  scheduling) — without mutating the raw records.

  ## Why

  The router and internet `TrackConn.SpikeMonitor`s sample independently, so a
  single disturbance that stalls the *whole host* — the machine briefly pegged
  while gaming, a Wi-Fi hiccup, the WSL VM scheduled late — gets logged twice,
  once per segment. Read row-by-row that looks like both a "router fault" and an
  "ISP fault" at the same instant, which overstates the ISP's role and is exactly
  the kind of noise that makes the log sow doubt instead of confidence.

  But a delay that hits the local-router ping and the open-internet ping at the
  *same moment* cannot be your provider: your ISP can't slow down a packet that
  never leaves your house. So **co-occurring spikes are common-mode → local**;
  only an internet spike with *no* concurrent router spike is genuinely past your
  equipment. (Same rule as the live timeline's "a bump in both lines at once is
  local" note, applied to the historical log.)

  A co-occurring spike large enough to be implausible as real network latency
  (≥ `:artifact_ms`, default 1s) is flagged as a likely host/VM freeze rather
  than a network event at all — the multi-second "spikes" that are really the
  machine stalling both probes together.

  ## Contract

  Pure and order-independent. Give it spike-event structs (or maps with
  `:occurred_at`, `:segment`, `:peak_ms`); get them back with three derived keys
  added — `:source` (`:isp | :local | :host_freeze`), `:co_occurring?` and
  `:artifact?`. The database rows are never changed; this is a derived view.
  """

  # How close two segments' spikes must land to count as the same disturbance.
  # Deliberately tight: with only ~20-30 spikes/hour, a chance overlap is rare, so
  # a co-occurrence is almost always causal — and keeping it tight errs toward
  # leaving an event labelled ISP rather than falsely exonerating the provider.
  @window_ms 2_000
  # A co-occurring spike at least this large is almost certainly the host/VM
  # freezing both probes, not real network latency.
  @artifact_ms 1_000

  @doc "The default cross-segment co-occurrence window (ms) used by `annotate/2`."
  def co_window_ms, do: @window_ms

  @doc """
  Annotates each event with `:source`, `:co_occurring?` and `:artifact?`.

  Options:
    * `:window_ms` — co-occurrence window across segments (default #{@window_ms})
    * `:artifact_ms` — peak at/above which a co-occurring spike is a host freeze (default #{@artifact_ms})
  """
  def annotate(events, opts \\ [])

  def annotate([], _opts), do: []

  def annotate(events, opts) do
    window = Keyword.get(opts, :window_ms, @window_ms)
    artifact = Keyword.get(opts, :artifact_ms, @artifact_ms)

    router_ms = segment_ms(events, "router")
    internet_ms = segment_ms(events, "internet")

    Enum.map(events, fn e ->
      others = if e.segment == "router", do: internet_ms, else: router_ms
      co? = near?(others, event_ms(e), window)
      artifact? = co? and is_number(e.peak_ms) and e.peak_ms >= artifact

      e
      |> Map.put(:co_occurring?, co?)
      |> Map.put(:artifact?, artifact?)
      |> Map.put(:source, classify(e.segment, co?, artifact?, Map.get(e, :corroborated)))
    end)
  end

  @doc """
  Counts annotated events by source — `%{isp:, isp_unconfirmed:, local:,
  host_freeze:, total:}`. Handy for a one-line "of N spikes, X were ISP-side"
  summary.
  """
  def summarize(annotated) do
    empty = %{isp: 0, isp_unconfirmed: 0, local: 0, host_freeze: 0, total: 0}

    Enum.reduce(annotated, empty, fn e, acc ->
      acc
      |> Map.update!(:total, &(&1 + 1))
      |> Map.update!(e.source, &(&1 + 1))
    end)
  end

  @doc "Human label for a source tag."
  def source_label(:isp), do: "Your ISP"
  def source_label(:isp_unconfirmed), do: "Open internet — one route"
  def source_label(:local), do: "Local (machine / Wi-Fi)"
  def source_label(:host_freeze), do: "Local — host/Wi-Fi freeze"
  def source_label(_), do: "—"

  # A co-occurring spike big enough to be a stall is a host freeze; anything
  # co-occurring with the router (the local hop) is local. An internet spike with
  # no router twin is past your equipment — but only *confidently* your ISP if a
  # second provider's anchor degraded at the same instant (`corroborated == true`).
  # If the other anchor stayed clean it's just that one route (`false`); if we
  # couldn't corroborate (`nil`) we keep the prior behaviour and call it ISP.
  defp classify(_segment, true, true, _corrob), do: :host_freeze
  defp classify("router", _co?, _artifact?, _corrob), do: :local
  defp classify("internet", true, _artifact?, _corrob), do: :local
  defp classify("internet", false, _artifact?, false), do: :isp_unconfirmed
  defp classify("internet", false, _artifact?, _corrob), do: :isp
  defp classify(_segment, _co?, _artifact?, _corrob), do: :local

  defp segment_ms(events, segment) do
    for e <- events, e.segment == segment, do: event_ms(e)
  end

  defp near?(times, t, window), do: Enum.any?(times, &(abs(&1 - t) <= window))

  defp event_ms(%{occurred_at: %DateTime{} = at}), do: DateTime.to_unix(at, :millisecond)
  defp event_ms(_), do: 0
end
