defmodule TrackConn.Probes.TcpStream do
  @moduledoc """
  Continuous reachability sampler over **TCP connect** instead of ICMP — for
  hosts that drop `ping` but still accept connections (the common home router
  that answers DNS on :53 / web admin on :80/:443 yet never replies to echo).

  It is drop-in compatible with `TrackConn.Probes.Ping.stream/3`: it spawns a
  reader process, returns its pid, and emits `{:stream_line, reader, line}`
  messages whose text `TrackConn.Probes.Ping.parse_stream_line/1` already
  understands — `"reply time=<ms> ms"` for a completed handshake, `"request
  timed out"` for a failed one. So `TrackConn.SpikeMonitor` can swap to it with
  no change to its parsing or windowing — only the measurement source differs
  (TCP connect time rather than round-trip ping).
  """

  @connect_timeout 1_000

  @doc """
  Start a resident TCP-connect sampler. `opts`:
    * `:interval` — seconds between connects (default 1.0)
    * `:ports`    — ports to try each tick, first to complete wins (default [443])
    * `:connect`  — injectable `(host, ports) -> {:ok, ms} | :error` for tests
  """
  def stream(owner, host, opts \\ []) do
    interval_ms = round(Keyword.get(opts, :interval, 1.0) * 1000)
    ports = Keyword.get(opts, :ports, [443])
    connect = Keyword.get(opts, :connect, &tcp_connect/2)
    spawn(fn -> loop(owner, host, ports, interval_ms, connect) end)
  end

  defp loop(owner, host, ports, interval_ms, connect) do
    line =
      case connect.(host, ports) do
        {:ok, ms} -> "reply time=#{ms} ms"
        _ -> "request timed out"
      end

    send(owner, {:stream_line, self(), line})
    Process.sleep(interval_ms)
    loop(owner, host, ports, interval_ms, connect)
  rescue
    e -> send(owner, {:stream_down, self(), Exception.message(e)})
  end

  # First port to complete a handshake wins; its connect time is the sample.
  defp tcp_connect(host, ports) do
    charlist = String.to_charlist(host)

    Enum.find_value(ports, :error, fn port ->
      t0 = System.monotonic_time(:millisecond)

      case :gen_tcp.connect(charlist, port, [:binary, active: false], @connect_timeout) do
        {:ok, sock} ->
          :gen_tcp.close(sock)
          {:ok, System.monotonic_time(:millisecond) - t0}

        {:error, _} ->
          nil
      end
    end)
  end
end
