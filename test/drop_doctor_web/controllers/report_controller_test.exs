defmodule DropDoctorWeb.ReportControllerTest do
  use DropDoctorWeb.ConnCase
  alias DropDoctor.Test.FakeProbes

  setup do
    # The report endpoint reads the live verdict/deep-trace from a monitor
    # registered under the default name, just like the dashboard.
    start_supervised!(
      {DropDoctor.Monitor,
       name: DropDoctor.Monitor,
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
    assert body =~ "DropDoctor"
    assert body =~ "Save as PDF"
  end

  test "GET /report wires the page to the live feed for in-place updates", %{conn: conn} do
    body = conn |> get("/report") |> response(200)

    assert body =~ "/report/live"
    assert body =~ "EventSource"
    # live-update targets the rendering shares with the SSE feed
    assert body =~ ~s(id="dd-verdict")
    assert body =~ ~s(id="dd-stability")
  end

  # The SSE feed itself (`GET /report/live`) is a long-lived stream: its action
  # only returns when the client disconnects, so a blocking ConnTest request
  # would hang. Its payload is `Report.live_payload/1`, covered directly in
  # DropDoctor.ReportTest — the controller is a thin transport over it.

  test "GET /report.csv downloads a CSV with the header row", %{conn: conn} do
    conn = get(conn, "/report.csv")

    assert response_content_type(conn, :csv) =~ "text/csv"

    assert get_resp_header(conn, "content-disposition") |> hd() =~
             "attachment; filename=\"drop_doctor-isp-report-"

    assert response(conn, 200) =~ "timestamp_utc,status,culprit,headline"
  end

  test "GET /report.csv clamps an absurd limit instead of erroring", %{conn: conn} do
    conn = get(conn, "/report.csv?limit=99999999")
    assert response(conn, 200) =~ "timestamp_utc"
  end

  test "GET /speeds.csv downloads the speed-test CSV with the header row", %{conn: conn} do
    conn = get(conn, "/speeds.csv")

    assert response_content_type(conn, :csv) =~ "text/csv"

    assert get_resp_header(conn, "content-disposition") |> hd() =~
             "attachment; filename=\"drop_doctor-speed-tests-"

    assert response(conn, 200) =~ "timestamp_utc,download_mbps,upload_mbps"
  end
end
