defmodule DropDoctorWeb.DashboardLiveTest do
  use DropDoctorWeb.ConnCase
  import Phoenix.LiveViewTest
  alias DropDoctor.{Repo, Test.FakeProbes}
  alias DropDoctor.Measurements.Sweep

  setup do
    # The dashboard talks to a monitor registered under the default name.
    # Start one with fake probes and no persistence for a hermetic test.
    start_supervised!(
      {DropDoctor.Monitor,
       name: DropDoctor.Monitor,
       persist: false,
       interval: 10_000,
       sweep_opts: [probes: FakeProbes.healthy()]}
    )

    :ok
  end

  test "mounts and renders the dashboard without error", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "DropDoctor"
    assert html =~ "Re-check the connection now"
    assert html =~ "Recent history"
    # The pipeline hero (You → Router → Your ISP → Internet) replaced the old
    # "path from you to the internet" ladder.
    assert html =~ "Your ISP"
    assert html =~ "Live stability"
    assert html =~ "Deep diagnostic"
    assert html =~ "Speed test"
  end

  test "renders the theme picker with independent mode and colorway controls", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(aria-label="Choose a color theme")
    assert html =~ "Mode"
    assert html =~ "Colorway"

    # The loved system/light/dark mode segment (dispatches phx:set-theme).
    for mode <- ~w(system light dark) do
      assert html =~ ~s(data-phx-theme="#{mode}")
    end

    # Default + a representative spread of the new colorways (dispatch
    # phx:set-colorway). Mode and colorway compose into e.g. winter-dark.
    assert html =~ ~s(data-colorway="default")

    for colorway <- ~w(winter forest matrix rose cyberpunk) do
      assert html =~ ~s(data-colorway="#{colorway}")
    end

    # One swatch per colorway plus Default — locks the set so a stray add/remove
    # is caught against the canonical DropDoctor.Themes list.
    colorway_count =
      html |> String.split(~s(data-colorway=")) |> length() |> Kernel.-(1)

    assert colorway_count == 1 + length(DropDoctor.Themes.colorways())
  end

  test "renders the speed test module with a run button", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#run-speedtest")
    assert has_element?(view, "#speedtest")
  end

  describe "speed test" do
    test "starting the test pauses background monitoring and asks the browser to run", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      html = render_click(view, "speedtest_start")

      assert html =~ "Testing"
      # Monitoring is quieted so the saturation isn't logged as spikes.
      refute DropDoctor.Monitor.running?()
    end

    test "a browser result is persisted, shown, and resumes monitoring", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      payload = %{
        "ok" => true,
        "download_mbps" => 912.3,
        "upload_mbps" => 905.1,
        "latency_ms" => 14.2,
        "jitter_ms" => 1.1,
        "server" => "speed.cloudflare.com",
        "down_bytes" => 1_000_000,
        "up_bytes" => 1_000_000,
        "error" => nil
      }

      html = view |> element("#speedtest") |> render_hook("speedtest:result", payload)

      assert html =~ "912.3"
      assert html =~ "905.1"
      assert DropDoctor.Measurements.count_speed_tests() == 1
      assert DropDoctor.Monitor.running?()
    end
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

      seed_sweep(%{
        internet_rtt_ms: 120.0,
        router_rtt_ms: 4.0,
        status: "degraded",
        culprit: "isp"
      })

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

      assert render_click(view, "close_timeline") =~ "DropDoctor"
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

  describe "guided tour" do
    test "renders the tour trigger to the left of the privacy controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ ~s(data-tour-start)
      assert html =~ ~s(aria-label="Take a guided tour of DropDoctor")

      # It must sit before the visibility/privacy controls (and the theme picker)
      # in source order — that's the placement the user asked for.
      tour_at = index_of(html, "data-tour-start")
      privacy_at = index_of(html, ~s(data-tour="privacy"))
      theme_at = index_of(html, ~s(data-tour="theme"))

      assert tour_at < privacy_at,
             "tour button must render before the privacy controls"

      assert tour_at < theme_at,
             "tour button must render before the theme picker"
    end

    # The JS walkthrough (assets/js/tour.js) anchors each step to a
    # `data-tour="<key>"` marker. Those markers live in the templates, so the two
    # can drift silently — a renamed/removed anchor leaves a step pointing at
    # nothing. Assert every anchor the tour references is actually in the DOM.
    test "every anchor referenced by the tour exists in the rendered dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      anchors = tour_anchors()

      assert anchors != [],
             "expected to parse step anchors from assets/js/tour.js — did the STEPS shape change?"

      for anchor <- anchors do
        assert html =~ ~s(data-tour="#{anchor}"),
               ~s(tour step anchors [data-tour="#{anchor}"], but no such element renders on the dashboard)
      end
    end
  end

  test "clear data wipes recorded rows and confirms", %{conn: conn} do
    seed_sweep(%{internet_rtt_ms: 14.0, router_rtt_ms: 3.0})
    assert DropDoctor.Measurements.count() == 1

    {:ok, view, _html} = live(conn, "/")
    html = render_click(view, "clear_data")

    assert html =~ "Cleared"
    assert DropDoctor.Measurements.count() == 0
  end

  defp seed_sweep(attrs) do
    %Sweep{}
    |> Sweep.changeset(Map.merge(%{status: "healthy", culprit: "none"}, attrs))
    |> Repo.insert!()
  end

  # Position of the first occurrence of `needle` in `haystack` (or a large
  # sentinel if absent, so an ordering assertion fails loudly rather than passing
  # on a missing element).
  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {start, _len} -> start
      :nomatch -> 1_000_000_000
    end
  end

  # The non-null `anchor: "<key>"` values from the tour's STEPS array. Centered
  # steps (anchor: null) have no DOM marker and are intentionally excluded.
  defp tour_anchors do
    Regex.scan(~r/anchor:\s*"([a-z-]+)"/, File.read!("assets/js/tour.js"),
      capture: :all_but_first
    )
    |> List.flatten()
    |> Enum.uniq()
  end
end
