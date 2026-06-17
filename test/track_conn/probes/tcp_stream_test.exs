defmodule TrackConn.Probes.TcpStreamTest do
  use ExUnit.Case, async: true

  alias TrackConn.Probes.{Ping, TcpStream}

  test "emits a ping-shaped 'reply time=' line a successful connect parses" do
    connect = fn _host, _ports -> {:ok, 4} end

    reader =
      TcpStream.stream(self(), "192.168.1.1", interval: 0.01, ports: [53], connect: connect)

    assert_receive {:stream_line, ^reader, line}, 500
    assert line =~ "time=4"
    # And the SpikeMonitor's existing parser turns it into a sample.
    assert Ping.parse_stream_line(line) == {:ok, 4.0}

    Process.exit(reader, :kill)
  end

  test "emits a timeout line a failed connect parses as loss" do
    connect = fn _host, _ports -> :error end

    reader =
      TcpStream.stream(self(), "192.168.1.1", interval: 0.01, ports: [53], connect: connect)

    assert_receive {:stream_line, ^reader, line}, 500
    assert Ping.parse_stream_line(line) == :loss

    Process.exit(reader, :kill)
  end
end
