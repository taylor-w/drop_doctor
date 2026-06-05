defmodule TrackConnWeb.DashboardLive do
  @moduledoc """
  The single-screen dashboard. Designed for the "lowest common denominator":
  the first thing you see is a giant traffic light and one plain sentence. The
  numbers and raw command output are there too, tucked into expandable sections
  for people who want them — so the same screen serves a panicked non-technical
  user and a network engineer.
  """
  use TrackConnWeb, :live_view

  alias TrackConn.{DeepDiagnostic, Measurements, Monitor, Net, Targets}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Monitor.subscribe()

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
     |> assign(:total_all, total)}
  end

  @impl true
  def handle_event("sweep_now", _params, socket) do
    # Async: the verdict arrives via the {:sweep, ...} broadcast above.
    Monitor.sweep_now()
    {:noreply, socket}
  end

  def handle_event("toggle_monitor", _params, socket) do
    if socket.assigns.running, do: Monitor.pause(), else: Monitor.resume()
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
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-4xl mx-auto space-y-6 pb-16">
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
        
    <!-- Hero verdict -->
        <div class={"card shadow-lg border-2 #{hero_border(@verdict.status)}"}>
          <div class="card-body items-center text-center gap-3">
            <div class={"text-6xl #{pulse(@running)}"}>{status_emoji(@verdict.status)}</div>
            <h2 class={"text-2xl font-bold #{status_text(@verdict.status)}"}>{@verdict.headline}</h2>
            <p class="max-w-2xl opacity-80">{Map.get(@verdict, :detail)}</p>
            <%= if action = Map.get(@verdict, :action) do %>
              <div class="alert alert-warning max-w-2xl text-sm mt-1">
                <span><strong>What to do:</strong> {action}</span>
              </div>
            <% end %>
            <div class="badge badge-outline mt-1">
              Likely cause: <span class="font-semibold ml-1">{culprit_label(@verdict.culprit)}</span>
            </div>
            <%= if Map.get(@verdict, :provisional?) and Map.get(@verdict, :samples, 0) > 0 do %>
              <div class="text-xs opacity-50">
                Confirming — verdict based on {@verdict.samples} of 5 readings so far
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- The ladder -->
        <div>
          <h3 class="text-sm font-semibold uppercase opacity-60 mb-2">
            The path from you to the internet
          </h3>
          <div class="space-y-2">
            <%= for seg <- @verdict.segments do %>
              <div class={"card card-compact border #{seg_border(seg.state)}"}>
                <div
                  class="card-body cursor-pointer"
                  phx-click="toggle_segment"
                  phx-value-key={seg.key}
                >
                  <div class="flex items-center justify-between gap-3">
                    <div class="flex items-center gap-3 min-w-0">
                      <span class="text-2xl">{state_dot(seg.state)}</span>
                      <div class="min-w-0">
                        <div class="font-semibold truncate">{seg.label}</div>
                        <div class="text-xs opacity-60 truncate">
                          {seg.target} · {seg.about}
                        </div>
                      </div>
                    </div>
                    <div class="text-right shrink-0">
                      <div class={"font-mono font-semibold #{status_text(seg.state)}"}>
                        {seg.summary}
                      </div>
                      <div class="text-xs opacity-50">{String.upcase(to_string(seg.state))}</div>
                    </div>
                  </div>

                  <%= if to_string(seg.key) == @expanded do %>
                    <div class="mt-3 pt-3 border-t border-base-300 text-xs">
                      <div class="font-semibold opacity-70 mb-1">Raw measurement (the proof):</div>
                      <pre class="bg-base-200 rounded p-2 overflow-x-auto whitespace-pre-wrap">{seg.raw}</pre>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- Deep diagnostic (per-hop trace) -->
        <div>
          <div class="flex items-center justify-between flex-wrap gap-2 mb-2">
            <h3 class="text-sm font-semibold uppercase opacity-60">
              Deep diagnostic — per-hop trace to {@deep.target}
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

          <div class="card border border-base-300">
            <div class="card-body">
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
        </div>
        
    <!-- Export for your ISP -->
        <div>
          <h3 class="text-sm font-semibold uppercase opacity-60 mb-2">Save proof for your ISP</h3>
          <div class="card border border-base-300">
            <div class="card-body flex-row items-center justify-between flex-wrap gap-3">
              <p class="text-sm opacity-70 max-w-md">
                Hand a support rep something concrete: a timestamped report with the verdict, the
                per-segment evidence, and your latest deep trace — plus the raw timeline as a spreadsheet.
              </p>
              <div class="flex items-center gap-2">
                <a href="/report" target="_blank" rel="noopener" class="btn btn-sm btn-primary">
                  <.lucide name="file-text" class="size-4" /> Open report (Save as PDF)
                </a>
                <a href="/report.csv" class="btn btn-sm btn-outline">
                  <.lucide name="download" class="size-4" /> Download CSV
                </a>
              </div>
            </div>
          </div>
        </div>
        
    <!-- History timeline -->
        <div>
          <h3 class="text-sm font-semibold uppercase opacity-60 mb-2">
            Recent history
            <span class="font-normal normal-case opacity-70">
              · {@stats.healthy}/{@stats.total} healthy · {@stats.uptime}% uptime
            </span>
          </h3>
          <div class="card border border-base-300">
            <div class="card-body">
              <div class="flex items-end gap-px h-16 overflow-hidden" title="oldest → newest">
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
              <div class="text-xs opacity-50 mt-1">
                Bar height = internet latency · color = verdict · hover for details
              </div>
            </div>
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

  defp fmt_ms(nil), do: "—"
  defp fmt_ms(n) when is_number(n), do: "#{Float.round(n / 1, 1)}ms"
  defp fmt_ms(_), do: "—"

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

  defp hero_border(:healthy), do: "border-success"
  defp hero_border(:degraded), do: "border-warning"
  defp hero_border(:down), do: "border-error"
  defp hero_border(_), do: "border-base-300"

  defp seg_border(:healthy), do: "border-success/40"
  defp seg_border(:degraded), do: "border-warning/60"
  defp seg_border(:down), do: "border-error/60"
  defp seg_border(_), do: "border-base-300"

  defp bar_color("healthy"), do: "bg-success"
  defp bar_color("degraded"), do: "bg-warning"
  defp bar_color("down"), do: "bg-error"
  defp bar_color(_), do: "bg-base-300"

  defp pulse(true), do: "animate-pulse"
  defp pulse(false), do: ""

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
