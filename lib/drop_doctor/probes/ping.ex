defmodule DropDoctor.Probes.Ping do
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

  @behaviour DropDoctor.Probe

  @default_count 3
  # seconds we are willing to wait per packet before giving up
  @default_timeout 2

  # Babysitter wrapper for the *resident* ping (see `run_stream/3`). It guarantees
  # the OS ping dies when the Erlang port closes (pause / anchor-switch) OR the
  # BEAM itself dies abnormally (crash, Ctrl-C, the WSL host sleeping). Mechanism:
  #
  #   * `exec 3<&0` saves the port's stdin — a *backgrounded* subshell otherwise
  #     inherits /dev/null for stdin, so the watcher would see EOF immediately.
  #   * the watcher blocks on that fd via `cat <&3`; the instant the port (or the
  #     whole BEAM) goes away the pipe closes, `cat` returns, and it TERMs ping.
  #   * if ping exits on its own, `wait` returns and the wrapper exits too, so the
  #     monitor still sees `:exit_status` and restarts the stream.
  #
  # ping args are passed positionally (`"$@"`), never spliced into the script, so
  # a host string can't inject shell. Without this, iputils `ping` ignores the
  # closed pipe (it doesn't read stdin and shrugs off SIGPIPE) and keeps sending
  # forever; orphaned resident pings then pile up across restarts into a
  # self-inflicted ICMP flood that gets our own probe targets rate-limited.
  @babysitter ~S"""
  exec 3<&0
  "$@" & pid=$!
  ( cat <&3 >/dev/null; kill -TERM "$pid" 2>/dev/null ) &
  wait "$pid"; rc=$?
  kill -TERM "$!" 2>/dev/null
  exit "$rc"
  """

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
  Starts a *continuous* ping as one long-lived OS process and forwards each
  per-packet result to `owner` as a message. This is what `DropDoctor.SpikeMonitor`
  uses for gap-free stability sampling.

  Why one resident process instead of repeated short bursts (the old approach):
  spawning a fresh `ping` every couple of seconds makes the *measured* RTT
  sensitive to host CPU scheduling — under load the short-lived process is
  descheduled between sending a packet and reading its reply, and reports inflated
  latency the network never saw. A single process that stays warm avoids that
  per-burst startup cost and measures the wire, not the scheduler.

  Spawns a small reader process that owns the port and returns its pid. The caller
  should `Process.monitor/1` it; killing it closes the port and stops the OS
  `ping`. Messages delivered to `owner`:

    * `{:stream_line, reader_pid, line}` — one raw output line (parse with `parse_stream_line/1`)
    * `{:stream_down, reader_pid, reason}` — the ping process ended

  `interval` is the spacing in seconds (Unix `-i`); Windows ignores it and runs at
  its ~1s default.
  """
  def stream(owner, host, opts \\ []) do
    interval = Keyword.get(opts, :interval, 1.0)
    spawn(fn -> run_stream(owner, host, interval) end)
  end

  @doc """
  Best-effort cleanup of *orphaned* resident pings — ones left sending by a
  previous run that died before `@babysitter` could stop them (an old build, or
  the wrapper itself getting hard-killed). Run once at boot so they can't pile up
  across restarts into a self-inflicted ICMP flood.

  Only kills a `ping` that (a) carries our resident `-O -i` signature and (b)
  whose direct parent isn't our spawner (`erl_child_setup` or the babysitter
  `sh`) — meaning it was reparented to a reaper (pid 1 / systemd / a WSL "Relay")
  and is therefore an orphan. A live monitor's ping always has one of those two
  parents, so other running instances are never touched. Linux/`/proc` only; a
  no-op that never raises elsewhere.
  """
  def reap_orphaned_streams do
    with {:unix, _} <- :os.type(),
         true <- File.dir?("/proc") do
      "/proc"
      |> File.ls!()
      |> Enum.filter(&Regex.match?(~r/^\d+$/, &1))
      |> Enum.each(fn pid ->
        if resident_ping?(pid) and orphaned?(pid),
          do: System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  # A process is one of our resident pings if its executable is `ping` and its
  # args carry the streaming signature (`-O -i`). /proc/<pid>/cmdline is
  # NUL-separated; a vanished pid reads as :error → not a match.
  defp resident_ping?(pid) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, raw} ->
        parts = String.split(raw, <<0>>, trim: true)
        Path.basename(List.first(parts) || "") == "ping" and "-O" in parts and "-i" in parts

      _ ->
        false
    end
  end

  # A live monitor ping's direct parent is always our spawner: `erl_child_setup`
  # (the old direct spawn) or the babysitter `sh`. Any other parent means it was
  # reparented to a reaper (pid 1 / systemd / a WSL "Relay") — i.e. an orphan.
  # Parent-only is deliberate: a reaper's own ancestry isn't reliably readable
  # under WSL, and the live set is a closed, known pair. An unreadable parent
  # returns false (don't kill) so we never reap a ping we couldn't vet.
  @live_ping_parents ["erl_child_setup", "sh", "dash"]

  defp orphaned?(pid) do
    case parent_comm(pid) do
      {:ok, comm} -> comm not in @live_ping_parents
      :error -> false
    end
  end

  defp parent_comm(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         ppid when is_binary(ppid) <- ppid_from_stat(stat),
         {:ok, comm} <- File.read("/proc/#{ppid}/comm") do
      {:ok, String.trim(comm)}
    else
      _ -> :error
    end
  end

  # /proc/<pid>/stat is "pid (comm) state ppid ..."; comm can contain spaces and
  # parens, so split on the *last* ")" and take ppid (2nd field after state).
  defp ppid_from_stat(stat) do
    case String.split(stat, ")", parts: 2) do
      [_, rest] -> rest |> String.trim_leading() |> String.split() |> Enum.at(1)
      _ -> nil
    end
  end

  defp run_stream(owner, host, interval) do
    {exe, args} = spawn_command(stream_command(host, interval))

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :hide,
        {:line, 2048},
        args: args
      ])

    stream_loop(owner, port)
  rescue
    e -> send(owner, {:stream_down, self(), Exception.message(e)})
  end

  # Resolve the logical `{cmd, args}` from `stream_command/2` into the
  # `{executable, args}` we actually spawn. On Unix/macOS the ping runs under the
  # `@babysitter` sh wrapper so it can't outlive its port; on Windows we spawn
  # ping directly (the wrapper is POSIX sh, and Windows port teardown differs).
  defp spawn_command({cmd, args}) do
    case :os.type() do
      {:win32, _} ->
        {System.find_executable(cmd) || cmd, args}

      _ ->
        sh = System.find_executable("sh") || "/bin/sh"
        ping = System.find_executable(cmd) || cmd
        {sh, ["-c", @babysitter, "sh", ping | args]}
    end
  end

  defp stream_loop(owner, port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        send(owner, {:stream_line, self(), line})
        stream_loop(owner, port)

      # A line longer than the buffer (shouldn't happen for ping) — skip the
      # fragment rather than emit a half-parsed sample.
      {^port, {:data, {:noeol, _partial}}} ->
        stream_loop(owner, port)

      {^port, {:exit_status, status}} ->
        send(owner, {:stream_down, self(), {:exit_status, status}})
    end
  end

  defp stream_command(host, interval) do
    case :os.type() do
      {:win32, _} ->
        # -t runs until stopped; Windows can't do sub-second spacing unprivileged.
        {"ping", ["-t", host]}

      {:unix, :darwin} ->
        # macOS prints "Request timeout for icmp_seq N" on a missed reply by default.
        {"ping", ["-i", to_string(interval), host]}

      {:unix, _} ->
        # -O makes Linux emit a line for each *missing* reply, so loss is seen live.
        {"ping", ["-O", "-i", to_string(interval), host]}
    end
  end

  @doc """
  Parses one line of continuous-`ping` output into a sample:

    * `{:ok, rtt_ms}` — a reply carrying a round-trip time
    * `:loss` — an explicit timeout / unreachable line
    * `:ignore` — banners, the trailing statistics, blank lines

  Public so this cross-platform, format-sensitive parsing can be regression-tested
  against real per-line output the way `parse/2` is for the burst summary.
  """
  def parse_stream_line(line) do
    case Regex.run(~r/time[=<]\s*([\d.]+)\s*ms/i, line) do
      [_, t] ->
        case parse_float(t) do
          nil -> :ignore
          rtt -> {:ok, rtt}
        end

      _ ->
        if Regex.match?(
             ~r/no answer yet|request timeout|request timed out|unreachable|100% packet loss/i,
             line
           ),
           do: :loss,
           else: :ignore
    end
  end

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
