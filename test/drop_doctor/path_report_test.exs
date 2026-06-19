defmodule DropDoctor.PathReportTest do
  use ExUnit.Case, async: true
  alias DropDoctor.PathReport
  alias DropDoctor.Probes.Mtr

  # A healthy path with a phantom-loss hop (hop 3 = ??? at 100%, but every hop
  # after it is clean — classic ICMP rate-limiting, NOT real loss).
  @healthy_json """
  {"report":{"mtr":{"src":"host","dst":"1.1.1.1"},"hubs":[
    {"count":1,"host":"host.mshome.net","Loss%":0.0,"Snt":10,"Last":0.2,"Avg":0.2,"Best":0.1,"Wrst":0.3,"StDev":0.0},
    {"count":2,"host":"192.168.1.1","Loss%":0.0,"Snt":10,"Last":1.0,"Avg":1.1,"Best":0.9,"Wrst":1.5,"StDev":0.2},
    {"count":3,"host":"???","Loss%":100.0,"Snt":10,"Last":0.0,"Avg":0.0,"Best":0.0,"Wrst":0.0,"StDev":0.0},
    {"count":4,"host":"edge.example-isp.net","Loss%":0.0,"Snt":10,"Last":12.0,"Avg":12.0,"Best":11.0,"Wrst":13.0,"StDev":0.5},
    {"count":5,"host":"one.one.one.one","Loss%":0.0,"Snt":10,"Last":11.5,"Avg":11.8,"Best":11.0,"Wrst":12.5,"StDev":0.4}
  ]}}
  """

  # Sustained loss that begins at hop 4 and persists to the destination.
  @lossy_json """
  {"report":{"mtr":{"src":"host","dst":"1.1.1.1"},"hubs":[
    {"count":1,"host":"host.mshome.net","Loss%":0.0,"Snt":10,"Last":0.2,"Avg":0.2,"Best":0.1,"Wrst":0.3,"StDev":0.0},
    {"count":2,"host":"192.168.1.1","Loss%":0.0,"Snt":10,"Last":1.0,"Avg":1.1,"Best":0.9,"Wrst":1.5,"StDev":0.2},
    {"count":3,"host":"???","Loss%":100.0,"Snt":10,"Last":0.0,"Avg":0.0,"Best":0.0,"Wrst":0.0,"StDev":0.0},
    {"count":4,"host":"edge.example-isp.net","Loss%":40.0,"Snt":10,"Last":12.0,"Avg":12.0,"Best":11.0,"Wrst":13.0,"StDev":0.5},
    {"count":5,"host":"one.one.one.one","Loss%":40.0,"Snt":10,"Last":11.5,"Avg":11.8,"Best":11.0,"Wrst":12.5,"StDev":0.4}
  ]}}
  """

  # ISP hops (example-isp.net) followed by a bare-IP Cloudflare hop (172.68/16) before
  # the destination — the CDN hop must NOT be labeled as the user's ISP.
  @cdn_json """
  {"report":{"mtr":{"src":"host","dst":"1.1.1.1"},"hubs":[
    {"count":1,"host":"192.168.1.1","Loss%":0.0,"Snt":10,"Last":1.0,"Avg":1.0,"Best":0.9,"Wrst":1.5,"StDev":0.2},
    {"count":2,"host":"edge.example-isp.net","Loss%":0.0,"Snt":10,"Last":12.0,"Avg":12.0,"Best":11.0,"Wrst":13.0,"StDev":0.5},
    {"count":3,"host":"core.example-isp.net","Loss%":0.0,"Snt":10,"Last":12.5,"Avg":12.5,"Best":11.5,"Wrst":13.5,"StDev":0.5},
    {"count":4,"host":"172.68.36.2","Loss%":0.0,"Snt":10,"Last":13.0,"Avg":13.0,"Best":12.0,"Wrst":14.0,"StDev":0.5},
    {"count":5,"host":"one.one.one.one","Loss%":0.0,"Snt":10,"Last":11.5,"Avg":11.8,"Best":11.0,"Wrst":12.5,"StDev":0.4}
  ]}}
  """

  defp analyze(json), do: json |> Mtr.parse("1.1.1.1") |> PathReport.analyze()
  defp hop(report, n), do: Enum.find(report.hops, &(&1.count == n))

  describe "parsing" do
    test "maps mtr fields including the Loss% key" do
      result = Mtr.parse(@healthy_json, "1.1.1.1")
      assert result.ok?
      assert length(result.hops) == 5
      assert hd(result.hops).host == "host.mshome.net"
      assert Enum.at(result.hops, 2).host == "???"
      assert Enum.at(result.hops, 2).loss_pct == 100.0
    end
  end

  describe "healthy path with phantom loss" do
    setup do: %{r: analyze(@healthy_json)}

    test "is healthy with zero real end-to-end loss", %{r: r} do
      assert r.ok?
      assert r.status == :healthy
      assert r.end_loss == 0.0
      assert r.headline =~ "Clean path"
    end

    test "flags the ??? hop's 100% as phantom, not real", %{r: r} do
      h3 = hop(r, 3)
      assert h3.phantom_loss?
      refute h3.responded?
      refute h3.loss_onset?
    end

    test "no hop is marked as a loss origin", %{r: r} do
      refute Enum.any?(r.hops, & &1.loss_onset?)
    end

    test "classifies zones: local, ISP edge, destination", %{r: r} do
      assert hop(r, 1).zone == :local
      assert hop(r, 2).zone == :local
      assert hop(r, 4).zone == :isp_edge
      assert hop(r, 5).zone == :destination
    end
  end

  describe "sustained loss" do
    setup do: %{r: analyze(@lossy_json)}

    test "reports degraded with the real end-to-end loss", %{r: r} do
      assert r.status == :degraded
      assert r.end_loss == 40.0
    end

    test "pinpoints the onset at the first persistently-lossy hop", %{r: r} do
      assert hop(r, 4).loss_onset?
      refute hop(r, 5).loss_onset?
      assert r.headline =~ "hop 4"
    end

    test "still treats the phantom ??? hop as benign, not the culprit", %{r: r} do
      assert hop(r, 3).phantom_loss?
      refute hop(r, 3).loss_onset?
    end
  end

  describe "ISP vs transit/CDN zoning" do
    setup do: %{r: analyze(@cdn_json)}

    test "ISP hops are the ISP; the first is the edge", %{r: r} do
      assert hop(r, 2).zone == :isp_edge
      assert hop(r, 3).zone == :isp
    end

    test "the Cloudflare bare-IP hop is transit/CDN, not the user's ISP", %{r: r} do
      assert hop(r, 4).zone == :transit
    end

    test "the final hop is the destination", %{r: r} do
      assert hop(r, 5).zone == :destination
    end
  end

  describe "errors" do
    test "missing mtr yields a friendly report, not a crash" do
      r =
        PathReport.analyze(%{
          ok?: false,
          error: "mtr is not installed",
          raw: "hint",
          target: "1.1.1.1"
        })

      refute r.ok?
      assert r.headline =~ "needs mtr"
    end
  end
end
