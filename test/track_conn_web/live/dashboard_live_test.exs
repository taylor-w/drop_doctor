defmodule TrackConnWeb.DashboardLiveTest do
  use TrackConnWeb.ConnCase
  import Phoenix.LiveViewTest
  alias TrackConn.{Repo, Test.FakeProbes}
  alias TrackConn.Measurements.Sweep

  setup do
    # The dashboard talks to a monitor registered under the default name.
    # Start one with fake probes and no persistence for a hermetic test.
    start_supervised!(
      {TrackConn.Monitor,
       name: TrackConn.Monitor,
       persist: false,
       interval: 10_000,
       sweep_opts: [probes: FakeProbes.healthy()]}
    )

    :ok
  end

  test "mounts and renders the dashboard without error", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "track_conn"
    assert html =~ "Test now"
    assert html =~ "Recent history"
    # The pipeline hero (You → Router → Your ISP → Internet) replaced the old
    # "path from you to the internet" ladder.
    assert html =~ "Your ISP"
    assert html =~ "Live stability"
    assert html =~ "Deep diagnostic"
  end

  test "pause button toggles the monitor and updates the control", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert render(view) =~ "Pause"
    html = render_click(view, "toggle_monitor")
    assert html =~ "Resume"
  end

  describe "expandable timeline (router vs. ISP)" do
    test "renders both series and the ISP differential band", %{conn: conn} do
      seed_sweep(%{internet_rtt_ms: 14.0, router_rtt_ms: 3.0})
      seed_sweep(%{internet_rtt_ms: 120.0, router_rtt_ms: 4.0, status: "degraded", culprit: "isp"})

      {:ok, view, _html} = live(conn, "/")
      html = render_click(view, "open_timeline")

      assert html =~ "router vs. ISP latency"
      assert html =~ "ISP added"
      # The chart is drawn client-side by the hook; the server ships the
      # precomputed geometry as JSON for it to render and pan over.
      assert html =~ ~s(id="tl-pan")
      assert html =~ "TimelinePan"
      assert html =~ "data-series"
      assert html =~ "data-offset"

      assert render_click(view, "close_timeline") =~ "track_conn"
      refute render(view) =~ "router vs. ISP latency"
    end

    test "shows an empty state when there's no history yet", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      assert render_click(view, "open_timeline") =~ "collecting data"
    end

    test "drag-pan scrolls into the past and jump-to-now returns live", %{conn: conn} do
      base = ~U[2026-06-14 12:00:00.000000Z]

      for i <- 0..119 do
        Repo.insert!(%Sweep{
          status: "healthy",
          culprit: "none",
          internet_rtt_ms: 14.0,
          router_rtt_ms: 3.0,
          inserted_at: DateTime.add(base, i, :second)
        })
      end

      {:ok, view, _html} = live(conn, "/")

      html = render_click(view, "open_timeline")
      assert html =~ "● Live"
      refute html =~ "Viewing past"

      # The hook pushes an absolute target offset as the cursor drags.
      html = render_click(view, "pan_to", %{"offset" => 20})
      assert html =~ "Viewing past"
      assert html =~ "Jump to now"
      # data-offset reflects the panned position for the hook to re-anchor on.
      assert html =~ ~s(data-offset="20")

      assert render_click(view, "jump_now") =~ "● Live"
    end
  end

  test "clear data wipes recorded rows and confirms", %{conn: conn} do
    seed_sweep(%{internet_rtt_ms: 14.0, router_rtt_ms: 3.0})
    assert TrackConn.Measurements.count() == 1

    {:ok, view, _html} = live(conn, "/")
    html = render_click(view, "clear_data")

    assert html =~ "Cleared"
    assert TrackConn.Measurements.count() == 0
  end

  defp seed_sweep(attrs) do
    %Sweep{}
    |> Sweep.changeset(Map.merge(%{status: "healthy", culprit: "none"}, attrs))
    |> Repo.insert!()
  end
end
