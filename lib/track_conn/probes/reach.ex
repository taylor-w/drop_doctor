defmodule TrackConn.Probes.Reach do
  @moduledoc """
  Open-internet reachability probe — the robust replacement for pinging a single
  hardcoded IP.

  Two failure modes were faking outages on connections that were actually fine:

    1. **A filtered anchor.** Some networks (and WSL NAT setups) silently drop
       ICMP to one well-known resolver — e.g. 1.1.1.1 — while happily answering
       another (8.8.8.8). Betting the whole ISP verdict on one IP turns that into
       a false "internet down".

    2. **ICMP filtered entirely.** A few paths block ICMP echo outright but pass
       ordinary TCP — the traffic you actually use. Ping-only probing calls that
       an outage too.

  So this probe (a) fans ICMP out across *all* anchors and treats the internet as
  reachable if **any** answers (picking the healthiest for the reading), and
  (b) if every anchor is ICMP-silent, falls back to a **TCP connect** to one of
  them — if that succeeds, real traffic is getting through, so it reports
  reachable (with coarse, connect-time latency) rather than down.

  Returns the same ping-shaped map every other ping consumer expects
  (`:ok?`, `:rtt_ms`, `:loss_pct`, `:max_rtt_ms`, `:jitter_ms`, …) so the
  diagnosis, smoothing, and UI need no special-casing — only the `:def.kind`
  differs (`:reach`), which `TrackConn.Aggregate` smooths exactly like a ping.
  """

  @behaviour TrackConn.Probe

  alias TrackConn.{Probes.Ping, Targets}

  # Per-anchor ICMP probe: a few packets, short per-packet wait so a blocked
  # anchor resolves to "silent" quickly. Anchors are probed concurrently, so the
  # ICMP phase costs about one anchor's time, not the sum.
  @count 3
  @ping_timeout 1
  @icmp_stream_timeout 6_000

  # TCP fallback: a plain connect to a port real traffic uses. 443 is open on the
  # resolvers and, crucially, isn't ICMP — so it survives ICMP filters and NATs.
  @tcp_port 443
  @tcp_timeout 1_500

  @impl true
  def run(target, opts \\ []) do
    anchors = opts[:anchors] || Targets.internet_anchors()
    anchors = if anchors == [], do: [target], else: anchors

    case best_icmp(anchors, opts) do
      {anchor, result} -> via_icmp(result, anchor, anchors)
      nil -> tcp_fallback(anchors, opts)
    end
  end

  # --- ICMP phase ---------------------------------------------------------

  # Ping every anchor concurrently; return the healthiest responder (lowest loss,
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

  defp via_icmp(result, anchor, anchors) do
    %{
      result
      | raw: "open internet via #{anchor} (any of #{length(anchors)} anchors)\n#{result.raw}"
    }
  end

  # --- TCP fallback -------------------------------------------------------

  defp tcp_fallback(anchors, opts) do
    connect = opts[:tcp] || (&tcp_connect/1)

    anchors
    |> Task.async_stream(fn a -> {a, connect.(a)} end,
      max_concurrency: max(length(anchors), 1),
      timeout: @tcp_timeout + 500,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, {anchor, {:ok, ms}}} -> [{anchor, ms}]
      _ -> []
    end)
    |> case do
      [] -> unreachable(anchors)
      oks -> {anchor, ms} = Enum.min_by(oks, fn {_a, ms} -> ms end); reachable_tcp(anchor, ms, anchors)
    end
  end

  defp reachable_tcp(anchor, ms, anchors) do
    %{
      ok?: true,
      rtt_ms: ms * 1.0,
      max_rtt_ms: ms * 1.0,
      jitter_ms: nil,
      loss_pct: 0.0,
      sent: 1,
      received: 1,
      raw:
        "ICMP blocked to every anchor — reached #{anchor}:#{@tcp_port} over TCP in #{ms}ms\n" <>
          "tried: #{Enum.join(anchors, ", ")}",
      error: nil
    }
  end

  defp unreachable(anchors) do
    %{
      ok?: false,
      rtt_ms: nil,
      max_rtt_ms: nil,
      jitter_ms: nil,
      loss_pct: 100.0,
      sent: length(anchors),
      received: 0,
      raw: "no internet anchor responded to ICMP or TCP — tried: #{Enum.join(anchors, ", ")}",
      error: "no reply"
    }
  end

  # Plain TCP connect timing. Returns {:ok, ms} on a completed handshake (real
  # traffic flows), :error otherwise.
  defp tcp_connect(host) do
    t0 = System.monotonic_time(:millisecond)

    case :gen_tcp.connect(String.to_charlist(host), @tcp_port, [:binary, active: false], @tcp_timeout) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        {:ok, System.monotonic_time(:millisecond) - t0}

      {:error, _} ->
        :error
    end
  end
end
