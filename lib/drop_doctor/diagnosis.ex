defmodule DropDoctor.Diagnosis do
  @moduledoc """
  The brain. Takes a single sweep of segment measurements and produces a
  plain-English verdict that answers the only question the user actually has:
  *whose fault is it, and what do I do?*

  The logic is a priority walk **outward** along the ladder. The earliest
  segment that's broken is the culprit, because a failure close to you makes
  everything beyond it look broken too. So we check the router first; only if
  it's healthy do we blame the ISP, and so on. This avoids the classic mistake
  of blaming the ISP when really your own Wi-Fi is dropping packets.

  Thresholds are deliberately conservative and explained in evidence strings so
  a non-technical user sees *why* a verdict was reached, and a technical user
  can sanity-check the numbers.
  """

  # latency (ms) above which a segment is "slow but working"
  @router_warn_ms 35
  @internet_warn_ms 90
  @dns_warn_ms 300
  @web_warn_ms 1500
  # packet loss (%) above which a ping segment is degraded
  @loss_warn_pct 2.0
  # The ISP+path latency a sweep adds *beyond* your own router: the open-internet
  # RTT minus the local router RTT. We judge the ISP on this *differential*, not
  # on the internet's absolute RTT, because the absolute figure also contains
  # your local first hop (Wi-Fi/cabling) and host scheduling jitter — so a slow
  # local link or a busy machine could otherwise be misattributed to your
  # provider. Set so that, for the common near-zero-latency router, it roughly
  # preserves the old absolute-90ms behaviour while *only ever removing* false
  # ISP blame, never adding it. Falls back to @internet_warn_ms when there's no
  # router RTT to subtract, so we never go blind.
  @isp_warn_ms 80

  @doc """
  `sweep` is a map of `%{router: result, internet: result, dns: result, web: result}`
  where each result is the raw probe map plus a `:def` (the ladder definition).
  Returns the verdict map consumed by the UI and persisted to history.
  """
  def analyze(sweep) do
    # The router RTT is the baseline we subtract to isolate the ISP's own
    # contribution on the internet segment (see `isp_latency/2`).
    router_rtt = get_in(sweep, [:router, :rtt_ms])

    by_key =
      ladder_keys()
      |> Enum.map(&segment_status(&1, sweep[&1], router_rtt))
      |> Map.new(&{&1.key, &1})
      |> corroborate()

    segments = Enum.map(ladder_keys(), &Map.fetch!(by_key, &1))
    {culprit, status} = attribute(by_key)

    %{
      status: status,
      culprit: culprit,
      headline: headline(culprit, status),
      detail: detail(culprit, by_key),
      action: action(culprit),
      evidence: evidence(by_key),
      segments: segments
    }
  end

  # --- cross-layer corroboration ------------------------------------------

  # A ping/reach segment that reads `:down` only means "this ICMP target didn't
  # answer" — which some networks and NATs cause even while real traffic flows.
  # If DNS resolution *and* a real page load both succeeded, the path out through
  # your router and ISP is provably working, so an unreachable ping there is a
  # probe artifact, not an outage: clear it rather than screaming "router down".
  # Only a hard `:down` is overridden — genuine latency/loss `:degraded` stands.
  defp corroborate(by_key) do
    if proven_usable?(by_key) do
      by_key
      |> clear_false_down(:router)
      |> clear_false_down(:internet)
    else
      by_key
    end
  end

  defp proven_usable?(by_key), do: healthy?(by_key[:dns]) and healthy?(by_key[:web])

  defp healthy?(%{state: :healthy}), do: true
  defp healthy?(_), do: false

  defp clear_false_down(by_key, key) do
    case by_key[key] do
      %{state: :down} = seg ->
        Map.put(by_key, key, %{
          seg
          | state: :healthy,
            summary: "reachable — ICMP blocked here, but real traffic is getting through"
        })

      _ ->
        by_key
    end
  end

  defp ladder_keys, do: [:router, :internet, :dns, :web]

  # --- per-segment status -------------------------------------------------

  defp segment_status(key, %{def: defn} = result, router_rtt) do
    {state, summary} = segment_state(key, result, router_rtt)

    %{
      key: key,
      label: defn.label,
      about: defn.about,
      target: defn.target,
      state: state,
      summary: summary,
      metrics: metrics(key, result, router_rtt),
      raw: Map.get(result, :raw)
    }
  end

  defp segment_status(key, nil, _router_rtt) do
    %{
      key: key,
      label: to_string(key),
      about: nil,
      target: nil,
      state: :unknown,
      summary: "no data yet",
      metrics: %{},
      raw: nil
    }
  end

  # Internet is judged on the ISP differential (needs the router baseline);
  # every other segment is judged on its own absolute measurement.
  defp segment_state(:internet, result, router_rtt), do: isp_ping_state(result, router_rtt)
  defp segment_state(key, result, _router_rtt), do: state_for(key, result)

  defp state_for(:router, r), do: ping_state(r, @router_warn_ms)

  defp state_for(:dns, %{ok?: false}), do: {:down, "name lookup failed"}

  defp state_for(:dns, %{ms: ms}) when is_number(ms) and ms > @dns_warn_ms,
    do: {:degraded, "slow: #{round(ms)}ms"}

  defp state_for(:dns, %{ms: ms}), do: {:healthy, "#{round_ms(ms)}ms"}

  defp state_for(:web, %{ok?: false}), do: {:down, "page failed to load"}

  defp state_for(:web, %{ms: ms}) when is_number(ms) and ms > @web_warn_ms,
    do: {:degraded, "slow: #{round(ms)}ms"}

  defp state_for(:web, %{ms: ms}), do: {:healthy, "#{round_ms(ms)}ms"}

  defp ping_state(%{loss_pct: loss}, _warn) when loss >= 100,
    do: {:down, "100% packet loss — unreachable"}

  defp ping_state(%{loss_pct: loss}, _warn) when loss > @loss_warn_pct,
    do: {:degraded, "#{round_ms(loss)}% packet loss"}

  defp ping_state(%{rtt_ms: rtt}, warn) when is_number(rtt) and rtt > warn,
    do: {:degraded, "high latency: #{round(rtt)}ms"}

  defp ping_state(%{rtt_ms: rtt}, _warn) when is_number(rtt), do: {:healthy, "#{round_ms(rtt)}ms"}
  defp ping_state(_, _), do: {:down, "no response"}

  # Internet ping state, judged on the ISP differential. Loss is connectivity, so
  # it's judged on the internet segment's own figure (the router-first ladder
  # already exonerates the ISP when the loss is actually local). Latency, though,
  # is split: only the part the ISP adds *over* your router counts against it.
  defp isp_ping_state(%{loss_pct: loss}, _router_rtt) when loss >= 100,
    do: {:down, "100% packet loss — unreachable"}

  defp isp_ping_state(%{loss_pct: loss}, _router_rtt) when loss > @loss_warn_pct,
    do: {:degraded, "#{round_ms(loss)}% packet loss"}

  defp isp_ping_state(%{rtt_ms: rtt}, router_rtt) when is_number(rtt) do
    case isp_latency(rtt, router_rtt) do
      # No router baseline this sweep — fall back to the absolute ceiling so we
      # never miss a degradation just because the router didn't answer.
      nil ->
        if rtt > @internet_warn_ms,
          do: {:degraded, "high latency: #{round(rtt)}ms"},
          else: {:healthy, "#{round_ms(rtt)}ms"}

      isp when isp > @isp_warn_ms ->
        {:degraded, "ISP adds #{round(isp)}ms beyond your router (#{round(rtt)}ms total)"}

      _ ->
        {:healthy, "#{round_ms(rtt)}ms"}
    end
  end

  defp isp_ping_state(_, _), do: {:down, "no response"}

  # ISP+path latency contribution: internet RTT minus the local router RTT,
  # floored at 0. A negative delta means the router answered *slower* than the
  # internet hop that contains it — a local/host artifact (or just non-
  # simultaneous samples), never a real ISP cost, so we clamp it away. Returns
  # nil when there's no router RTT to subtract.
  defp isp_latency(internet_rtt, router_rtt)
       when is_number(internet_rtt) and is_number(router_rtt),
       do: max(internet_rtt - router_rtt, 0.0)

  defp isp_latency(_, _), do: nil

  defp metrics(:router, r, _router_rtt),
    do: %{
      rtt_ms: r[:rtt_ms],
      loss_pct: r[:loss_pct],
      max_rtt_ms: r[:max_rtt_ms],
      jitter_ms: r[:jitter_ms]
    }

  defp metrics(:internet, r, router_rtt),
    do: %{
      rtt_ms: r[:rtt_ms],
      loss_pct: r[:loss_pct],
      max_rtt_ms: r[:max_rtt_ms],
      jitter_ms: r[:jitter_ms],
      # The ISP's own latency contribution, surfaced so the UI/report can say
      # "your ISP added X ms over your router" instead of just a raw total.
      isp_latency_ms: isp_latency(r[:rtt_ms], router_rtt)
    }

  defp metrics(:dns, r, _router_rtt), do: %{ms: r[:ms], address: r[:address]}
  defp metrics(:web, r, _router_rtt), do: %{ms: r[:ms], status: r[:status], bytes: r[:bytes]}

  # --- attribution: who's to blame ---------------------------------------

  defp attribute(s) do
    cond do
      down?(s.router) -> {:local, :down}
      degraded?(s.router) -> {:local, :degraded}
      down?(s.internet) -> {:isp, :down}
      degraded?(s.internet) -> {:isp, :degraded}
      down?(s.dns) -> {:dns, :down}
      degraded?(s.dns) -> {:dns, :degraded}
      down?(s.web) -> {:web, :down}
      degraded?(s.web) -> {:web, :degraded}
      true -> {:none, :healthy}
    end
  end

  defp down?(%{state: :down}), do: true
  defp down?(_), do: false
  defp degraded?(%{state: :degraded}), do: true
  defp degraded?(_), do: false

  # --- human-facing copy --------------------------------------------------

  defp headline(:none, _), do: "Your connection looks healthy"
  defp headline(:local, :down), do: "The problem is on your side — your router isn't responding"
  defp headline(:local, _), do: "The problem is on your side — your local network is struggling"

  defp headline(:isp, :down),
    do: "This is your ISP — your router is fine but the internet is unreachable"

  defp headline(:isp, _),
    do: "This points at your ISP — your equipment is fine but the link is degraded"

  defp headline(:dns, _), do: "Your internet works, but DNS (name lookups) is the problem"
  defp headline(:web, _), do: "Connectivity is fine, but loading real sites is slow"

  defp detail(:none, _),
    do:
      "Every layer from your router out to the open internet is responding normally. If something still feels slow, run a deep diagnostic to inspect each hop to your ISP."

  defp detail(:local, by) do
    "Your computer can't reliably reach your own router (#{by.router.target}). Because this hop is *before* your ISP, the issue is your Wi-Fi, cabling, network adapter, or the router itself — not your provider. Fixing this usually fixes everything downstream."
  end

  defp detail(:isp, by) do
    "Your router (#{by.router.target}) responds fine, but traffic to the open internet (#{by.internet.target}, a raw IP with no DNS) is failing or degraded. The break is *past* your equipment, in your ISP's network. This is the evidence you want when you call them."
  end

  defp detail(:dns, by) do
    "Raw internet connectivity is healthy, but resolving names (#{by.dns.target}) is failing or slow. Your link is fine — the DNS server you're using is the bottleneck. Switching to a public resolver like 1.1.1.1 or 8.8.8.8 usually fixes it instantly."
  end

  defp detail(:web, _),
    do:
      "Pings and DNS are healthy, but actually loading a page is slow. That's typically bandwidth saturation (something hogging your connection), congestion on the path, or the specific site being slow — not a hard fault."

  defp action(:none), do: nil

  defp action(:local),
    do: "Restart your router, check cables/Wi-Fi signal, and try a wired connection to confirm."

  defp action(:isp),
    do:
      "Save this report and contact your ISP — the data shows the fault is in their network, not yours."

  defp action(:dns),
    do: "Change your DNS server to 1.1.1.1 or 8.8.8.8 in your OS or router settings."

  defp action(:web),
    do:
      "Check for downloads/streaming using bandwidth, then re-test. If it persists across sites, it may be congestion."

  defp evidence(by) do
    Enum.map([:router, :internet, :dns, :web], fn k ->
      s = by[k]
      "#{symbol(s.state)} #{s.label}: #{s.summary}"
    end)
  end

  defp symbol(:healthy), do: "✓"
  defp symbol(:degraded), do: "▲"
  defp symbol(:down), do: "✕"
  defp symbol(_), do: "•"

  defp round_ms(n) when is_number(n), do: Float.round(n / 1, 1)
  defp round_ms(_), do: 0
end
