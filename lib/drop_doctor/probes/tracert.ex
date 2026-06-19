defmodule DropDoctor.Probes.Tracert do
  @moduledoc """
  Per-hop path trace via Windows' built-in `tracert` — the Windows analogue of
  `DropDoctor.Probes.Mtr`. It returns the *same* hop-shaped map, so `PathReport`
  and the UI need no special-casing; only the measurement source differs.

  `tracert` ships with every Windows install and runs unprivileged, so the deep
  diagnostic works out of the box on the packaged Windows binary (where `mtr`
  doesn't exist). It is coarser than `mtr`: it sends 3 probes per hop, so per-hop
  loss is one of 0/33/67/100% rather than mtr's many-cycle precision — enough to
  locate where loss/latency begins, which is all the report needs.

  ## Locale robustness

  `tracert`'s output is localized (the banner, "Request timed out.", "Trace
  complete."), but the *data* on each hop line — the hop number, the RTT columns
  (`<1 ms` / `12 ms` / `*`), and the IP/hostname — is not. We parse only that
  data and never depend on any translated word, so this works on non-English
  Windows the same way.
  """

  # A reachable target stops the trace at the destination (~10–20 hops), so this
  # cap only bounds the *unreachable*/black-holed case; 20 keeps that worst case
  # (max_hops × 3 probes × per-probe wait) tolerable instead of ~90s.
  @default_max_hops 20
  # Per-probe reply wait. Bounds how long a dead hop costs (3 × this) and the
  # whole trace's worst case.
  @probe_timeout_ms 1_000

  @doc """
  True on Windows. `tracert.exe` ships with every Windows install (System32), so
  we key off the OS rather than `System.find_executable/1` — under the packaged
  Burrito runtime PATH can be sparse, and a missing-binary case is handled
  gracefully by `run/2` anyway (a friendly error report, not a dead button).
  """
  def available?, do: match?({:win32, _}, :os.type())

  @doc """
  Traces the path to `target`, returning the same shape as `Mtr.run/2`:

      %{ok?: boolean, target: String.t(), hops: [hop], raw: String.t(), error: String.t() | nil}

  where each hop is `%{count, host, loss_pct, sent, last, avg, best, worst, stdev}`.
  """
  def run(target, opts \\ []) do
    max_hops = Keyword.get(opts, :max_hops, @default_max_hops)
    # Worst case ≈ max_hops × 3 probes × per-probe timeout if every hop is dead;
    # an outer deadline guards against a black-holed path hanging the async.
    timeout = Keyword.get(opts, :timeout, max_hops * 3 * @probe_timeout_ms + 10_000)

    cond do
      not available?() ->
        error(target, "tracert is not available", "")

      true ->
        task = Task.async(fn -> exec(target, max_hops) end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> error(target, "timeout", "tracert did not finish in #{timeout}ms")
        end
    end
  end

  defp exec(target, max_hops) do
    # No -d: we want reverse-DNS names so PathReport can label the ISP's hops.
    args = ["-h", to_string(max_hops), "-w", to_string(@probe_timeout_ms), target]

    case System.cmd("tracert", args, stderr_to_stdout: true) do
      {out, 0} -> parse(out, target)
      {out, _code} -> error(target, "tracert exited non-zero", out)
    end
  rescue
    e -> error(target, "exception", Exception.message(e))
  end

  @doc "Parses raw `tracert` output into the hop list. Public for testing."
  def parse(out, target) do
    hops =
      out
      |> String.split(~r/\r?\n/)
      |> Enum.map(&parse_line/1)
      |> Enum.reject(&is_nil/1)

    case hops do
      [] -> error(target, "could not parse tracert output", out)
      _ -> %{ok?: true, target: target, hops: hops, raw: out, error: nil}
    end
  end

  # A hop line: leading spaces, the hop number, then up to three probe columns
  # (each an RTT or `*`), then the host. Banner/footer/blank lines don't start
  # with "<spaces><number><space>" and parse to nil.
  defp parse_line(line) do
    case Regex.run(~r/^\s*(\d+)\s+(.*\S)\s*$/, line) do
      [_, num, rest] -> build_hop(String.to_integer(num), rest)
      _ -> nil
    end
  end

  defp build_hop(count, rest) do
    {rtts, host_str} = split_probes(rest, [])
    present = Enum.reject(rtts, &is_nil/1)
    # tracert always sends exactly 3 probes per hop, so the denominator is fixed —
    # deriving it from how many columns parsed would inflate loss if a column
    # failed to split.
    sent = 3

    %{
      count: count,
      host: extract_host(host_str),
      loss_pct: (sent - length(present)) * 100.0 / sent,
      sent: sent,
      last: List.last(present),
      avg: avg(present),
      best: min_of(present),
      worst: max_of(present),
      stdev: 0.0
    }
  end

  # Peel the leading probe columns (at most 3) off the line, returning
  # `{[rtt | nil], host_remainder}` — `nil` for a `*` (timed-out) probe.
  defp split_probes(rest, acc) when length(acc) >= 3, do: {acc, String.trim(rest)}

  defp split_probes(rest, acc) do
    cond do
      m = Regex.run(~r/^\s*\*\s*/, rest) ->
        split_probes(drop_match(rest, m), acc ++ [nil])

      m = Regex.run(~r/^\s*(<?\s*\d+(?:\.\d+)?)\s*ms\s*/i, rest) ->
        split_probes(drop_match(rest, m), acc ++ [to_ms(Enum.at(m, 1))])

      true ->
        {acc, String.trim(rest)}
    end
  end

  defp drop_match(rest, [matched | _]),
    do: binary_part(rest, byte_size(matched), byte_size(rest) - byte_size(matched))

  # "<1" / "< 1" / "12" / "12.3" -> a float; the "<" just means "under 1ms".
  defp to_ms(token) do
    case token |> String.replace(~r/[^\d.]/, "") |> Float.parse() do
      {f, _} -> f
      :error -> nil
    end
  end

  # Prefer the reverse-DNS name ("name [ip]") so PathReport can map ISP domains;
  # fall back to the bracketed IP, then a bare IP (v4 or v6); "???" for a fully
  # timed-out hop (so it reads as a non-responder, exactly like mtr's unknowns).
  defp extract_host(host_str) do
    str = String.trim(host_str)

    cond do
      m = Regex.run(~r/^(\S+)\s+\[[^\]]+\]/, str) -> Enum.at(m, 1)
      m = Regex.run(~r/^\[([^\]]+)\]/, str) -> Enum.at(m, 1)
      ip = leading_ip(str) -> ip
      true -> "???"
    end
  end

  # The first whitespace-delimited token, if it parses as an IP address (v4 or
  # v6) — covers a bare IPv4 hop and an IPv6 hop, which `inet.parse_address`
  # both accept but a v4-only regex would miss.
  defp leading_ip(str) do
    token = str |> String.split() |> List.first()

    case token && token |> String.to_charlist() |> :inet.parse_address() do
      {:ok, _} -> token
      _ -> nil
    end
  end

  defp avg([]), do: nil
  defp avg(list), do: Float.round(Enum.sum(list) / length(list), 1)
  defp min_of([]), do: nil
  defp min_of(list), do: Enum.min(list)
  defp max_of([]), do: nil
  defp max_of(list), do: Enum.max(list)

  # Same failure shape mtr returns, so both probes are interchangeable to PathReport.
  defp error(target, err, raw),
    do: %{ok?: false, target: target, hops: [], raw: raw, error: err}
end
