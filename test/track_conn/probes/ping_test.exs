defmodule TrackConn.Probes.PingTest do
  use ExUnit.Case, async: true
  alias TrackConn.Probes.Ping

  describe "parse/2 with real-world output" do
    test "Linux ping, all received" do
      out = """
      PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.
      64 bytes from 1.1.1.1: icmp_seq=1 ttl=55 time=14.9 ms
      64 bytes from 1.1.1.1: icmp_seq=2 ttl=55 time=7.71 ms
      64 bytes from 1.1.1.1: icmp_seq=3 ttl=55 time=13.3 ms

      --- 1.1.1.1 ping statistics ---
      3 packets transmitted, 3 received, 0% packet loss, time 2003ms
      rtt min/avg/max/mdev = 7.709/11.971/14.946/3.091 ms
      """

      r = Ping.parse(out, 3)
      assert r.ok?
      assert r.loss_pct == 0.0
      assert r.received == 3
      assert_in_delta r.rtt_ms, 11.971, 0.001
      # spike (max) and jitter (mdev) are surfaced, not collapsed into the avg
      assert_in_delta r.max_rtt_ms, 14.946, 0.001
      assert_in_delta r.jitter_ms, 3.091, 0.001
    end

    test "Linux ping, partial loss" do
      out = """
      --- 192.168.1.1 ping statistics ---
      4 packets transmitted, 3 received, 25% packet loss, time 3050ms
      rtt min/avg/max/mdev = 1.100/2.200/3.300/0.500 ms
      """

      r = Ping.parse(out, 4)
      assert r.ok?
      assert r.loss_pct == 25.0
      assert r.received == 3
      assert_in_delta r.rtt_ms, 2.2, 0.001
    end

    test "Linux ping, total loss" do
      out = """
      PING 10.0.0.99 (10.0.0.99) 56(84) bytes of data.

      --- 10.0.0.99 ping statistics ---
      3 packets transmitted, 0 received, 100% packet loss, time 2048ms
      """

      r = Ping.parse(out, 3)
      refute r.ok?
      assert r.loss_pct == 100.0
      assert r.received == 0
      assert r.rtt_ms == nil
    end

    test "macOS ping" do
      out = """
      PING 1.1.1.1 (1.1.1.1): 56 data bytes
      64 bytes from 1.1.1.1: icmp_seq=0 ttl=55 time=12.345 ms

      --- 1.1.1.1 ping statistics ---
      3 packets transmitted, 3 packets received, 0.0% packet loss
      round-trip min/avg/max/stddev = 11.100/12.345/13.500/0.900 ms
      """

      r = Ping.parse(out, 3)
      assert r.ok?
      assert r.loss_pct == 0.0
      assert r.received == 3
      assert_in_delta r.rtt_ms, 12.345, 0.001
      # macOS labels the 4th field "stddev"; positionally it's still jitter
      assert_in_delta r.max_rtt_ms, 13.500, 0.001
      assert_in_delta r.jitter_ms, 0.900, 0.001
    end

    test "Windows ping" do
      out = """
      Pinging 1.1.1.1 with 32 bytes of data:
      Reply from 1.1.1.1: bytes=32 time=13ms TTL=55

      Ping statistics for 1.1.1.1:
          Packets: Sent = 3, Received = 3, Lost = 0 (0% loss),
      Approximate round trip times in milli-seconds:
          Minimum = 11ms, Maximum = 16ms, Average = 13ms
      """

      r = Ping.parse(out, 3)
      assert r.ok?
      assert r.loss_pct == 0.0
      assert r.received == 3
      assert_in_delta r.rtt_ms, 13.0, 0.001
      # Windows reports Maximum but no jitter/stddev
      assert_in_delta r.max_rtt_ms, 16.0, 0.001
      assert r.jitter_ms == nil
    end
  end

  describe "parse_stream_line/1 — one line of continuous ping" do
    test "Linux/macOS reply line yields the round-trip time" do
      assert Ping.parse_stream_line("64 bytes from 1.1.1.1: icmp_seq=1 ttl=55 time=14.9 ms") ==
               {:ok, 14.9}
    end

    test "Windows reply line yields the round-trip time" do
      assert Ping.parse_stream_line("Reply from 1.1.1.1: bytes=32 time=13ms TTL=55") ==
               {:ok, 13.0}

      assert Ping.parse_stream_line("Reply from 192.168.1.1: bytes=32 time<1ms TTL=64") ==
               {:ok, 1.0}
    end

    test "timeout / unreachable lines are loss" do
      assert Ping.parse_stream_line("no answer yet for icmp_seq=7") == :loss
      assert Ping.parse_stream_line("Request timeout for icmp_seq 7") == :loss
      assert Ping.parse_stream_line("Request timed out.") == :loss

      assert Ping.parse_stream_line("From 10.0.0.1 icmp_seq=3 Destination Host Unreachable") ==
               :loss
    end

    test "banners, stats and blank lines are ignored" do
      assert Ping.parse_stream_line("PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.") == :ignore
      assert Ping.parse_stream_line("--- 1.1.1.1 ping statistics ---") == :ignore
      assert Ping.parse_stream_line("") == :ignore
    end
  end
end
