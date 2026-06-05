defmodule TrackConn.Measurements do
  @moduledoc """
  Context for storing and querying sweep history. Keeps the database concerns
  out of the monitor and the LiveView.
  """
  import Ecto.Query
  alias TrackConn.Repo
  alias TrackConn.Measurements.Sweep

  @doc """
  Persists a verdict (the map produced by `TrackConn.Diagnosis.analyze/1`) as a
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
      internet_rtt_ms: internet[:rtt_ms],
      internet_loss_pct: internet[:loss_pct],
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

  @doc "Sweeps since `datetime`, oldest first — for charting a window."
  def since(datetime) do
    Sweep
    |> where([s], s.inserted_at >= ^datetime)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  @doc "Total number of recorded sweeps."
  def count, do: Repo.aggregate(Sweep, :count)

  @doc """
  Deletes sweeps older than `max_age` seconds. Keeps the SQLite file bounded —
  a sweep every 5s is ~17k rows/day, so without this the history grows forever.
  Returns the number of rows deleted.
  """
  def prune(max_age_seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_seconds, :second)
    {deleted, _} = Sweep |> where([s], s.inserted_at < ^cutoff) |> Repo.delete_all()
    deleted
  end

  # Atom-keyed maps with atom values can't be stored as JSON directly; round-trip
  # through JSON-friendly forms (string keys, stringified atoms).
  defp jsonable(term), do: term |> Jason.encode!() |> Jason.decode!()
end
