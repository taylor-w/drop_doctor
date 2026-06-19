defmodule DropDoctor.Probes.TcpStream do
  @moduledoc """
  Continuous reachability sampler over **TCP connect** instead of ICMP — for
  hosts that drop `ping` but still accept connections (the common home router
  that answers DNS on :53 / web admin on :80/:443 yet never replies to echo).

  It is drop-in compatible with `DropDoctor.Probes.Ping.stream/3`: it spawns a
  reader process, returns its pid, and emits `{:stream_line, reader, line}`
  messages whose text `DropDoctor.Probes.Ping.parse_stream_line/1` already
  understands — `"reply time=<ms> ms"` for a completed handshake, `"request
  timed out"` for a failed one. So `DropDoctor.SpikeMonitor` can swap to it with
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
    connect = Keyword.get(opts, :connect, &default_connect/2)
    spawn(fn -> loop(owner, host, ports, interval_ms, connect) end)
  end

  # The sampler only needs the connect time, so collapse the shared helper's
  # `{:ok, ms, port}` to `{:ok, ms}`; the injectable `:connect` keeps that shape.
  defp default_connect(host, ports) do
    case DropDoctor.Net.tcp_connect(host, ports, @connect_timeout) do
      {:ok, ms, _port} -> {:ok, ms}
      other -> other
    end
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
end
