defmodule TrackConnWeb.DashboardLiveTest do
  use TrackConnWeb.ConnCase
  import Phoenix.LiveViewTest
  alias TrackConn.Test.FakeProbes

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
    assert html =~ "The path from you to the internet"
    assert html =~ "Deep diagnostic"
  end

  test "pause button toggles the monitor and updates the control", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert render(view) =~ "Pause"
    html = render_click(view, "toggle_monitor")
    assert html =~ "Resume"
  end
end
