defmodule TrackConn.Net do
  @moduledoc """
  Network topology discovery: figuring out *what* to probe.

  The whole "is it my router or my ISP?" question depends on knowing the
  address of the first hop out of your machine (your gateway / router) and a
  hop that belongs to your ISP. This module discovers those in a way that
  works across Linux, macOS and Windows, and is tolerant of failure — if we
  can't discover something we fall back to sensible defaults rather than
  crashing the monitor.

  ## A note on WSL

  Inside WSL2 the Linux *default* gateway is the Windows host's virtual switch
  (e.g. `172.x.x.1`), not your physical router — so a naive gateway lookup would
  make the "router" segment measure a memory-to-memory hop on your own PC rather
  than your real LAN. To keep the router-vs-ISP attribution honest without making
  the user configure anything, under WSL we ask the *Windows host* for its real
  default route (via `ipconfig.exe` / PowerShell over interop) and probe that.
  `ROUTER_IP` still overrides everything for the rare case detection can't reach
  the host. The discovered address is cached (it doesn't change mid-session), so
  this costs one lookup every few minutes, not one per sweep.
  """

  # The physical router rarely changes during a session, and discovering it under
  # WSL means shelling out to a Windows binary — so cache it rather than paying
  # that on every 5s sweep. nil results are cached too, so a machine with interop
  # disabled doesn't re-spawn the lookup every sweep; the TTL lets it recover.
  @win_gateway_cache {__MODULE__, :win_host_gateway}
  @win_gateway_ttl_ms 300_000

  @doc """
  Returns the default gateway IP as a string, or `nil` if it can't be found.

  Under WSL this is the *physical* router (discovered from the Windows host),
  falling back to the Linux-side virtual-switch gateway if the host can't be
  reached.
  """
  def default_gateway do
    if wsl?() do
      windows_host_gateway() || os_default_gateway()
    else
      os_default_gateway()
    end
  rescue
    _ -> nil
  end

  defp os_default_gateway do
    case :os.type() do
      {:unix, :darwin} -> macos_gateway()
      {:unix, _} -> linux_gateway()
      {:win32, _} -> windows_gateway()
    end
  end

  @doc """
  Under WSL, the real (physical) router as seen by the Windows host, or `nil` if
  it can't be discovered. Result is cached for #{div(@win_gateway_ttl_ms, 1000)}s.
  """
  def windows_host_gateway do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@win_gateway_cache, nil) do
      {gw, expires_at} when expires_at > now ->
        gw

      _ ->
        gw = discover_windows_host_gateway()
        :persistent_term.put(@win_gateway_cache, {gw, now + @win_gateway_ttl_ms})
        gw
    end
  rescue
    _ -> nil
  end

  @doc """
  True when running under WSL with no usable router override *and* we couldn't
  discover the physical router from the Windows host — i.e. the "router" segment
  has fallen back to the virtual switch and attribution can't be trusted. The UI
  uses this to surface a (now rare) manual-setup hint.
  """
  def wsl_router_unresolved? do
    wsl?() and is_nil(System.get_env("ROUTER_IP")) and is_nil(windows_host_gateway())
  rescue
    _ -> false
  end

  # Hard cap on the Windows-host lookup. Discovery shells out over WSL interop and
  # runs on the Monitor's sweep tick (via the target ladder), which must stay
  # responsive — so a wedged host process can never stall it. On timeout we return
  # nil (→ fall back to the virtual switch) rather than block.
  @discovery_timeout_ms 5_000

  # Prefer PowerShell's exact IPv4 default-route next-hop; fall back to parsing
  # ipconfig if PowerShell isn't available. Both reach the Windows host over WSL
  # interop and return the real router, never the WSL NAT switch. The probes never
  # raise (each rescues to nil), so the bounding task always exits normally — no
  # crash signal can propagate to the caller.
  defp discover_windows_host_gateway do
    task =
      Task.async(fn ->
        windows_gateway_via_powershell() || windows_gateway_via_ipconfig()
      end)

    case Task.yield(task, @discovery_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, gateway} -> gateway
      _ -> nil
    end
  end

  defp windows_gateway_via_powershell do
    ps =
      "Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | " <>
        "Select-Object -First 1 -ExpandProperty NextHop"

    case System.cmd("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", ps],
           stderr_to_stdout: true
         ) do
      {out, 0} -> first_ipv4_gateway(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp windows_gateway_via_ipconfig do
    case System.cmd("ipconfig.exe", [], stderr_to_stdout: true) do
      {out, 0} -> parse_ipconfig_gateway(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Picks the first real IPv4 default gateway out of raw `ipconfig` output. Public
  so this fragile, format-sensitive parsing can be regression-tested against real
  captured output (blank gateways, IPv6 next-hops, the WSL adapter) the way
  `TrackConn.Probes.Ping.parse/2` is.

  ipconfig prints the gateway on the labelled `Default Gateway . . . :` line and,
  when an adapter has both stacks, often the IPv4 on an *unlabelled continuation
  line* below it with the IPv6 on the labelled line. So we gather each gateway
  line plus its continuation lines, pull every IPv4 out of them, and return the
  first real one — never an IPv6 fragment, never a value from a `:`-split.
  """
  def parse_ipconfig_gateway(out) do
    out
    |> String.split(~r/\r?\n/)
    |> gateway_block_lines()
    |> Enum.flat_map(&ipv4s_in/1)
    |> Enum.find(&real_ipv4_gateway?/1)
  end

  # Collect every "Default Gateway" line and the value-only continuation lines
  # that follow it (an indented line with no `. . . :` dotted label).
  defp gateway_block_lines(lines) do
    lines
    |> Enum.reduce({[], false}, fn line, {acc, in_block?} ->
      cond do
        String.contains?(line, "Default Gateway") -> {[line | acc], true}
        in_block? and continuation_line?(line) -> {[line | acc], true}
        true -> {acc, false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # A continuation line is indented and carries only a value — no dotted label
  # leader (". . .") like every real ipconfig field has.
  defp continuation_line?(line),
    do: Regex.match?(~r/^\s+\S/, line) and not String.contains?(line, ". .")

  defp ipv4s_in(line),
    do: Regex.scan(~r/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/, line) |> Enum.map(&hd/1)

  defp first_ipv4_gateway(out) do
    out
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(&if(real_ipv4_gateway?(&1), do: &1))
  end

  # A usable router address: a real IPv4 (not the unspecified 0.0.0.0). Blank
  # strings and IPv6 next-hops fail to parse as a 4-tuple and are rejected.
  defp real_ipv4_gateway?(str) do
    case str |> String.to_charlist() |> :inet.parse_address() do
      {:ok, {0, 0, 0, 0}} -> false
      {:ok, {_, _, _, _}} -> true
      _ -> false
    end
  end

  defp linux_gateway do
    # `ip route show default` => "default via 192.168.1.1 dev eth0 ..."
    case System.cmd("ip", ["route", "show", "default"], stderr_to_stdout: true) do
      {out, 0} -> extract_via(out)
      _ -> route_n_fallback()
    end
  rescue
    _ -> route_n_fallback()
  end

  defp route_n_fallback do
    case System.cmd("route", ["-n"], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case String.split(line) do
            ["0.0.0.0", gw | _] -> gw
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp macos_gateway do
    case System.cmd("netstat", ["-rn"], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case String.split(line) do
            ["default", gw | _] -> if valid_ip?(gw), do: gw, else: nil
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  # Native Windows: same robust, validated parse as the WSL-interop path, so a
  # bare IPv6 default gateway (or a `:`-split fragment of one) can never be
  # handed to `ping` as a bogus host — which left the router segment stuck at
  # "sampling…" with zero replies.
  defp windows_gateway do
    case System.cmd("ipconfig", [], stderr_to_stdout: true) do
      {out, 0} -> parse_ipconfig_gateway(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp extract_via(out) do
    case Regex.run(~r/via\s+(\d+\.\d+\.\d+\.\d+)/, out) do
      [_, ip] -> ip
      _ -> nil
    end
  end

  @doc """
  True when we appear to be running inside WSL, where the default gateway is
  the Windows host rather than the physical router.
  """
  def wsl? do
    File.exists?("/proc/sys/fs/binfmt_misc/WSLInterop") or
      (File.exists?("/proc/version") and
         File.read!("/proc/version") |> String.downcase() |> String.contains?("microsoft"))
  rescue
    _ -> false
  end

  defp valid_ip?(str), do: match?({:ok, _}, str |> to_charlist() |> :inet.parse_address())
end
