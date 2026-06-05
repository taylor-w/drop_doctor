defmodule TrackConn.ReportTest do
  use ExUnit.Case, async: true

  alias TrackConn.Report
  alias TrackConn.Measurements.Sweep
  alias TrackConn.PathReport
  alias TrackConn.Probes.Mtr

  @now ~U[2026-06-05 13:00:00Z]

  # A small, hand-built history: oldest at the tail (sweeps come newest-first).
  defp sweeps do
    [
      sweep("down", "isp", ~U[2026-06-05 12:59:55Z], internet_rtt: nil, internet_loss: 100.0),
      sweep("degraded", "isp", ~U[2026-06-05 12:59:50Z], internet_rtt: 120.0, internet_loss: 5.0),
      sweep("healthy", "none", ~U[2026-06-05 12:59:45Z], internet_rtt: 18.0, internet_loss: 0.0)
    ]
  end

  defp sweep(status, culprit, at, opts) do
    %Sweep{
      status: status,
      culprit: culprit,
      headline: "headline for #{status}",
      router_rtt_ms: 2.0,
      router_loss_pct: 0.0,
      internet_rtt_ms: Keyword.get(opts, :internet_rtt),
      internet_loss_pct: Keyword.get(opts, :internet_loss),
      dns_ms: 20.0,
      web_ms: 150.0,
      inserted_at: at
    }
  end

  defp verdict do
    %{
      status: :isp,
      culprit: :isp,
      headline: "This is your ISP — your router is fine but the internet is unreachable",
      detail: "Your router responds fine, but traffic to the open internet is failing.",
      action: "Save this report and contact your ISP.",
      segments: [
        %{
          key: :router,
          label: "Your router",
          about: "first hop",
          target: "192.168.1.1",
          state: :healthy,
          summary: "2ms"
        },
        %{
          key: :internet,
          label: "Open internet",
          about: "raw IP",
          target: "1.1.1.1",
          state: :down,
          summary: "100% packet loss"
        }
      ]
    }
  end

  defp deep_report do
    """
    {"report":{"mtr":{"src":"host","dst":"1.1.1.1"},"hubs":[
      {"count":1,"host":"192.168.1.1","Loss%":0.0,"Snt":10,"Last":1.0,"Avg":1.0,"Best":0.9,"Wrst":1.5,"StDev":0.2},
      {"count":2,"host":"edge.example-isp.net","Loss%":0.0,"Snt":10,"Last":12.0,"Avg":12.0,"Best":11.0,"Wrst":13.0,"StDev":0.5},
      {"count":3,"host":"one.one.one.one","Loss%":0.0,"Snt":10,"Last":11.5,"Avg":11.8,"Best":11.0,"Wrst":12.5,"StDev":0.4}
    ]}}
    """
    |> Mtr.parse("1.1.1.1")
    |> PathReport.analyze()
  end

  defp build(opts \\ []) do
    Report.build(
      Keyword.merge(
        [now: @now, verdict: verdict(), deep: deep_report(), sweeps: sweeps(), spike_events: []],
        opts
      )
    )
  end

  # Two logged instability events (newest first), for the spike-log tests.
  defp spike_events do
    [
      %TrackConn.Measurements.SpikeEvent{
        occurred_at: ~U[2026-06-05 12:59:52Z],
        segment: "internet",
        host: "1.1.1.1",
        kind: "latency",
        peak_ms: 180.0,
        baseline_ms: 14.0,
        loss_pct: nil,
        samples: 10
      },
      %TrackConn.Measurements.SpikeEvent{
        occurred_at: ~U[2026-06-05 12:59:40Z],
        segment: "internet",
        host: "1.1.1.1",
        kind: "loss",
        peak_ms: nil,
        baseline_ms: nil,
        loss_pct: 30.0,
        samples: 10
      }
    ]
  end

  describe "stats" do
    test "counts states, uptime, and the time window" do
      stats =
        Report.build(now: @now, verdict: verdict(), deep: nil, sweeps: sweeps(), spike_events: []).stats

      assert stats.total == 3
      assert stats.healthy == 1
      assert stats.degraded == 1
      assert stats.down == 1
      # 2 of 3 are not down
      assert stats.uptime == 67
    end

    test "is safe with no history" do
      stats =
        Report.build(now: @now, verdict: verdict(), deep: nil, sweeps: [], spike_events: []).stats

      assert stats.total == 0
      assert stats.uptime == 100
    end
  end

  describe "to_csv/1" do
    test "has a header and one row per sweep, oldest first" do
      csv = build() |> Report.to_csv()
      lines = String.split(csv, "\r\n", trim: true)

      assert hd(lines) ==
               "timestamp_utc,status,culprit,headline,router_rtt_ms,router_loss_pct,internet_rtt_ms,internet_loss_pct,dns_ms,web_ms"

      # 1 header + 3 data rows
      assert length(lines) == 4
      # oldest (healthy) row comes first
      assert Enum.at(lines, 1) =~ "2026-06-05T12:59:45Z,healthy,none"
      # newest (down) row comes last
      assert List.last(lines) =~ "2026-06-05T12:59:55Z,down,isp"
    end

    test "renders nil metrics as empty fields" do
      csv = build() |> Report.to_csv()
      down_row = csv |> String.split("\r\n") |> Enum.find(&String.contains?(&1, ",down,isp,"))

      # internet_rtt_ms is nil on the down row -> empty field between router_loss and internet_loss
      assert down_row =~ "2.0,0.0,,100.0,20.0"
    end

    test "quotes fields that contain commas or quotes" do
      tricky = [sweep("healthy", "none", @now, internet_rtt: 1.0, internet_loss: 0.0)]
      tricky = [%{hd(tricky) | headline: ~s(it's "fine", really)}]

      csv =
        Report.build(now: @now, verdict: verdict(), deep: nil, sweeps: tricky, spike_events: [])
        |> Report.to_csv()

      assert csv =~ ~s("it's ""fine"", really")
    end
  end

  describe "to_html/1" do
    test "is a self-contained document with the verdict and proof" do
      html = build() |> Report.to_html()

      assert html =~ "<!doctype html>"
      assert html =~ "track_conn"
      assert html =~ "This is your ISP"
      assert html =~ "Likely cause:"
      assert html =~ "Your ISP"
      # the ladder proof
      assert html =~ "192.168.1.1"
      assert html =~ "100% packet loss"
      # the deep trace
      assert html =~ "Per-hop trace"
      assert html =~ "edge.example-isp.net"
      # print affordance
      assert html =~ "Save as PDF"
      assert html =~ "window.print()"
    end

    test "escapes HTML in dynamic content" do
      v = %{verdict() | headline: "<script>alert(1)</script> & friends"}

      html =
        Report.build(now: @now, verdict: v, deep: nil, sweeps: sweeps(), spike_events: [])
        |> Report.to_html()

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt; &amp; friends"
    end

    test "handles a missing deep trace gracefully" do
      html =
        Report.build(now: @now, verdict: verdict(), deep: nil, sweeps: sweeps(), spike_events: [])
        |> Report.to_html()

      assert html =~ "No deep diagnostic has been run"
    end
  end

  describe "filename/2" do
    test "embeds the timestamp and extension" do
      assert Report.filename(:csv, @now) == "track_conn-isp-report-2026-06-05_1300Z.csv"
      assert Report.filename(:html, @now) == "track_conn-isp-report-2026-06-05_1300Z.html"
      assert Report.filename(:spikes, @now) == "track_conn-spike-log-2026-06-05_1300Z.csv"
    end
  end

  describe "spikes_csv/1 and the stability section" do
    test "CSV has the header and one row per event, oldest first" do
      csv =
        Report.build(
          now: @now,
          verdict: verdict(),
          deep: nil,
          sweeps: [],
          spike_events: spike_events()
        )
        |> Report.spikes_csv()

      lines = String.split(csv, "\r\n", trim: true)

      assert hd(lines) ==
               "timestamp_utc,segment,host,kind,peak_ms,baseline_ms,loss_pct,samples"

      assert length(lines) == 3
      # oldest (the loss event) first
      assert Enum.at(lines, 1) =~ "2026-06-05T12:59:40Z,internet,1.1.1.1,loss"
      assert List.last(lines) =~ "2026-06-05T12:59:52Z,internet,1.1.1.1,latency,180.0,14.0"
    end

    test "empty spike log still yields a valid header-only CSV" do
      csv =
        Report.build(now: @now, verdict: verdict(), deep: nil, sweeps: [], spike_events: [])
        |> Report.spikes_csv()

      assert csv == "timestamp_utc,segment,host,kind,peak_ms,baseline_ms,loss_pct,samples\r\n"
    end

    test "HTML report includes a stability section listing the events" do
      html =
        Report.build(
          now: @now,
          verdict: verdict(),
          deep: nil,
          sweeps: [],
          spike_events: spike_events()
        )
        |> Report.to_html()

      assert html =~ "Connection stability"
      assert html =~ "Latency spiked to 180.0ms"
      assert html =~ "30.0% packet loss"
    end
  end
end
