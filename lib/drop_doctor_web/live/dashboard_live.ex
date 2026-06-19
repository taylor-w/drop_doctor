defmodule DropDoctorWeb.DashboardLive do
  @moduledoc """
  The single-screen dashboard. Designed for the "lowest common denominator":
  the first thing you see is a giant traffic light and one plain sentence. The
  numbers and raw command output are there too, tucked into expandable sections
  for people who want them — so the same screen serves a panicked non-technical
  user and a network engineer.
  """
  use DropDoctorWeb, :live_view

  alias DropDoctor.{
    DeepDiagnostic,
    Measurements,
    Monitor,
    Net,
    SpikeAnalysis,
    SpikeMonitor,
    Targets
  }

  # How many sweeps the expanded timeline shows at once. The window pans across
  # the full recorded history (drag), anchored `tl_offset` sweeps back from now.
  @tl_window 90

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Monitor.subscribe()
      Phoenix.PubSub.subscribe(DropDoctor.PubSub, SpikeMonitor.topic())
    end

    # Load existing history once from the DB. Thereafter the LiveView updates
    # from broadcasts (appending the persisted row), so it never re-queries the
    # database on every sweep — Tier-3 churn reduction.
    history = Measurements.recent(60)

    {:ok,
     socket
     |> assign(:verdict, Monitor.latest())
     |> assign(:running, Monitor.running?())
     |> assign(:wsl_warning, wsl_warning())
     |> assign(:history, history)
     |> assign(:stats, stats(history))
     |> assign(:total_all, Measurements.count())
     # `proof_key` is the last-selected segment (retained even while closing so
     # the panel can animate shut with its content still in place); `proof_open`
     # is whether that panel is currently expanded.
     |> assign(:proof_key, nil)
     |> assign(:proof_open, false)
     |> assign(:timeline_open, false)
     |> assign(:tl_offset, 0)
     |> assign(:timeline_rows, [])
     |> assign(:timeline_spikes, [])
     |> assign(:stability, initial_stability())
     |> assign(:spike_events, Measurements.count_spike_events())
     |> assign(:deep, %{status: :idle, target: Targets.internet_target()})
     |> assign(:mtr_available, DeepDiagnostic.available?())}
  end

  @impl true
  def handle_info({:sweep, verdict, row}, socket) do
    history = [row | socket.assigns.history] |> Enum.reject(&is_nil/1) |> Enum.take(60)
    total = socket.assigns.total_all + if(row, do: 1, else: 0)

    {:noreply,
     socket
     |> assign(:verdict, verdict)
     |> assign(:history, history)
     |> assign(:stats, stats(history))
     |> assign(:total_all, total)
     |> assign(:spike_events, Measurements.count_spike_events())
     |> refresh_timeline_on_sweep(row)}
  end

  # Continuous stability stats for one segment (router/internet) arrive ~0.5/s.
  def handle_info({:stability, key, stats}, socket) do
    {:noreply, assign(socket, :stability, Map.put(socket.assigns.stability, key, stats))}
  end

  @impl true
  def handle_event("sweep_now", _params, socket) do
    # Async: the verdict arrives via the {:sweep, ...} broadcast above.
    Monitor.sweep_now()
    {:noreply, socket}
  end

  def handle_event("toggle_monitor", _params, socket) do
    if socket.assigns.running do
      Monitor.pause()
      SpikeMonitor.pause_all()
    else
      Monitor.resume()
      SpikeMonitor.resume_all()
    end

    {:noreply, assign(socket, :running, Monitor.running?())}
  end

  def handle_event("toggle_segment", %{"key" => key}, socket) do
    # Clicking the open segment again collapses it; clicking any other segment
    # swaps the content and (re)opens. We never null `proof_key` on close, so the
    # panel keeps its content through the collapse animation.
    socket =
      if socket.assigns.proof_open and socket.assigns.proof_key == key do
        assign(socket, :proof_open, false)
      else
        socket
        |> assign(:proof_key, key)
        |> assign(:proof_open, true)
      end

    {:noreply, socket}
  end

  def handle_event("open_timeline", _params, socket) do
    {:noreply,
     socket
     |> assign(:timeline_open, true)
     |> load_timeline(0)}
  end

  def handle_event("close_timeline", _params, socket),
    do: {:noreply, assign(socket, :timeline_open, false)}

  # Continuous drag-pan: the hook pushes the absolute target offset (sweeps back
  # from now) as the cursor moves; `load_timeline` clamps it to the history.
  def handle_event("pan_to", %{"offset" => offset}, socket) when is_integer(offset) do
    {:noreply, load_timeline(socket, offset)}
  end

  # Relative step-pan (e.g. for keyboard/buttons): +steps scrolls back in time.
  def handle_event("pan_timeline", %{"steps" => steps}, socket) when is_integer(steps) do
    {:noreply, load_timeline(socket, socket.assigns.tl_offset + steps)}
  end

  def handle_event("jump_now", _params, socket),
    do: {:noreply, load_timeline(socket, 0)}

  def handle_event("clear_data", _params, socket) do
    deleted = Measurements.reset()
    Monitor.reset()
    SpikeMonitor.reset_all()

    {:noreply,
     socket
     |> assign(:history, [])
     |> assign(:stats, stats([]))
     |> assign(:total_all, 0)
     |> assign(:spike_events, 0)
     |> assign(:proof_open, false)
     |> assign(:proof_key, nil)
     |> assign(:stability, initial_stability())
     |> assign(:deep, %{status: :idle, target: Targets.internet_target()})
     |> assign(:timeline_open, false)
     |> put_flash(:info, "Cleared #{deleted} recorded row(s) — starting fresh.")}
  end

  def handle_event("run_deep", _params, socket) do
    target = socket.assigns.deep.target

    socket =
      socket
      |> assign(:deep, %{status: :running, target: target})
      |> start_async(:deep, fn -> DeepDiagnostic.run(target) end)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:deep, {:ok, report}, socket) do
    # Stash it so an exported report can include this trace (it lives only here
    # otherwise — deep traces aren't part of the continuous sweep history).
    Monitor.put_deep(report)
    {:noreply, assign(socket, :deep, %{status: :done, target: report.target, report: report})}
  end

  def handle_async(:deep, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, :deep, %{
       status: :error,
       target: socket.assigns.deep.target,
       error: inspect(reason)
     })}
  end

  # --- render -------------------------------------------------------------

  @impl true
  def render(assigns) do
    router = pseg(assigns.verdict, :router)
    internet = pseg(assigns.verdict, :internet)
    dns = pseg(assigns.verdict, :dns)
    web = pseg(assigns.verdict, :web)
    usable = combined_usable(dns, web)

    # The pipeline: 4 nodes joined by 3 links. Each node takes the state of the
    # link arriving at it, so the first non-green circle marks where it breaks.
    nodes = [
      %{label: "You", icon: "monitor", state: :healthy},
      %{label: "Router", icon: "wifi", state: router.state},
      %{label: "Your ISP", icon: "building-2", state: internet.state},
      %{label: "Internet", icon: "globe", state: usable.state}
    ]

    links = [
      %{seg: router, caption: "Local network"},
      %{seg: internet, caption: "To the open internet"},
      %{seg: usable, caption: "Names & sites"}
    ]

    segs_by_key = %{
      router: router,
      internet: internet,
      dns: dns,
      web: web,
      usable: usable
    }

    proof_seg =
      case assigns.proof_key && safe_existing_atom(assigns.proof_key) do
        nil -> nil
        key -> Map.get(segs_by_key, key)
      end

    assigns =
      assigns
      |> assign(:nodes, nodes)
      |> assign(:links, links)
      |> assign(:segs_by_key, segs_by_key)
      |> assign(:proof_seg, proof_seg)

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-5 pb-16">
        <!-- Header -->
        <div class="flex items-center justify-between flex-wrap gap-3">
          <div>
            <h1 class="text-2xl font-bold flex items-center gap-2">
              <.lucide name="satellite-dish" class="size-6 text-primary" /> DropDoctor
            </h1>
            <p class="text-sm opacity-70">
              Is it you, your router, or your ISP? Find out — with proof.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <button class="btn btn-sm tc-btn" phx-click="toggle_monitor">
              <%= if @running do %>
                <.lucide name="pause" class="size-4" /> Pause
              <% else %>
                <.lucide name="play" class="size-4" /> Resume
              <% end %>
            </button>
            <button class="btn btn-sm tc-btn tc-btn-primary" phx-click="sweep_now">
              <.lucide name="refresh-cw" class="size-4" /> Test now
            </button>
          </div>
        </div>

        <%= if @wsl_warning do %>
          <div class="alert alert-info text-sm">
            <span>
              <strong>WSL detected.</strong>
              We couldn't reach the Windows host to find your physical router, so
              the "router" hop is the WSL virtual switch and router vs. ISP
              attribution may be off. Restart the app with
              <code class="px-1">ROUTER_IP=192.168.1.1</code>
              (your real gateway) to fix it.
            </span>
          </div>
        <% end %>
        
    <!-- PIPELINE HERO — verdict banner with status wash + elevation -->
        <div class={"card overflow-hidden border border-base-300 tc-hero #{hero_tint(@verdict.status)}"}>
          <div class="card-body gap-5">
            <!-- Verdict banner -->
            <div class="space-y-2">
              <div class="flex items-center gap-3 flex-wrap">
                <span class={"tc-pill #{verdict_pill(@verdict.status)}"}>
                  {String.upcase(to_string(@verdict.status))}
                </span>
                <span class="text-sm opacity-70">
                  Likely cause: <span class="font-semibold">{culprit_label(@verdict.culprit)}</span>
                </span>
              </div>
              <h2 class={"text-2xl sm:text-3xl font-bold #{status_text(@verdict.status)}"}>
                {@verdict.headline}
              </h2>
              <p class="max-w-3xl text-sm opacity-80">{Map.get(@verdict, :detail)}</p>
              <%= if Map.get(@verdict, :provisional?) and Map.get(@verdict, :samples, 0) > 0 do %>
                <div class="text-xs opacity-50">
                  Confirming — verdict based on {@verdict.samples} of 5 readings so far
                </div>
              <% end %>
            </div>
            
    <!-- The animated path (+ the measurement it reveals, kept together so the
                 panel collapses without leaving a gap) -->
            <div>
              <div class="flex items-stretch gap-1 sm:gap-2 overflow-x-auto py-2">
                <%= for {node, i} <- Enum.with_index(@nodes) do %>
                  <!-- Node -->
                  <div class="flex flex-col items-center gap-1.5 shrink-0 w-16 sm:w-20">
                    <div class={"size-12 sm:size-14 rounded-full grid place-items-center border-2 bg-base-100 #{node_ring(node.state)} #{node_alert(node.state)}"}>
                      <.lucide name={node.icon} class="size-6 sm:size-7" />
                    </div>
                    <span class="text-xs font-semibold text-center leading-tight">{node.label}</span>
                  </div>
                  
    <!-- Link (after every node except the last). Clicking reveals its raw
                       measurement below; the active link gets a soft chip + caret. -->
                  <%= if link = Enum.at(@links, i) do %>
                    <% active = @proof_open and @proof_key == to_string(link.seg.key) %>
                    <button
                      type="button"
                      class={"tc-link-btn flex-1 min-w-[3rem] flex flex-col items-center justify-center gap-1.5 px-1 py-1 rounded-lg group cursor-pointer #{active && "tc-link-btn-active"}"}
                      phx-click="toggle_segment"
                      phx-value-key={link.seg.key}
                      aria-expanded={to_string(active)}
                      title="Show the raw measurement"
                    >
                      <span class={"text-xs font-mono font-semibold #{status_text(link.seg.state)}"}>
                        {link_latency(link.seg)}
                      </span>
                      <span class={"tc-link h-1.5 w-full rounded-full #{link_color(link.seg.state)} #{not @running && "tc-link-paused"}"}>
                      </span>
                      <span class={"text-[10px] uppercase tracking-wide text-center leading-tight flex items-center gap-1 transition-opacity #{if active, do: "opacity-90", else: "opacity-50 group-hover:opacity-80"}"}>
                        {link.caption}
                        <.lucide
                          name="chevron-down"
                          class={"size-3 -mr-1 transition-all #{if active, do: "rotate-180 opacity-100", else: "opacity-0 group-hover:opacity-60"}"}
                        />
                      </span>
                    </button>
                  <% end %>
                <% end %>
              </div>
              
    <!-- The raw measurement, smoothly expanding/collapsing in place -->
              <div class={"tc-proof #{@proof_open && "tc-proof-open"}"}>
                <div class="tc-proof-clip">
                  <%= if @proof_seg do %>
                    <div class="tc-cmd mt-4">
                      <div class="tc-cmd-head">
                        <span class="flex items-center gap-2 min-w-0">
                          <span class={"tc-cmd-dot #{link_color(@proof_seg.state)}"}></span>
                          <span class="truncate">{@proof_seg.label}</span>
                          <span class="opacity-40 hidden sm:inline">· live measurement</span>
                        </span>
                        <span class={"font-mono shrink-0 #{status_text(@proof_seg.state)}"}>
                          {@proof_seg.summary}
                        </span>
                      </div>
                      <%= if @proof_seg.key == :usable do %>
                        <pre class="tc-cmd-body tc-secret">{@segs_by_key.dns.raw}
    {@segs_by_key.web.raw}</pre>
                      <% else %>
                        <pre class="tc-cmd-body tc-secret">{@proof_seg.raw}</pre>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>

            <%= if action = Map.get(@verdict, :action) do %>
              <div class="alert alert-warning text-sm">
                <span><strong>What to do:</strong> {action}</span>
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- BENTO GRID -->
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <!-- Stability -->
          <div class="card border border-base-300 tc-panel">
            <div class="card-body gap-3">
              <h3 class="text-sm font-semibold flex items-center gap-2 pb-2 mb-1 border-b border-base-300">
                <.lucide name="activity" class="size-4" /> Live stability
              </h3>
              <%= for {key, name} <- [internet: "Internet", router: "Router"] do %>
                <div>
                  <div class="text-xs font-semibold opacity-70 mb-1">{name}</div>
                  <%= case @stability[key] do %>
                    <% %{sample_count: n, received: 0, mode: :tcp} when n > 0 -> %>
                      <div class="text-xs opacity-50 leading-snug">
                        no reply — this host isn't answering right now (see the verdict above)
                      </div>
                    <% %{sample_count: n, received: 0} when n > 0 -> %>
                      <div class="text-xs opacity-50 leading-snug">
                        no ICMP reply here — real traffic is getting through (see the verdict above)
                      </div>
                    <% %{sample_count: n} = st when n > 0 -> %>
                      <div class="grid grid-cols-2 gap-x-3 gap-y-0.5 font-mono text-xs">
                        <div class="flex justify-between">
                          <span class="opacity-50">jitter</span><span>{fmt_ms(st.jitter_ms)}</span>
                        </div>
                        <div class="flex justify-between">
                          <span class="opacity-50">p99</span><span>{fmt_ms(st.p99_ms)}</span>
                        </div>
                        <div class="flex justify-between">
                          <span class="opacity-50">spikes</span><span>{st.spike_count}</span>
                        </div>
                        <div class="flex justify-between">
                          <span class="opacity-50">loss</span><span>{fmt_pct(st.loss_pct)}</span>
                        </div>
                      </div>
                    <% _ -> %>
                      <div class="text-xs opacity-40 font-mono">sampling…</div>
                  <% end %>
                </div>
              <% end %>
              <p class="text-[10px] opacity-40 leading-snug">
                ~5×/sec between checks. Jitter & spikes are what cause stutter even when the average looks fine.
              </p>
            </div>
          </div>
          
    <!-- History -->
          <div class="card border border-base-300 tc-panel">
            <div class="card-body gap-3">
              <h3 class="text-sm font-semibold flex items-center justify-between gap-2 pb-2 mb-1 border-b border-base-300">
                <span class="flex items-center gap-2">
                  <.lucide name="bar-chart" class="size-4" /> Recent history
                </span>
                <button
                  type="button"
                  class="opacity-50 hover:opacity-100 transition-opacity"
                  phx-click="open_timeline"
                  title="Expand the timeline — router vs. ISP, side by side"
                >
                  <.lucide name="maximize-2" class="size-3.5" />
                </button>
              </h3>
              <button
                type="button"
                class="flex items-end gap-px h-20 overflow-hidden w-full cursor-pointer"
                title="Click to expand — see router vs. ISP over time"
                phx-click="open_timeline"
              >
                <%= for s <- Enum.reverse(@history) do %>
                  <div
                    class={"flex-1 min-w-[2px] rounded-sm #{bar_color(s.status)}"}
                    style={"height: #{bar_height(s.internet_rtt_ms)}%"}
                    title={"#{s.status} · internet #{fmt(s.internet_rtt_ms)}ms · #{fmt_time(s.inserted_at)}"}
                  >
                  </div>
                <% end %>
                <%= if @history == [] do %>
                  <span class="text-sm opacity-50">Collecting data…</span>
                <% end %>
              </button>
              <div class="flex items-baseline justify-between text-xs">
                <span class="font-mono text-2xl font-bold">{@stats.uptime}%</span>
                <span class="opacity-50">uptime · {@stats.healthy}/{@stats.total} healthy</span>
              </div>
            </div>
          </div>
          
    <!-- Save proof -->
          <div class="card border border-base-300 tc-panel">
            <div class="card-body gap-3">
              <h3 class="text-sm font-semibold flex items-center gap-2 pb-2 mb-1 border-b border-base-300">
                <.lucide name="file-text" class="size-4" /> Save proof for your ISP
              </h3>
              <p class="text-xs opacity-60 leading-snug">
                A timestamped report with the verdict, per-segment evidence, your latest trace, and every spike caught between checks{spike_count_phrase(
                  @spike_events
                )}.
              </p>
              <div class="flex flex-col gap-2 mt-auto">
                <a
                  href="/report"
                  target="_blank"
                  rel="noopener"
                  class="btn btn-sm tc-btn tc-btn-primary justify-start"
                >
                  <.lucide name="file-text" class="size-4" /> Open report (Save as PDF)
                </a>
                <a href="/report.csv" download class="btn btn-sm tc-btn justify-start">
                  <.lucide name="download" class="size-4" /> Download CSV
                </a>
                <a href="/spikes.csv" download class="btn btn-sm tc-btn justify-start">
                  <.lucide name="zap" class="size-4" /> Spike log{spike_count_badge(@spike_events)}
                </a>
                <button
                  type="button"
                  class="btn btn-sm btn-ghost justify-start text-error/80 hover:text-error hover:bg-error/10"
                  phx-click="clear_data"
                  data-confirm="This permanently deletes all recorded sweeps and spike events for a clean slate. Download a CSV above first if you want to keep them. Continue?"
                >
                  <.lucide name="trash-2" class="size-4" /> Clear recorded data
                </button>
              </div>
            </div>
          </div>
        </div>
        
    <!-- Deep diagnostic (per-hop trace) -->
        <div class="card border border-base-300 tc-panel">
          <div class="card-body gap-3">
            <div class="flex items-center justify-between flex-wrap gap-2">
              <h3 class="text-sm font-semibold flex items-center gap-2 pb-2 mb-1 border-b border-base-300">
                <.lucide name="route" class="size-4" />
                Deep diagnostic — per-hop trace to {@deep.target}
              </h3>
              <button
                class="btn btn-sm tc-btn"
                phx-click="run_deep"
                disabled={@deep.status == :running or not @mtr_available}
              >
                <%= if @deep.status == :running do %>
                  <span class="loading loading-spinner loading-xs"></span> Tracing…
                <% else %>
                  <.lucide name="route" class="size-4" /> Run deep diagnostic
                <% end %>
              </button>
            </div>

            <%= cond do %>
              <% not @mtr_available -> %>
                <p class="text-sm opacity-70">
                  The per-hop trace needs <code>mtr</code>. Install it: Linux <code>sudo apt install mtr</code>, macOS <code>brew install mtr</code>,
                  Windows: use WinMTR.
                </p>
              <% @deep.status == :idle -> %>
                <p class="text-sm opacity-70">
                  Pinpoints the exact hop where latency or loss is introduced — and names
                  your ISP's routers along the way. Takes ~15 seconds.
                </p>
              <% @deep.status == :running -> %>
                <div class="flex items-center gap-3 text-sm opacity-80">
                  <span class="loading loading-spinner loading-sm"></span>
                  Tracing every hop to {@deep.target}… this takes ~15 seconds.
                </div>
              <% @deep.status == :error -> %>
                <p class="text-sm text-error">Couldn't run the trace: {@deep.error}</p>
              <% true -> %>
                {render_deep_report(assigns)}
            <% end %>
          </div>
        </div>

        <p class="text-center text-xs opacity-40">
          Monitoring {if @running, do: "every 5s", else: "paused"} · {@total_all} sweeps recorded<%= case List.first(@history) do %>
            <% %{inserted_at: at} -> %>
              · last check
              <span class="tc-secret" data-utc={utc_iso(at)} data-utc-style="time">
                {fmt_time(at)}
              </span>
            <% _ -> %>
          <% end %>
          · open source
        </p>
      </div>

      <%= if @timeline_open do %>
        {render_timeline(assigns)}
      <% end %>
    </Layouts.app>
    """
  end

  # --- expanded timeline (router vs. ISP over time) -----------------------

  # SVG user-space dimensions. We keep the aspect ratio fixed (via CSS
  # `aspect-ratio`) so nothing distorts, and use non-scaling strokes so lines
  # stay crisp at any rendered size.
  @tl_w 1000
  @tl_h 320
  @tl_pad 10

  defp render_timeline(assigns) do
    assigns = assign(assigns, :tl, timeline(assigns.timeline_rows, assigns.timeline_spikes))

    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown="close_timeline"
      phx-key="Escape"
    >
      <div class="tl-overlay absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="close_timeline">
      </div>
      <div class="tl-modal relative card border border-base-300 tc-panel w-full max-w-5xl max-h-[90vh] overflow-auto">
        <div class="card-body gap-4">
          <div class="flex items-center justify-between gap-2 flex-wrap">
            <h3 class="text-sm font-semibold flex items-center gap-2">
              <.lucide name="activity" class="size-4" /> Timeline — router vs. ISP latency
            </h3>
            <div class="flex items-center gap-2">
              <%= if @tl_offset > 0 do %>
                <span class="tc-badge text-warning">Viewing past</span>
                <button type="button" class="btn btn-xs tc-btn" phx-click="jump_now">
                  <.lucide name="refresh-cw" class="size-3" /> Jump to now
                </button>
              <% else %>
                <span class="tc-badge text-success">● Live</span>
              <% end %>
              <button
                type="button"
                class="opacity-60 hover:opacity-100"
                phx-click="close_timeline"
                title="Close (Esc)"
              >
                <.lucide name="x" class="size-5" />
              </button>
            </div>
          </div>

          <p class="tl-muted text-xs opacity-60 max-w-2xl">
            Each point is one 5-second sweep — newest on the right, older to the left.
            <strong>Drag right</strong>
            to scroll back through the past (older events slide in from the left); drag left to return toward now. The amber band is the latency your
            <strong>ISP adds beyond your router</strong>
            — when it swells, the problem is past your equipment. A bump in <em>both</em>
            lines at once is local (your machine or Wi-Fi), not your provider.
            Vertical ticks mark brief spikes the smoothed line averages away — <strong>amber</strong>
            for your ISP, <strong>grey</strong>
            for local; dashed ticks are packet loss.
          </p>

          <%= if @timeline_rows == [] do %>
            <div class="tl-muted h-64 grid place-items-center text-sm opacity-50">
              No history yet — collecting data…
            </div>
          <% else %>
            <div class="relative">
              <!-- The SVG inside is drawn and panned entirely by the hook; we mark
                   it phx-update="ignore" so LiveView never fights the live drag
                   transform. New data arrives as the data-series / data-offset
                   attributes, which the hook reads on update. -->
              <div
                id="tl-pan"
                phx-hook=".TimelinePan"
                phx-update="ignore"
                data-series={@tl.series}
                data-offset={@tl_offset}
                data-window={@tl.n}
                class="overflow-hidden cursor-grab active:cursor-grabbing select-none block"
                style={"touch-action: none; aspect-ratio: #{@tl.w} / #{@tl.h}"}
              >
              </div>
              <span class="tl-muted absolute top-0 left-1 text-[10px] opacity-50 font-mono pointer-events-none">
                {round(@tl.max)}ms
              </span>
              <span class="tl-muted absolute bottom-0 left-1 text-[10px] opacity-50 font-mono pointer-events-none">
                0ms
              </span>
            </div>

            <div class="tl-muted flex justify-between text-[10px] opacity-50 font-mono">
              <span>
                older ·
                <span class="tc-secret" data-utc={utc_iso(@tl.first_at)} data-utc-style="time">
                  {fmt_time(@tl.first_at)}
                </span>
              </span>
              <span>{@tl.n} sweeps · ~{@tl.minutes} min</span>
              <span>
                <span class="tc-secret" data-utc={utc_iso(@tl.last_at)} data-utc-style="time">
                  {fmt_time(@tl.last_at)}
                </span>
                · newer
              </span>
            </div>

            <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs">
              <span class="flex items-center gap-1.5">
                <span class="inline-block w-4 h-0.5 bg-primary"></span> Internet (total)
              </span>
              <span class="flex items-center gap-1.5">
                <span class="inline-block w-4 h-0 border-t border-dashed border-base-content/50">
                </span>
                Router (local)
              </span>
              <span class="flex items-center gap-1.5">
                <span class="inline-block w-3 h-2.5 bg-warning/30"></span>
                ISP added (internet − router)
              </span>
              <span class="flex items-center gap-1.5">
                <span class="inline-block size-2 rounded-full bg-warning"></span>
                ISP spike (confirmed)
              </span>
              <span class="flex items-center gap-1.5">
                <span class="inline-block size-2 rounded-full bg-warning/60"></span> One route only
              </span>
              <span class="flex items-center gap-1.5">
                <span class="inline-block size-2 rounded-full bg-base-content/50"></span> Local spike
              </span>
            </div>
          <% end %>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".TimelinePan">
        export default {
          mounted() {
            this.dragging = false
            this.startX = 0
            this.lastX = 0
            this.dx = 0
            this.startOffset = 0
            this.lastPushed = null
            this.raf = null

            // The hook owns the SVG so LiveView's DOM patching never touches the
            // live transform. We draw into our own child of the (ignored) root.
            this.content = document.createElement("div")
            this.content.style.willChange = "transform"
            this.el.appendChild(this.content)
            this.draw()

            this.down = (e) => {
              this.dragging = true
              this.startX = e.clientX
              this.lastX = e.clientX
              this.dx = 0
              this.startOffset = this.offset()
              this.lastPushed = this.startOffset
              this.content.style.transition = ""
            }
            this.move = (e) => {
              if (!this.dragging) return
              this.lastX = e.clientX
              if (!this.raf) this.raf = requestAnimationFrame(() => this.frame())
            }
            this.up = () => {
              if (!this.dragging) return
              this.dragging = false
              if (this.raf) { cancelAnimationFrame(this.raf); this.raf = null }
              // Trailing sync: make sure the exact release position is loaded.
              const desired = this.targetOffset()
              if (desired !== this.lastPushed) {
                this.lastPushed = desired
                this.pushEvent("pan_to", { offset: desired })
              }
              this.dx = 0
              // Settle the sub-step remainder back to the data's true position.
              this.content.style.transition = "transform 0.12s ease-out"
              this.content.style.transform = "translate3d(0,0,0)"
            }

            this.el.addEventListener("pointerdown", this.down)
            window.addEventListener("pointermove", this.move)
            window.addEventListener("pointerup", this.up)
          },

          // Fresh data (new offset/series) arrived from the server: redraw and,
          // mid-drag, re-anchor the transform so the cursor stays glued to the data.
          updated() {
            this.draw()
            if (this.dragging) this.applyTransform()
          },

          destroyed() {
            window.removeEventListener("pointermove", this.move)
            window.removeEventListener("pointerup", this.up)
          },

          offset() { return parseInt(this.el.dataset.offset) || 0 },
          pps() { return this.el.clientWidth / (parseInt(this.el.dataset.window) || 1) },

          // The history position the cursor currently points at. Grab-and-drag
          // model: dragging RIGHT (dx > 0) pulls the strip right, revealing older
          // events from the left (larger offset); dragging LEFT returns toward now.
          targetOffset() {
            const pps = this.pps()
            return pps ? this.startOffset + Math.round(this.dx / pps) : this.startOffset
          },

          frame() {
            this.raf = null
            this.dx = this.lastX - this.startX
            const desired = this.targetOffset()
            // Load new data the instant the cursor crosses into the next sweep
            // (capped at one push per animation frame), so past events stream in
            // continuously instead of arriving in throttled chunks.
            if (desired !== this.lastPushed) {
              this.lastPushed = desired
              this.pushEvent("pan_to", { offset: desired })
            }
            this.applyTransform()
          },

          // Grab-and-drag: the axis runs older(left) → now(right). Dragging RIGHT
          // moves the chart RIGHT with your cursor, sliding older events in from
          // the left. The transform follows the cursor and cancels the per-frame
          // data shift, so the motion stays glued and never jitters.
          applyTransform() {
            const shifted = (this.offset() - this.startOffset) * this.pps()
            this.content.style.transform = `translate3d(${this.dx - shifted}px,0,0)`
          },

          draw() {
            const d = JSON.parse(this.el.dataset.series || "{}")
            if (!d.internet) { this.content.innerHTML = ""; return }
            const { w, h, pad } = d
            const gy = (f) => h - pad - f * (h - 2 * pad)
            const grid = [0, 0.5, 1].map((f) =>
              `<line x1="0" x2="${w}" y1="${gy(f)}" y2="${gy(f)}" class="tl-grid text-base-content/15" stroke="currentColor" stroke-width="1" vector-effect="non-scaling-stroke"/>`
            ).join("")
            const marks = (d.markers || []).map((m) =>
              `<rect x="${m.x - 1.5}" y="0" width="3" height="${h}" class="tl-marker ${m.status === "down" ? "text-error" : "text-warning"}" fill="currentColor" fill-opacity="0.14"/>`
            ).join("")
            // Logged spike/loss events as vertical ticks: amber = your ISP
            // (confirmed across two providers), faint amber = one route only
            // (not proven provider-wide), muted = local (machine/Wi-Fi); dashed =
            // brief packet loss. A <title> gives a hover tooltip with the detail.
            const esc = (s) => String(s).replace(/[<&>]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;" }[c]))
            const spikes = (d.spikes || []).map((s) => {
              const isp = s.source === "isp"
              const oneRoute = s.source === "isp_unconfirmed"
              const cls = isp ? "text-warning" : oneRoute ? "text-warning/60" : "text-base-content/50"
              const dash = s.kind === "loss" ? `stroke-dasharray="2 3"` : ""
              const op = isp ? 0.6 : oneRoute ? 0.5 : 0.4
              return `<g class="tl-spike ${cls}"><title>${esc(s.label)}</title>` +
                `<line x1="${s.x}" x2="${s.x}" y1="10" y2="${h}" stroke="currentColor" stroke-width="1" stroke-opacity="${op}" ${dash} vector-effect="non-scaling-stroke"/>` +
                `<circle cx="${s.x}" cy="7" r="3" fill="currentColor" fill-opacity="${isp ? 0.95 : oneRoute ? 0.8 : 0.65}"/>` +
              `</g>`
            }).join("")
            this.content.innerHTML =
              `<svg viewBox="0 0 ${w} ${h}" class="w-full block" style="aspect-ratio:${w}/${h}">` +
                grid + marks +
                `<polygon class="tl-band text-warning" fill="currentColor" fill-opacity="0.16" stroke="none" points="${d.band}"/>` +
                `<polyline class="tl-router text-base-content/40" fill="none" stroke="currentColor" stroke-width="1.5" stroke-dasharray="4 3" vector-effect="non-scaling-stroke" points="${d.router}"/>` +
                `<polyline class="text-primary" fill="none" stroke="currentColor" stroke-width="2" vector-effect="non-scaling-stroke" points="${d.internet}"/>` +
                spikes +
              `</svg>`
          }
        }
      </script>
    </div>
    """
  end

  # Load the timeline window at `offset` sweeps back from now, clamped to the
  # bounds of the recorded history.
  defp load_timeline(socket, offset) do
    max_off = max(socket.assigns.total_all - @tl_window, 0)
    offset = offset |> max(0) |> min(max_off)

    rows = Measurements.window(@tl_window, offset)

    socket
    |> assign(:tl_offset, offset)
    |> assign(:timeline_rows, rows)
    |> assign(:timeline_spikes, window_spikes(rows))
  end

  # The logged spike/loss events that fall inside the currently-shown window,
  # annotated with their likely source so the timeline can colour them (amber =
  # ISP, muted = local). Pulled from the continuous sampler, not the 5s sweeps —
  # these are the brief blips the smoothed line deliberately averages away.
  defp window_spikes([]), do: []

  defp window_spikes(rows) do
    from = tl_at(List.first(rows))
    to = tl_at(List.last(rows))

    if from && to do
      # Pad the query by the co-occurrence window so a spike whose cross-segment
      # twin sits just outside the visible range is still present when annotate/1
      # classifies source — otherwise an edge event loses its partner and a local
      # common-mode blip gets mislabelled "ISP". Render only the events actually
      # inside [from, to].
      pad = SpikeAnalysis.co_window_ms()
      ctx_from = DateTime.add(from, -pad, :millisecond)
      ctx_to = DateTime.add(to, pad, :millisecond)

      Measurements.spike_events_between(ctx_from, ctx_to)
      |> SpikeAnalysis.annotate()
      |> Enum.filter(&in_window?(&1, from, to))
    else
      []
    end
  end

  defp in_window?(%{occurred_at: at}, from, to),
    do: DateTime.compare(at, from) != :lt and DateTime.compare(at, to) != :gt

  # On each new sweep while the timeline is open: the live edge (offset 0) tracks
  # now; a panned-into-the-past view shifts one step older so it stays anchored to
  # the same absolute moment instead of sliding under you.
  defp refresh_timeline_on_sweep(%{assigns: %{timeline_open: false}} = socket, _row), do: socket

  defp refresh_timeline_on_sweep(socket, row) do
    bump = if socket.assigns.tl_offset > 0 and row, do: 1, else: 0
    load_timeline(socket, socket.assigns.tl_offset + bump)
  end

  # Build everything the timeline SVG needs from the history rows (newest-first
  # in the socket; charted oldest → newest, left → right).
  defp timeline(history, spikes) do
    # Oldest-first → plotted left-to-right, so the newest sweep sits on the right
    # (now-on-right). `history` (the pan window) already arrives oldest-first.
    rows = history
    inet = Enum.map(rows, & &1.internet_rtt_ms)
    rtr = Enum.map(rows, & &1.router_rtt_ms)
    max = tl_max(inet ++ rtr)
    n = length(rows)

    internet = tl_points(inet, max, n)
    router = tl_points(rtr, max, n)
    band = tl_band(inet, rtr, max, n)
    markers = tl_markers(rows, n)

    first_at = tl_at(List.first(rows))
    last_at = tl_at(List.last(rows))

    %{
      w: @tl_w,
      h: @tl_h,
      max: max,
      n: n,
      minutes: max(round(n * 5 / 60), 1),
      first_at: first_at,
      last_at: last_at,
      # The SVG is drawn client-side (so panning stays smooth), so ship the
      # precomputed geometry to the hook as JSON rather than rendering it here.
      series:
        Jason.encode!(%{
          w: @tl_w,
          h: @tl_h,
          pad: @tl_pad,
          internet: internet,
          router: router,
          band: band,
          markers: markers,
          spikes: tl_spikes(spikes, first_at, last_at)
        })
    }
  end

  # Place each logged spike on the time axis. The line/band are indexed by sweep
  # position, but spikes carry an absolute timestamp, so we map by *time* across
  # the window's [first_at, last_at] span (sweeps are ~uniform 5s, so the two
  # agree closely). Each marker ships its x, source (for colour) and kind (latency
  # vs loss) plus a label for a hover tooltip.
  defp tl_spikes([], _first, _last), do: []
  defp tl_spikes(_spikes, %DateTime{} = from, %DateTime{} = to) when from == to, do: []

  defp tl_spikes(spikes, %DateTime{} = from, %DateTime{} = to) do
    span = DateTime.diff(to, from, :millisecond)

    if span <= 0 do
      []
    else
      Enum.map(spikes, fn e ->
        frac = DateTime.diff(e.occurred_at, from, :millisecond) / span
        x = (frac * @tl_w) |> max(0.0) |> min(@tl_w * 1.0)

        %{
          x: Float.round(x, 1),
          source: to_string(Map.get(e, :source, :local)),
          kind: e.kind,
          label: spike_label(e)
        }
      end)
    end
  end

  defp tl_spikes(_spikes, _from, _to), do: []

  defp spike_label(e) do
    detail =
      case e.kind do
        "latency" -> "#{fmt(e.peak_ms)} ms spike"
        "loss" -> "#{fmt(e.loss_pct)}% loss"
        _ -> "event"
      end

    "#{SpikeAnalysis.source_label(Map.get(e, :source, :local))} · #{detail}"
  end

  # Y-scale ceiling: the largest plotted value with 10% headroom, never below
  # 50ms so a calm link doesn't get a misleadingly dramatic scale.
  defp tl_max(vals) do
    case Enum.filter(vals, &is_number/1) do
      [] -> 50.0
      nums -> max(Enum.max(nums) * 1.1, 50.0)
    end
  end

  defp tl_points(values, max, n) do
    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {v, i} -> "#{r1(tl_x(i, n))},#{r1(tl_y(v, max))}" end)
  end

  # Polygon spanning internet (top, left→right) then router (bottom, right→left)
  # — the filled area is the ISP's latency contribution over time.
  defp tl_band(inet, rtr, max, n) do
    top =
      inet
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> "#{r1(tl_x(i, n))},#{r1(tl_y(v, max))}" end)

    bottom =
      rtr
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> "#{r1(tl_x(i, n))},#{r1(tl_y(v, max))}" end)
      |> Enum.reverse()

    Enum.join(top ++ bottom, " ")
  end

  defp tl_markers(rows, n) do
    rows
    |> Enum.with_index()
    |> Enum.filter(fn {s, _i} -> s.status != "healthy" end)
    |> Enum.map(fn {s, i} -> %{x: r1(tl_x(i, n)), status: s.status} end)
  end

  defp tl_x(_i, n) when n <= 1, do: 0.0
  defp tl_x(i, n), do: i / (n - 1) * @tl_w

  # Missing RTT (e.g. a 100%-loss sweep) plots at the baseline; the red marker
  # band drawn for that sweep is what flags it, not the line height.
  defp tl_y(v, _max) when not is_number(v), do: @tl_h - @tl_pad

  defp tl_y(v, max) do
    frac = v |> Kernel./(max) |> min(1.0) |> max(0.0)
    @tl_h - @tl_pad - frac * (@tl_h - 2 * @tl_pad)
  end

  defp tl_at(%{inserted_at: at}), do: at
  defp tl_at(_), do: nil

  defp r1(n), do: Float.round(n / 1, 1)

  # Inline Lucide icons (https://lucide.dev, ISC/MIT). Kept as raw SVG so there's
  # no asset-pipeline dependency — clean line icons that inherit text color.
  attr :name, :string, required: true
  attr :class, :string, default: "size-5"

  def lucide(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
      aria-hidden="true"
    >
      {Phoenix.HTML.raw(lucide_paths(@name))}
    </svg>
    """
  end

  defp lucide_paths("satellite-dish"),
    do:
      ~S(<path d="M4 10a7.31 7.31 0 0 0 10 10Z"/><path d="m9 15 3-3"/><path d="M17 13a6 6 0 0 0-6-6"/><path d="M21 13A10 10 0 0 0 11 3"/>)

  defp lucide_paths("pause"),
    do:
      ~S(<rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/>)

  defp lucide_paths("play"), do: ~S(<polygon points="6 3 20 12 6 21 6 3"/>)

  defp lucide_paths("refresh-cw"),
    do:
      ~S(<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>)

  defp lucide_paths("route"),
    do:
      ~S(<circle cx="6" cy="19" r="3"/><path d="M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15"/><circle cx="18" cy="5" r="3"/>)

  defp lucide_paths("file-text"),
    do:
      ~S(<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>)

  defp lucide_paths("download"),
    do:
      ~S(<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/>)

  defp lucide_paths("zap"),
    do:
      ~S(<path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>)

  defp lucide_paths("monitor"),
    do:
      ~S(<rect width="20" height="14" x="2" y="3" rx="2"/><line x1="8" x2="16" y1="21" y2="21"/><line x1="12" x2="12" y1="17" y2="21"/>)

  defp lucide_paths("wifi"),
    do:
      ~S(<path d="M12 20h.01"/><path d="M2 8.82a15 15 0 0 1 20 0"/><path d="M5 12.859a10 10 0 0 1 14 0"/><path d="M8.5 16.429a5 5 0 0 1 7 0"/>)

  defp lucide_paths("building-2"),
    do:
      ~S(<path d="M6 22V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18Z"/><path d="M6 12H4a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2"/><path d="M18 9h2a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-2"/><path d="M10 6h4"/><path d="M10 10h4"/><path d="M10 14h4"/><path d="M10 18h4"/>)

  defp lucide_paths("globe"),
    do:
      ~S(<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>)

  defp lucide_paths("activity"),
    do:
      ~S(<path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2"/>)

  defp lucide_paths("bar-chart"),
    do:
      ~S(<line x1="12" x2="12" y1="20" y2="10"/><line x1="18" x2="18" y1="20" y2="4"/><line x1="6" x2="6" y1="20" y2="16"/>)

  defp lucide_paths("maximize-2"),
    do:
      ~S(<polyline points="15 3 21 3 21 9"/><polyline points="9 21 3 21 3 15"/><line x1="21" x2="14" y1="3" y2="10"/><line x1="3" x2="10" y1="21" y2="14"/>)

  defp lucide_paths("x"), do: ~S(<path d="M18 6 6 18"/><path d="m6 6 12 12"/>)

  defp lucide_paths("chevron-down"), do: ~S(<path d="m6 9 6 6 6-6"/>)

  defp lucide_paths("trash-2"),
    do:
      ~S(<path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><line x1="10" x2="10" y1="11" y2="17"/><line x1="14" x2="14" y1="11" y2="17"/>)

  defp lucide_paths(_), do: ""

  # --- deep diagnostic rendering ------------------------------------------

  defp render_deep_report(assigns) do
    assigns = assign(assigns, :report, assigns.deep.report)

    ~H"""
    <div class="space-y-3">
      <div>
        <div class={"font-semibold #{status_text(@report.status)}"}>
          {state_dot(@report.status)} {@report.headline}
        </div>
        <p class="text-sm opacity-80 mt-1">{@report.detail}</p>
      </div>

      <div class="overflow-x-auto">
        <div class="space-y-1 text-sm min-w-[28rem]">
          <%= for hop <- @report.hops do %>
            <div class={"flex items-center gap-2 rounded px-2 py-1 #{hop_row_class(hop)}"}>
              <span class="font-mono opacity-50 w-6 text-right">{hop.count}</span>
              <span class="tc-secret font-mono flex-1 truncate min-w-0">{display_host(hop)}</span>
              <span class={"tc-badge shrink-0 #{deep_zone_class(hop.zone)}"}>
                {deep_zone_label(hop.zone)}
              </span>
              <span class={"font-mono w-16 text-right shrink-0 #{loss_class(hop)}"}>
                {fmt(hop.loss_pct)}%
              </span>
              <span class="font-mono w-20 text-right shrink-0 opacity-70">{fmt_ms(hop.avg)}</span>
            </div>
            <%= if hop.note do %>
              <div class="text-xs opacity-50 pl-10 pb-1">↳ {hop.note}</div>
            <% end %>
          <% end %>
        </div>
      </div>

      <div class="text-xs opacity-50">
        Columns: hop · host · zone · loss · avg latency. Loss only counts when it persists to the destination.
      </div>
    </div>
    """
  end

  defp display_host(%{host: h}) when h in ["???", nil], do: "(no response)"
  defp display_host(%{host: h}), do: h

  defp hop_row_class(%{loss_onset?: true}), do: "bg-error/10 border border-error/40"
  defp hop_row_class(%{latency_jump?: true}), do: "bg-warning/10"
  defp hop_row_class(%{phantom_loss?: true}), do: "opacity-50"
  defp hop_row_class(_), do: ""

  defp loss_class(%{phantom_loss?: true}), do: "opacity-40 line-through"
  defp loss_class(%{loss_pct: l}) when is_number(l) and l > 2.0, do: "text-error"
  defp loss_class(_), do: "opacity-70"

  defp deep_zone_label(:local), do: "Your network"
  defp deep_zone_label(:isp_edge), do: "ISP edge"
  defp deep_zone_label(:isp), do: "Your ISP"
  defp deep_zone_label(:transit), do: "Transit / CDN"
  defp deep_zone_label(:destination), do: "Destination"
  defp deep_zone_label(_), do: "—"

  defp deep_zone_class(:local), do: "text-info"
  defp deep_zone_class(:isp_edge), do: "text-warning"
  defp deep_zone_class(:isp), do: "text-warning"
  defp deep_zone_class(:destination), do: "text-success"
  defp deep_zone_class(_), do: "text-base-content/60"

  # Pull current stats for each ping host; falls back to nil if the monitors
  # aren't running (e.g. in tests, which set :start_monitor false).
  defp initial_stability do
    for key <- [:router, :internet], into: %{}, do: {key, safe_stats(key)}
  end

  defp safe_stats(key) do
    SpikeMonitor.stats(key)
  catch
    :exit, _ -> nil
  end

  defp fmt_pct(n) when is_number(n), do: "#{Float.round(n / 1, 1)}%"
  defp fmt_pct(_), do: "—"

  defp spike_count_phrase(0), do: ""
  defp spike_count_phrase(n), do: " (#{n} logged so far)"

  defp spike_count_badge(0), do: ""
  defp spike_count_badge(n), do: " (#{n})"

  defp fmt_ms(nil), do: "—"
  defp fmt_ms(n) when is_number(n), do: "#{Float.round(n / 1, 1)}ms"
  defp fmt_ms(_), do: "—"

  # --- pipeline helpers ---------------------------------------------------

  # Look up a segment by key, with a safe placeholder if it isn't present yet
  # (e.g. before the first sweep).
  defp pseg(verdict, key) do
    Enum.find(verdict.segments, &(&1.key == key)) ||
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

  # The final "can you actually use it" link folds DNS + page-load into one node
  # boundary (the Internet). State is the worse of the two; latency shows the
  # most user-relevant number (page load), falling back to DNS.
  defp combined_usable(dns, web) do
    state = worst_state([dns.state, web.state])

    %{
      key: :usable,
      label: "Names & sites (DNS + page load)",
      state: state,
      summary: "DNS #{dns.summary} · page #{web.summary}",
      metrics: %{rtt_ms: web.metrics[:ms] || dns.metrics[:ms]},
      raw: nil
    }
  end

  defp worst_state(states) do
    cond do
      :down in states -> :down
      :degraded in states -> :degraded
      Enum.any?(states, &(&1 == :unknown)) -> :unknown
      true -> :healthy
    end
  end

  defp link_latency(%{metrics: m}), do: fmt_ms(m[:rtt_ms])

  defp safe_existing_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  defp link_color(:healthy), do: "text-success"
  defp link_color(:degraded), do: "text-warning"
  defp link_color(:down), do: "text-error"
  defp link_color(_), do: "text-base-content/25"

  defp node_ring(:healthy), do: "border-success text-success"
  defp node_ring(:degraded), do: "border-warning text-warning"
  defp node_ring(:down), do: "border-error text-error"
  defp node_ring(_), do: "border-base-300 opacity-60"

  # Pulse the ring only where something is actually wrong, to draw the eye.
  defp node_alert(state) when state in [:degraded, :down], do: "tc-node-alert"
  defp node_alert(_), do: ""

  defp verdict_pill(:healthy), do: "tc-pill-healthy"
  defp verdict_pill(:degraded), do: "tc-pill-degraded"
  defp verdict_pill(:down), do: "tc-pill-down"
  defp verdict_pill(_), do: "tc-pill-unknown"

  # --- view helpers -------------------------------------------------------

  defp state_dot(:healthy), do: "🟢"
  defp state_dot(:degraded), do: "🟡"
  defp state_dot(:down), do: "🔴"
  defp state_dot(_), do: "⚪"

  defp status_text(:healthy), do: "text-success"
  defp status_text(:degraded), do: "text-warning"
  defp status_text(:down), do: "text-error"
  defp status_text(_), do: "opacity-60"

  defp hero_tint(:healthy), do: "tc-hero-healthy"
  defp hero_tint(:degraded), do: "tc-hero-degraded"
  defp hero_tint(:down), do: "tc-hero-down"
  defp hero_tint(_), do: "tc-hero-unknown"

  defp bar_color("healthy"), do: "bg-success"
  defp bar_color("degraded"), do: "bg-warning"
  defp bar_color("down"), do: "bg-error"
  defp bar_color(_), do: "bg-base-300"

  defp culprit_label(:none), do: "Nothing — all healthy"
  defp culprit_label(:local), do: "Your local network / router"
  defp culprit_label(:isp), do: "Your ISP"
  defp culprit_label(:dns), do: "DNS configuration"
  defp culprit_label(:web), do: "Bandwidth / destination"
  defp culprit_label(other), do: to_string(other)

  # internet latency mapped to a 10–100% bar; clamps so spikes stay readable
  defp bar_height(nil), do: 100
  defp bar_height(ms) when ms <= 0, do: 10
  defp bar_height(ms), do: min(100, max(10, round(ms / 2)))

  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: Float.round(n, 1)
  defp fmt(n), do: n

  defp fmt_time(%DateTime{} = dt) do
    dt |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_string()
  end

  defp fmt_time(_), do: ""

  # ISO-8601 in UTC for the client-side timezone toggle. A NaiveDateTime is
  # assumed UTC (gets a trailing Z) so the browser parses it correctly.
  defp utc_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp utc_iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt) <> "Z"
  defp utc_iso(_), do: ""

  defp stats([]), do: %{total: 0, healthy: 0, uptime: 100}

  defp stats(history) do
    total = length(history)
    healthy = Enum.count(history, &(&1.status == "healthy"))

    # Headline % is the *healthy* fraction so it agrees with the "X/Y healthy"
    # label beside it (a degraded-but-up sweep shouldn't read as a perfect score).
    %{total: total, healthy: healthy, uptime: round(healthy / total * 100)}
  end

  defp wsl_warning, do: Net.wsl_router_unresolved?()
end
