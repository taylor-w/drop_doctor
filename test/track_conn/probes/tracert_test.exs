defmodule TrackConn.Probes.TracertTest do
  use ExUnit.Case, async: true
  alias TrackConn.Probes.Tracert
  alias TrackConn.PathReport

  @sample """
  Tracing route to one.one.one.one [1.1.1.1]
  over a maximum of 30 hops:

    1     1 ms    <1 ms    <1 ms  192.168.1.1
    2    10 ms     9 ms    11 ms  dsldevice.lan [192.168.1.254]
    3     *        *        *     Request timed out.
    4    14 ms    13 ms    15 ms  core1.example-isp.net [203.0.113.1]
    5    12 ms    13 ms    12 ms  one.one.one.one [1.1.1.1]

  Trace complete.
  """

  describe "parse/2" do
    test "parses every hop line and ignores the localized banner/footer" do
      %{ok?: true, hops: hops, target: target} = Tracert.parse(@sample, "1.1.1.1")
      assert target == "1.1.1.1"
      assert length(hops) == 5
      assert Enum.map(hops, & &1.count) == [1, 2, 3, 4, 5]
    end

    test "bare IP, named hop, and sub-ms RTTs" do
      [h1, h2 | _] = Tracert.parse(@sample, "1.1.1.1").hops

      assert h1.host == "192.168.1.1"
      assert h1.loss_pct == 0.0
      assert h1.avg == 1.0

      # Reverse-DNS name is preferred over the bracketed IP so PathReport can map
      # the hop to an ISP domain.
      assert h2.host == "dsldevice.lan"
      assert h2.avg == 10.0
      assert h2.best == 9.0
      assert h2.worst == 11.0
      assert h2.sent == 3
    end

    test "a fully timed-out hop reads as a non-responder with 100% loss" do
      h3 = Enum.at(Tracert.parse(@sample, "1.1.1.1").hops, 2)
      assert h3.host == "???"
      assert h3.loss_pct == 100.0
      assert h3.avg == nil
    end

    test "a partially timed-out hop yields coarse per-probe loss" do
      out = "  4    12 ms     *       14 ms  core1.example-isp.net [203.0.113.1]\n"
      [h] = Tracert.parse(out, "1.1.1.1").hops
      assert h.host == "core1.example-isp.net"
      assert_in_delta h.loss_pct, 33.3, 0.1
      assert h.avg == 13.0
      assert h.sent == 3
    end

    test "non-English 'request timed out' text still parses (locale independence)" do
      out = "  7     *        *        *     Zeitüberschreitung der Anforderung.\n"
      [h] = Tracert.parse(out, "1.1.1.1").hops
      assert h.count == 7
      assert h.host == "???"
      assert h.loss_pct == 100.0
    end

    test "garbage with no hop lines is a friendly error, not a crash" do
      assert %{ok?: false, error: "could not parse tracert output"} =
               Tracert.parse("not tracert output at all", "1.1.1.1")
    end
  end

  test "the parsed result flows through PathReport unchanged (drop-in for mtr)" do
    report = @sample |> Tracert.parse("1.1.1.1") |> PathReport.analyze()
    assert report.ok?
    assert report.target == "1.1.1.1"
    # The destination hop responded, so end-to-end loss is clean.
    assert report.status == :healthy
    assert length(report.hops) == 5
  end

  test "available?/0 is false off Windows (this host)" do
    refute Tracert.available?()
  end
end
