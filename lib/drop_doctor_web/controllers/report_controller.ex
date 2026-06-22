defmodule DropDoctorWeb.ReportController do
  @moduledoc """
  Serves the exportable ISP report: a printable HTML page (`/report`) and the
  raw timeline as a CSV download (`/report.csv`). Both are built from
  `DropDoctor.Report`, which snapshots the live verdict, the latest deep trace,
  and the recorded history.
  """
  use DropDoctorWeb, :controller

  alias DropDoctor.{Monitor, Report, SpikeMonitor}
  alias DropDoctorWeb.ReportFeed

  @max_limit 20_000

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
  sweeps, spikes and speed tests appear with no manual refresh. The streaming
  itself lives in `DropDoctorWeb.ReportFeed`; this action just clamps the window,
  subscribes, and hands over a chunking connection.

  Security & privacy:

    * Read-only, same-origin `GET`. The payload is the same already-escaped HTML
      the printed page renders (`DropDoctor.Report.live_payload/1`), JSON-encoded
      so it can't break the SSE framing — no injection surface beyond the page.
    * The payload deliberately carries the *same* data as `/report`, including
      IPs/hostnames. Stream-safe privacy (blur/redact) is a client-side **view**
      toggle — "blur = hover to peek" only works with the value present — so
      redacting server-side would both break that UX and split the page and feed
      into two renderers. The app binds to loopback only (see `config/*.exs`), so
      this feed exposes nothing the same-origin page didn't already.
    * `?limit=` is clamped exactly like the printable report. It can't shrink to
      a cheaper live-only window without the first update visibly truncating the
      history table the page rendered, so the cost ceiling is, by design, the
      same as one `/report` render — paid at most ~1.3×/s via coalescing, and
      only re-sent per section when that section's HTML actually changed.
  """
  def live(conn, params) do
    lim = limit(params)

    # Subscribe *before* the first snapshot so a measurement recorded in the gap
    # between the page's render and this stream isn't missed. Both topics are
    # cheap signals that report content may have changed.
    Monitor.subscribe()
    Phoenix.PubSub.subscribe(DropDoctor.PubSub, SpikeMonitor.topic())

    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    # Defeat reverse-proxy / response buffering so events flush immediately.
    |> put_resp_header("x-accel-buffering", "no")
    |> send_chunked(200)
    |> ReportFeed.run_conn(fn -> Report.build(limit: lim) |> Report.live_payload() end)
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
