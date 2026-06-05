defmodule TrackConn.Probes.Ping do
  @moduledoc """
  ICMP ping probe via the system `ping` binary.

  We shell out to `ping` rather than crafting raw ICMP packets because raw
  sockets require elevated privileges, whereas `ping` is setuid/available
  unprivileged on essentially every OS. The trade-off is that we must parse
  human-formatted output, which differs by platform — handled below.

  Returns a map:

      %{
        ok?: boolean,           # did at least one packet come back?
        rtt_ms: float | nil,    # average round-trip time
        max_rtt_ms: float | nil, # worst single round-trip (the latency spike)
        jitter_ms: float | nil, # mean deviation of RTT (mdev/stddev); nil on Windows
        loss_pct: float,        # packet loss percentage (0.0 - 100.0)
        sent: integer,
        received: integer,
        raw: String.t(),        # raw command output, for the "show me the proof" view
        error: String.t() | nil
      }

  `max_rtt_ms` and `jitter_ms` are the spike/jitter signals a gamer cares about:
  `ping` already prints them (`min/avg/max/mdev`), we just surface them instead of
  collapsing everything to the average.
  """

  @behaviour TrackConn.Probe

  @default_count 3
  # seconds we are willing to wait per packet before giving up
  @default_timeout 2

  def run(host, opts \\ []) do
    count = Keyword.get(opts, :count, @default_count)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    try do
      {cmd, args} = command(host, count, timeout)

      case System.cmd(cmd, args, stderr_to_stdout: true) do
        {out, _exit} -> parse(out, count)
        _ -> failure(count)
      end
    rescue
      e -> failure(count, Exception.message(e))
    end
  end

  defp command(host, count, timeout) do
    case :os.type() do
      {:win32, _} ->
        {"ping", ["-n", to_string(count), "-w", to_string(timeout * 1000), host]}

      {:unix, :darwin} ->
        # macOS: -t is total timeout in seconds for the whole run
        {"ping", ["-c", to_string(count), "-t", to_string(timeout * count), host]}

      {:unix, _} ->
        # Linux: -W is per-packet reply timeout (seconds)
        {"ping", ["-c", to_string(count), "-W", to_string(timeout), host]}
    end
  end

  @doc """
  Runs one high-rate burst of pings and returns the *per-packet* round-trip
  times (plus sent/received for loss). This is what `TrackConn.SpikeMonitor`
  calls back-to-back for continuous sampling — unlike `run/2`, which collapses a
  burst to its average.

  `interval` spacing is sub-second on Linux/macOS; Windows can't do sub-second
  intervals unprivileged, so there it sends `count` packets at its ~1s default.

  Returns `%{times: [float], sent: integer, received: integer, raw: String.t()}`.
  """
  def burst(host, opts \\ []) do
    count = Keyword.get(opts, :count, 10)
    interval = Keyword.get(opts, :interval, 0.2)
    timeout = Keyword.get(opts, :timeout, 1)

    try do
      {cmd, args} = burst_command(host, count, interval, timeout)

      case System.cmd(cmd, args, stderr_to_stdout: true) do
        {out, _exit} ->
          loss = parse_loss(out)

          %{
            times: packet_times(out),
            sent: count,
            received: parse_received(out, count, loss),
            raw: String.trim(out)
          }

        _ ->
          burst_failure(count)
      end
    rescue
      e -> burst_failure(count, Exception.message(e))
    end
  end

  defp burst_command(host, count, interval, timeout) do
    case :os.type() do
      {:win32, _} ->
        # No sub-second interval on Windows; -n sends `count` at the default ~1s.
        {"ping", ["-n", to_string(count), "-w", to_string(timeout * 1000), host]}

      {:unix, :darwin} ->
        total = max(1, round(interval * count) + timeout)

        {"ping",
         ["-c", to_string(count), "-i", to_string(interval), "-t", to_string(total), host]}

      {:unix, _} ->
        {"ping",
         ["-c", to_string(count), "-i", to_string(interval), "-W", to_string(timeout), host]}
    end
  end

  # Each reply line carries the per-packet time: "time=14.9 ms" (Unix) or
  # "time=13ms" / "time<1ms" (Windows). Scan them all out of one burst.
  defp packet_times(out) do
    ~r/time[=<]\s*([\d.]+)\s*ms/i
    |> Regex.scan(out)
    |> Enum.map(fn [_, t] -> parse_float(t) end)
    |> Enum.reject(&is_nil/1)
  end

  defp burst_failure(count, raw \\ "ping failed"),
    do: %{times: [], sent: count, received: 0, raw: raw}

  @doc """
  Parses raw `ping` output into the result map. Public so the cross-platform
  parsing — the most fragile part — can be regression-tested against real
  output captured on each OS.
  """
  def parse(out, count) do
    loss = parse_loss(out)
    rtt = parse_rtt(out)
    received = parse_received(out, count, loss)

    %{
      ok?: received > 0,
      rtt_ms: rtt,
      max_rtt_ms: parse_max(out),
      jitter_ms: parse_jitter(out),
      loss_pct: loss,
      sent: count,
      received: received,
      raw: String.trim(out),
      error: if(received > 0, do: nil, else: "no reply")
    }
  end

  # "0% packet loss" (Linux/mac)  or  "(0% loss)" (Windows)
  defp parse_loss(out) do
    cond do
      m = Regex.run(~r/([\d.]+)%\s*packet loss/, out) -> parse_float(Enum.at(m, 1))
      m = Regex.run(~r/\(([\d.]+)%\s*loss\)/, out) -> parse_float(Enum.at(m, 1))
      true -> 100.0
    end
  end

  # Linux/mac: "= 11.779/13.886/16.199/1.810 ms" -> avg is field 2
  # Windows:   "Average = 13ms"
  defp parse_rtt(out) do
    cond do
      m = Regex.run(~r/=\s*[\d.]+\/([\d.]+)\//, out) -> parse_float(Enum.at(m, 1))
      m = Regex.run(~r/Average\s*=\s*([\d.]+)\s*ms/i, out) -> parse_float(Enum.at(m, 1))
      true -> nil
    end
  end

  # Worst round-trip — the spike. Linux/mac: 3rd field of "min/avg/max/mdev".
  # Windows: "Maximum = 16ms".
  defp parse_max(out) do
    cond do
      m = Regex.run(~r/=\s*[\d.]+\/[\d.]+\/([\d.]+)\//, out) -> parse_float(Enum.at(m, 1))
      m = Regex.run(~r/Maximum\s*=\s*([\d.]+)\s*ms/i, out) -> parse_float(Enum.at(m, 1))
      true -> nil
    end
  end

  # Jitter = ping's mean deviation (mdev/stddev), the 4th field of the rtt line.
  # Windows `ping` doesn't report it, so jitter is nil there.
  defp parse_jitter(out) do
    case Regex.run(~r/=\s*[\d.]+\/[\d.]+\/[\d.]+\/([\d.]+)\s*ms/, out) do
      [_, mdev] -> parse_float(mdev)
      _ -> nil
    end
  end

  defp parse_received(out, count, loss) do
    cond do
      # Linux: "3 received" ; mac: "3 packets received"
      m = Regex.run(~r/(\d+)\s+(?:packets\s+)?received/, out) ->
        String.to_integer(Enum.at(m, 1))

      # Windows: "Received = 3"
      m = Regex.run(~r/Received\s*=\s*(\d+)/i, out) ->
        String.to_integer(Enum.at(m, 1))

      true ->
        round(count * (100.0 - loss) / 100.0)
    end
  end

  defp failure(count, msg \\ "ping failed") do
    %{
      ok?: false,
      rtt_ms: nil,
      max_rtt_ms: nil,
      jitter_ms: nil,
      loss_pct: 100.0,
      sent: count,
      received: 0,
      raw: msg,
      error: msg
    }
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> nil
    end
  end
end
