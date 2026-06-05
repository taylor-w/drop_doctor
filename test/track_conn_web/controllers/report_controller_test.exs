defmodule TrackConnWeb.ReportControllerTest do
  use TrackConnWeb.ConnCase
  alias TrackConn.Test.FakeProbes

  setup do
    # The report endpoint reads the live verdict/deep-trace from a monitor
    # registered under the default name, just like the dashboard.
    start_supervised!(
      {TrackConn.Monitor,
       name: TrackConn.Monitor,
       persist: false,
       interval: 10_000,
       sweep_opts: [probes: FakeProbes.healthy()]}
    )

    :ok
  end

  test "GET /report serves a printable HTML report", %{conn: conn} do
    conn = get(conn, "/report")

    assert response_content_type(conn, :html) =~ "text/html"
    body = response(conn, 200)
    assert body =~ "<!doctype html>"
    assert body =~ "track_conn"
    assert body =~ "Save as PDF"
  end

  test "GET /report.csv downloads a CSV with the header row", %{conn: conn} do
    conn = get(conn, "/report.csv")

    assert response_content_type(conn, :csv) =~ "text/csv"

    assert get_resp_header(conn, "content-disposition") |> hd() =~
             "attachment; filename=\"track_conn-isp-report-"

    assert response(conn, 200) =~ "timestamp_utc,status,culprit,headline"
  end

  test "GET /report.csv clamps an absurd limit instead of erroring", %{conn: conn} do
    conn = get(conn, "/report.csv?limit=99999999")
    assert response(conn, 200) =~ "timestamp_utc"
  end
end
