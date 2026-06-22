defmodule DropDoctorWeb.ReportController do
  @moduledoc """
  Serves the exportable ISP report: a printable HTML page (`/report`) and the
  raw timeline as a CSV download (`/report.csv`). Both are built from
  `DropDoctor.Report`, which snapshots the live verdict, the latest deep trace,
  and the recorded history.
  """
  use DropDoctorWeb, :controller

  alias DropDoctor.{Monitor, Report, SpikeMonitor}

  @max_limit 20_000

  # Collapse a burst of measurement broadcasts into a single re-render: a 5s
  # sweep often lands alongside several spike-sampling updates, and we want one
  # push, not five. Bounds the per-viewer render/query rate to ~1.3/s.
  @coalesce_ms 750

  # Idle keepalive. A comment line proves the stream is alive and — more
  # importantly — fails to write once the client has gone, which is how we learn
  # to end the request (and drop the PubSub subscriptions with the process).
  @heartbeat_ms 20_000

  @doc "Printable HTML report — styled for the browser's Save-as-PDF."
  def show(conn, params) do
    html = Report.to_html(Report.build(limit: limit(params)))

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  @doc """
  Live report feed over Server-Sent Events. An open `/report` tab subscribes
  here and the report's dynamic sections are pushed as they change, so new
  sweeps, spikes and speed tests appear with no manual refresh.

  Read-only and same-origin. The payload is the same already-escaped HTML the
  printed page renders (see `DropDoctor.Report.live_payload/1`), JSON-encoded so
  it can't break the SSE framing — i.e. no new injection surface over the page
  itself. The `?limit=` window is clamped exactly like the printable report.
  """
  def live(conn, params) do
    lim = limit(params)

    # Subscribe *before* the first snapshot so nothing recorded in the gap is
    # missed. Both topics are cheap signals that report content may have changed.
    Monitor.subscribe()
    Phoenix.PubSub.subscribe(DropDoctor.PubSub, SpikeMonitor.topic())

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      # Defeat reverse-proxy / response buffering so events flush immediately.
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case push_snapshot(conn, lim) do
      {:ok, conn} -> stream_loop(conn, lim, nil)
      {:error, _closed} -> conn
    end
  end

  # Block on measurement broadcasts. A relevant message arms a single coalesced
  # flush; unrelated messages are ignored; an idle stretch sends a heartbeat. Any
  # failed write means the client is gone — returning `conn` ends the request,
  # and the process exit unsubscribes us from PubSub.
  defp stream_loop(conn, lim, pending) do
    receive do
      {:sweep, _verdict, _row} ->
        arm_flush(conn, lim, pending)

      {:stability, _key, _stats} ->
        arm_flush(conn, lim, pending)

      :dd_flush ->
        case push_snapshot(conn, lim) do
          {:ok, conn} -> stream_loop(conn, lim, nil)
          {:error, _closed} -> conn
        end

      _other ->
        stream_loop(conn, lim, pending)
    after
      @heartbeat_ms ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream_loop(conn, lim, pending)
          {:error, _closed} -> conn
        end
    end
  end

  # First event since the last flush schedules the coalesced render; further
  # events within the window are absorbed (the timer is already pending).
  defp arm_flush(conn, lim, nil) do
    Process.send_after(self(), :dd_flush, @coalesce_ms)
    stream_loop(conn, lim, :armed)
  end

  defp arm_flush(conn, lim, :armed), do: stream_loop(conn, lim, :armed)

  defp push_snapshot(conn, lim) do
    data = Report.build(limit: lim) |> Report.live_payload() |> Jason.encode!()
    chunk(conn, "data: #{data}\n\n")
  end

  @doc "CSV download of the sweep timeline, newest data named in the filename."
  def csv(conn, params) do
    report = Report.build(limit: limit(params))

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{Report.filename(:csv, report.generated_at)}")
    )
    |> send_resp(200, Report.to_csv(report))
  end

  @doc "CSV download of the logged instability events (spikes / brief loss)."
  def spikes_csv(conn, params) do
    report = Report.build(limit: limit(params))

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{Report.filename(:spikes, report.generated_at)}")
    )
    |> send_resp(200, Report.spikes_csv(report))
  end

  @doc "CSV download of the recorded download/upload speed tests."
  def speeds_csv(conn, params) do
    report = Report.build(limit: limit(params))

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{Report.filename(:speeds, report.generated_at)}")
    )
    |> send_resp(200, Report.speeds_csv(report))
  end

  # `?limit=N` lets a technician pull a wider window; clamped so a stray value
  # can't ask for an unbounded query.
  defp limit(%{"limit" => raw}) do
    case Integer.parse(to_string(raw)) do
      {n, _} when n > 0 -> min(n, @max_limit)
      _ -> 1000
    end
  end

  defp limit(_), do: 1000
end
