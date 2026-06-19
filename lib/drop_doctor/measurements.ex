defmodule DropDoctor.Measurements do
  @moduledoc """
  Context for storing and querying sweep history. Keeps the database concerns
  out of the monitor and the LiveView.
  """
  import Ecto.Query
  alias DropDoctor.Repo
  alias DropDoctor.Measurements.{SpikeEvent, Sweep}

  @doc """
  Persists a verdict (the map produced by `DropDoctor.Diagnosis.analyze/1`) as a
  sweep row, pulling the headline metrics out for fast charting.
  """
  def record(verdict) do
    seg = fn key -> Enum.find(verdict.segments, &(&1.key == key)) || %{metrics: %{}} end
    router = seg.(:router).metrics
    internet = seg.(:internet).metrics
    dns = seg.(:dns).metrics
    web = seg.(:web).metrics

    %Sweep{}
    |> Sweep.changeset(%{
      status: to_string(verdict.status),
      culprit: to_string(verdict.culprit),
      headline: verdict.headline,
      router_rtt_ms: router[:rtt_ms],
      router_loss_pct: router[:loss_pct],
      router_max_rtt_ms: router[:max_rtt_ms],
      router_jitter_ms: router[:jitter_ms],
      internet_rtt_ms: internet[:rtt_ms],
      internet_loss_pct: internet[:loss_pct],
      internet_max_rtt_ms: internet[:max_rtt_ms],
      internet_jitter_ms: internet[:jitter_ms],
      dns_ms: dns[:ms],
      web_ms: web[:ms],
      verdict: jsonable(verdict)
    })
    |> Repo.insert()
  end

  @doc "Most recent sweeps, newest first."
  def recent(limit \\ 60) do
    Sweep
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  A panning window into history: `limit` sweeps ending `offset` sweeps back from
  the newest, returned oldest-first (ready to chart). `offset: 0` is the live
  edge (most recent); larger offsets scroll further into the past.
  """
  def window(limit, offset \\ 0) do
    Sweep
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc "Sweeps since `datetime`, oldest first — for charting a window."
  def since(datetime) do
    Sweep
    |> where([s], s.inserted_at >= ^datetime)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  @doc "Total number of recorded sweeps."
  def count, do: Repo.aggregate(Sweep, :count)

  # --- spike events -------------------------------------------------------

  @doc "Persist one instability event (a latency spike or brief loss)."
  def record_spike_event(attrs) do
    %SpikeEvent{} |> SpikeEvent.changeset(attrs) |> Repo.insert()
  end

  @doc "Recent spike events, newest first."
  def recent_spike_events(limit \\ 1000) do
    SpikeEvent
    |> order_by(desc: :occurred_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Spike events that occurred within `[from, to]`, oldest first — for overlaying
  spike markers on the timeline window currently in view.
  """
  def spike_events_between(%DateTime{} = from, %DateTime{} = to) do
    SpikeEvent
    |> where([e], e.occurred_at >= ^from and e.occurred_at <= ^to)
    |> order_by(asc: :occurred_at)
    |> Repo.all()
  end

  def spike_events_between(_from, _to), do: []

  @doc "Total number of recorded spike events."
  def count_spike_events, do: Repo.aggregate(SpikeEvent, :count)

  @doc """
  Wipes *all* recorded history — every sweep and every spike event — for a clean
  slate. Irreversible; the UI guards it behind a confirmation and an "export
  first" nudge. Returns the total number of rows deleted.
  """
  def reset do
    {sweeps, _} = Repo.delete_all(Sweep)
    {events, _} = Repo.delete_all(SpikeEvent)
    sweeps + events
  end

  @doc """
  Deletes sweeps and spike events older than `max_age` seconds. Keeps the SQLite
  file bounded — a sweep every 5s is ~17k rows/day, so without this the history
  grows forever. Returns the total number of rows deleted.
  """
  def prune(max_age_seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_seconds, :second)
    {sweeps, _} = Sweep |> where([s], s.inserted_at < ^cutoff) |> Repo.delete_all()
    {events, _} = SpikeEvent |> where([e], e.occurred_at < ^cutoff) |> Repo.delete_all()
    sweeps + events
  end

  # Atom-keyed maps with atom values can't be stored as JSON directly; round-trip
  # through JSON-friendly forms (string keys, stringified atoms).
  defp jsonable(term), do: term |> Jason.encode!() |> Jason.decode!()
end
