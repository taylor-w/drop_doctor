defmodule TrackConn.Probes.Reach do
  @moduledoc """
  Reachability probe with an ICMP→TCP fallback — the robust replacement for
  pinging a single hardcoded IP. Used for both the open internet (several anchors)
  and the local router (one target), each with its own candidate TCP ports.

  Two failure modes were faking outages on connections that were actually fine:

    1. **A filtered anchor.** Some networks (and WSL NAT setups) silently drop
       ICMP to one well-known resolver — e.g. 1.1.1.1 — while happily answering
       another (8.8.8.8). Betting the whole verdict on one IP turns that into a
       false outage.

    2. **ICMP filtered entirely.** Plenty of paths — and lots of home routers —
       block ICMP echo outright but still pass ordinary TCP, the traffic you
       actually use. Ping-only probing calls that an outage too. (A router that
       answers DNS on :53 but never replies to `ping` is the common case.)

  So this probe (a) fans ICMP across *all* targets and is reachable if **any**
  answers (picking the healthiest for the reading), and (b) if every target is
  ICMP-silent, falls back to a **TCP connect** to the given ports — if one
  completes, real traffic is getting through, so it reports reachable with
  coarse connect-time latency rather than down.

  Options (passed from the ladder def's `:probe_opts`):
    * `:anchors`   — list of IPs to try (defaults to `[target]`)
    * `:tcp_ports` — ports for the TCP fallback (defaults to `[443]`)
    * `:label`     — human prefix for the raw line ("open internet" / "your router")

  Returns the same ping-shaped map every ping consumer expects, so diagnosis,
  smoothing and the UI need no special-casing — only `:def.kind` is `:reach`,
  which `TrackConn.Aggregate` smooths exactly like a ping.
  """

  @behaviour TrackConn.Probe

  alias TrackConn.Probes.Ping

  # Per-target ICMP probe: a few packets, short per-packet wait so a blocked
  # target resolves to "silent" quickly. Targets are probed concurrently, so the
  # ICMP phase costs about one target's time, not the sum.
  @count 3
  @ping_timeout 1
  @icmp_stream_timeout 6_000

  # TCP fallback: a plain connect to a port real traffic uses — survives ICMP
  # filters and NATs.
  @default_tcp_ports [443]
  @tcp_timeout 1_500

  @impl true
  def run(target, opts \\ []) do
    anchors =
      case opts[:anchors] do
        nil -> [target]
        [] -> [target]
        list -> list
      end

    case best_icmp(anchors, opts) do
      {anchor, result} -> via_icmp(result, anchor, anchors, opts)
      nil -> tcp_fallback(anchors, opts)
    end
  end

  defp label(opts), do: opts[:label] || "open internet"

  # --- ICMP phase ---------------------------------------------------------

  # Ping every target concurrently; return the healthiest responder (lowest loss,
  # then lowest latency) as `{anchor, ping_result}`, or nil if none answered.
  defp best_icmp(anchors, opts) do
    # A 2-arity fun `(host, opts) -> ping_result` so tests can inject a closure
    # (which copies into the async-stream tasks; a module/process-dict would not).
    ping = opts[:ping] || (&Ping.run/2)

    anchors
    |> Task.async_stream(
      fn a -> {a, ping.(a, count: @count, timeout: @ping_timeout)} end,
      max_concurrency: max(length(anchors), 1),
      timeout: @icmp_stream_timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, {anchor, %{ok?: true, rtt_ms: rtt} = res}} when is_number(rtt) -> [{anchor, res}]
      _ -> []
    end)
    |> case do
      [] -> nil
      responders -> Enum.min_by(responders, fn {_a, r} -> {r.loss_pct || 0.0, r.rtt_ms} end)
    end
  end

  defp via_icmp(result, anchor, anchors, opts) do
    head =
      case anchors do
        [_] -> "#{label(opts)} #{anchor}"
        _ -> "#{label(opts)} via #{anchor} (any of #{length(anchors)} anchors)"
      end

    %{result | raw: "#{head}\n#{result.raw}"}
  end

  # --- TCP fallback -------------------------------------------------------

  defp tcp_fallback(anchors, opts) do
    ports = opts[:tcp_ports] || @default_tcp_ports
    connect = opts[:tcp] || fn host -> tcp_connect(host, ports) end

    anchors
    |> Task.async_stream(fn a -> {a, connect.(a)} end,
      max_concurrency: max(length(anchors), 1),
      timeout: @tcp_timeout * length(ports) + 500,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, {anchor, {:ok, ms}}} -> [{anchor, ms}]
      {:ok, {anchor, {:ok, ms, port}}} -> [{anchor, ms, port}]
      _ -> []
    end)
    |> case do
      [] -> unreachable(anchors, opts)
      oks -> oks |> Enum.min_by(&elem(&1, 1)) |> reachable_tcp(anchors, opts)
    end
  end

  defp reachable_tcp(hit, anchors, opts) do
    {anchor, ms, port} =
      case hit do
        {a, ms, port} -> {a, ms, port}
        {a, ms} -> {a, ms, nil}
      end

    where = if port, do: "#{anchor}:#{port}", else: anchor

    %{
      ok?: true,
      rtt_ms: ms * 1.0,
      max_rtt_ms: ms * 1.0,
      jitter_ms: nil,
      loss_pct: 0.0,
      sent: 1,
      received: 1,
      raw:
        "#{label(opts)} — ICMP blocked, reached #{where} over TCP in #{ms}ms\n" <>
          "tried: #{Enum.join(anchors, ", ")}",
      error: nil
    }
  end

  defp unreachable(anchors, opts) do
    %{
      ok?: false,
      rtt_ms: nil,
      max_rtt_ms: nil,
      jitter_ms: nil,
      loss_pct: 100.0,
      sent: length(anchors),
      received: 0,
      raw: "#{label(opts)} — no target answered ICMP or TCP (tried: #{Enum.join(anchors, ", ")})",
      error: "no reply"
    }
  end

  # Try each port in turn; first completed handshake wins. Returns
  # `{:ok, ms, port}` (real traffic flows) or `:error`.
  defp tcp_connect(host, ports) do
    charlist = String.to_charlist(host)

    Enum.find_value(ports, :error, fn port ->
      t0 = System.monotonic_time(:millisecond)

      case :gen_tcp.connect(charlist, port, [:binary, active: false], @tcp_timeout) do
        {:ok, sock} ->
          :gen_tcp.close(sock)
          {:ok, System.monotonic_time(:millisecond) - t0, port}

        {:error, _} ->
          nil
      end
    end)
  end
end
