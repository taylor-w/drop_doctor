defmodule TrackConnWeb.DashboardLive do
  @moduledoc """
  The single-screen dashboard. Designed for the "lowest common denominator":
  the first thing you see is a giant traffic light and one plain sentence. The
  numbers and raw command output are there too, tucked into expandable sections
  for people who want them — so the same screen serves a panicked non-technical
  user and a network engineer.
  """
  use TrackConnWeb, :live_view

  alias TrackConn.{DeepDiagnostic, Measurements, Monitor, Net, SpikeMonitor, Targets}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Monitor.subscribe()
      Phoenix.PubSub.subscribe(TrackConn.PubSub, SpikeMonitor.topic())
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
     |> assign(:expanded, nil)
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
     |> assign(:spike_events, Measurements.count_spike_events())}
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
    expanded = if socket.assigns.expanded == key, do: nil, else: key
    {:noreply, assign(socket, :expanded, expanded)}
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

    expanded_seg =
      case assigns.expanded && safe_existing_atom(assigns.expanded) do
        nil -> nil
        key -> Map.get(segs_by_key, key)
      end

    assigns =
      assigns
      |> assign(:nodes, nodes)
      |> assign(:links, links)
      |> assign(:segs_by_key, segs_by_key)
      |> assign(:expanded_seg, expanded_seg)

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-5 pb-16">
        <!-- Header -->
        <div class="flex items-center justify-between flex-wrap gap-3">
          <div>
            <h1 class="text-2xl font-bold flex items-center gap-2">
              <.lucide name="satellite-dish" class="size-6 text-primary" /> track_conn
            </h1>
            <p class="text-sm opacity-70">
              Is it you, your router, or your ISP? Find out — with proof.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <button class="btn btn-sm" phx-click="toggle_monitor">
              <%= if @running do %>
                <.lucide name="pause" class="size-4" /> Pause
              <% else %>
                <.lucide name="play" class="size-4" /> Resume
              <% end %>
            </button>
            <button class="btn btn-sm btn-primary" phx-click="sweep_now">
              <.lucide name="refresh-cw" class="size-4" /> Test now
            </button>
          </div>
        </div>

        <%= if @wsl_warning do %>
          <div class="alert alert-info text-sm">
            <span>
              <strong>WSL detected.</strong>
              The "router" hop is your Windows host, not your physical router.
              For true router vs. ISP attribution, start the app with
              <code class="px-1">ROUTER_IP=192.168.1.1</code>
              (your real gateway).
            </span>
          </div>
        <% end %>

    <!-- PIPELINE HERO — verdict banner with status wash + elevation -->
        <div class={"card overflow-hidden border border-base-300 tc-hero #{hero_tint(@verdict.status)}"}>
          <div class="card-body gap-5">
            <!-- Verdict banner -->
            <div class="space-y-2">
              <div class="flex items-center gap-3 flex-wrap">
                <span class={"badge badge-lg gap-1.5 #{verdict_badge(@verdict.status)}"}>
                  <span class="text-base leading-none">{status_emoji(@verdict.status)}</span>
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

    <!-- The animated path -->
            <div class="flex items-stretch gap-1 sm:gap-2 overflow-x-auto py-2">
              <%= for {node, i} <- Enum.with_index(@nodes) do %>
                <!-- Node -->
                <div class="flex flex-col items-center gap-1.5 shrink-0 w-16 sm:w-20">
                  <div class={"size-12 sm:size-14 rounded-full grid place-items-center border-2 bg-base-100 #{node_ring(node.state)} #{node_alert(node.state)}"}>
                    <.lucide name={node.icon} class="size-6 sm:size-7" />
                  </div>
                  <span class="text-xs font-semibold text-center leading-tight">{node.label}</span>
                </div>

    <!-- Link (after every node except the last) -->
                <%= if link = Enum.at(@links, i) do %>
                  <button
                    type="button"
                    class="flex-1 min-w-[3rem] flex flex-col items-center justify-center gap-1.5 px-1 group cursor-pointer"
                    phx-click="toggle_segment"
                    phx-value-key={link.seg.key}
                    title="Click for the raw measurement"
                  >
                    <span class={"text-xs font-mono font-semibold #{status_text(link.seg.state)}"}>
                      {link_latency(link.seg)}
                    </span>
                    <span class={"tc-link h-1.5 w-full rounded-full #{link_color(link.seg.state)} #{not @running && "tc-link-paused"}"}>
                    </span>
                    <span class="text-[10px] uppercase tracking-wide opacity-50 text-center leading-tight group-hover:opacity-80">
                      {link.caption}
                    </span>
                  </button>
                <% end %>
              <% end %>
            </div>

    <!-- Expanded raw measurement (the proof) -->
            <%= if @expanded_seg do %>
              <div class="border-t border-base-300 pt-3 text-xs">
                <div class="flex items-center justify-between mb-2">
                  <span class="font-semibold opacity-70">
                    {@expanded_seg.label} — raw measurement (the proof)
                  </span>
                  <span class={"font-mono #{status_text(@expanded_seg.state)}"}>{@expanded_seg.summary}</span>
                </div>
                <%= if @expanded_seg.key == :usable do %>
                  <pre class="bg-base-200 rounded p-2 overflow-x-auto whitespace-pre-wrap">{@segs_by_key.dns.raw}
    {@segs_by_key.web.raw}</pre>
                <% else %>
                  <pre class="bg-base-200 rounded p-2 overflow-x-auto whitespace-pre-wrap">{@expanded_seg.raw}</pre>
                <% end %>
              </div>
            <% end %>

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
                    <% %{sample_count: n} = st when n > 0 -> %>
                      <div class="grid grid-cols-2 gap-x-3 gap-y-0.5 font-mono text-xs">
                        <div class="flex justify-between"><span class="opacity-50">jitter</span><span>{fmt_ms(st.jitter_ms)}</span></div>
                        <div class="flex justify-between"><span class="opacity-50">p99</span><span>{fmt_ms(st.p99_ms)}</span></div>
                        <div class="flex justify-between"><span class="opacity-50">spikes</span><span>{st.spike_count}</span></div>
                        <div class="flex justify-between"><span class="opacity-50">loss</span><span>{fmt_pct(st.loss_pct)}</span></div>
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
              <h3 class="text-sm font-semibold flex items-center gap-2 pb-2 mb-1 border-b border-base-300">
                <.lucide name="bar-chart" class="size-4" /> Recent history
              </h3>
              <div class="flex items-end gap-px h-20 overflow-hidden" title="oldest → newest">
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
              </div>
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
                A timestamped report with the verdict, per-segment evidence, your latest trace, and every spike caught between checks{spike_count_phrase(@spike_events)}.
              </p>
              <div class="flex flex-col gap-2 mt-auto">
                <a href="/report" target="_blank" rel="noopener" class="btn btn-sm btn-primary justify-start">
                  <.lucide name="file-text" class="size-4" /> Open report (Save as PDF)
                </a>
                <a href="/report.csv" download class="btn btn-sm btn-outline justify-start">
                  <.lucide name="download" class="size-4" /> Download CSV
                </a>
                <a href="/spikes.csv" download class="btn btn-sm btn-outline justify-start">
                  <.lucide name="zap" class="size-4" /> Spike log{spike_count_badge(@spike_events)}
                </a>
              </div>
            </div>
          </div>
        </div>

    <!-- Deep diagnostic (per-hop trace) -->
        <div class="card border border-base-300 tc-panel">
          <div class="card-body gap-3">
            <div class="flex items-center justify-between flex-wrap gap-2">
              <h3 class="text-sm font-semibold flex items-center gap-2 pb-2 mb-1 border-b border-base-300">
                <.lucide name="route" class="size-4" /> Deep diagnostic — per-hop trace to {@deep.target}
              </h3>
              <button
                class="btn btn-sm btn-outline"
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
          Monitoring {if @running, do: "every 5s", else: "paused"} · {@total_all} sweeps recorded · open source
        </p>
      </div>
    </Layouts.app>
    """
  end

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
    do: ~S(<path d="M22 12h-2.48a2 2 0 0 0-1.93 1.46l-2.35 8.36a.25.25 0 0 1-.48 0L9.24 2.18a.25.25 0 0 0-.48 0l-2.35 8.36A2 2 0 0 1 4.49 12H2"/>)

  defp lucide_paths("bar-chart"),
    do: ~S(<line x1="12" x2="12" y1="20" y2="10"/><line x1="18" x2="18" y1="20" y2="4"/><line x1="6" x2="6" y1="20" y2="16"/>)

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
              <span class="font-mono flex-1 truncate min-w-0">{display_host(hop)}</span>
              <span class={"badge badge-sm shrink-0 #{deep_zone_class(hop.zone)}"}>
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

  defp deep_zone_class(:local), do: "badge-info"
  defp deep_zone_class(:isp_edge), do: "badge-warning"
  defp deep_zone_class(:isp), do: "badge-warning badge-outline"
  defp deep_zone_class(:destination), do: "badge-success"
  defp deep_zone_class(_), do: "badge-ghost"

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

  defp verdict_badge(:healthy), do: "badge-success"
  defp verdict_badge(:degraded), do: "badge-warning"
  defp verdict_badge(:down), do: "badge-error"
  defp verdict_badge(_), do: "badge-ghost"

  # --- view helpers -------------------------------------------------------

  defp status_emoji(:healthy), do: "🟢"
  defp status_emoji(:degraded), do: "🟡"
  defp status_emoji(:down), do: "🔴"
  defp status_emoji(_), do: "⚪"

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

  defp stats([]), do: %{total: 0, healthy: 0, uptime: 100}

  defp stats(history) do
    total = length(history)
    healthy = Enum.count(history, &(&1.status == "healthy"))
    up = Enum.count(history, &(&1.status != "down"))

    %{total: total, healthy: healthy, uptime: round(up / total * 100)}
  end

  defp wsl_warning do
    Net.wsl?() and is_nil(System.get_env("ROUTER_IP")) and
      not String.starts_with?(Targets.router_target(), "192.168.")
  end
end
