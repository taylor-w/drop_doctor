defmodule TrackConnWeb.ReportController do
  @moduledoc """
  Serves the exportable ISP report: a printable HTML page (`/report`) and the
  raw timeline as a CSV download (`/report.csv`). Both are built from
  `TrackConn.Report`, which snapshots the live verdict, the latest deep trace,
  and the recorded history.
  """
  use TrackConnWeb, :controller

  alias TrackConn.Report

  @max_limit 20_000

  @doc "Printable HTML report — styled for the browser's Save-as-PDF."
  def show(conn, params) do
    html = Report.to_html(Report.build(limit: limit(params)))

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
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
