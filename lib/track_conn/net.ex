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

  Inside WSL2 the *default* gateway is usually the Windows host's virtual
  switch (e.g. `172.x.x.1`), not your physical router. We detect that case and
  flag it, so the UI can explain why the "router" segment may not reflect your
  real router unless you set `ROUTER_IP` to your real LAN gateway (e.g.
  `192.168.1.1`).
  """

  @doc """
  Returns the default gateway IP as a string, or `nil` if it can't be found.
  """
  def default_gateway do
    case :os.type() do
      {:unix, :darwin} -> macos_gateway()
      {:unix, _} -> linux_gateway()
      {:win32, _} -> windows_gateway()
    end
  rescue
    _ -> nil
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

  defp windows_gateway do
    case System.cmd("ipconfig", [], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          if String.contains?(line, "Default Gateway") do
            line |> String.split(":") |> List.last() |> String.trim() |> nil_if_blank()
          end
        end)

      _ ->
        nil
    end
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
  defp nil_if_blank(""), do: nil
  defp nil_if_blank(str), do: str
end
