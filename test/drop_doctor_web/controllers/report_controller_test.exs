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
