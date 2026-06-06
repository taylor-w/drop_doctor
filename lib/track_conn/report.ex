defmodule TrackConn.Report do
  @moduledoc """
  Turns the live diagnosis into something you can *hand to your ISP*: a
  timestamped verdict, the per-segment proof, the latest per-hop trace, and the
  recent history — exported as either a printable HTML document or a CSV of the
  raw timeline.

  ## Why two formats

    * **HTML** is for a human (a support rep). It leads with the plain-English
      verdict and the evidence behind it, and it's styled for the browser's
      "Save as PDF" so anyone can produce a clean PDF with no extra software —
      which keeps the app a single self-contained binary (no headless Chrome or
      `wkhtmltopdf` to bundle).

    * **CSV** is for a machine. It's the full sweep timeline — one row per
      measurement, with timestamps — so a technician can chart exactly when the
      connection broke and for how long.

  Both are built from the same snapshot so a saved PDF and a saved CSV always
  agree. The module is pure: it takes the data in (or pulls a default snapshot
  from the running system) and returns strings. That keeps it trivial to test
  and free of any web or rendering dependency.
  """

  alias TrackConn.{Measurements, Monitor, Net, Targets}

  @csv_columns ~w(
    timestamp_utc status culprit headline
    router_rtt_ms router_loss_pct
    internet_rtt_ms internet_loss_pct
    dns_ms web_ms
  )

  @default_limit 1000

  @doc """
  Assemble a report snapshot. With no options it reads the live system; every
  piece can be injected for testing.

  Options:

    * `:now` — generation timestamp (default `DateTime.utc_now/0`)
    * `:verdict` — the current verdict map (default `Monitor.latest/0`)
    * `:deep` — the latest deep trace report, or `nil` (default `Monitor.latest_deep/0`)
    * `:sweeps` — history rows newest-first (default `Measurements.recent/1`)
    * `:limit` — how many history rows to pull when `:sweeps` isn't given
  """
  def build(opts \\ []) do
    sweeps =
      Keyword.get_lazy(opts, :sweeps, fn ->
        Measurements.recent(Keyword.get(opts, :limit, @default_limit))
      end)

    %{
      generated_at: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0),
      verdict: Keyword.get_lazy(opts, :verdict, &Monitor.latest/0),
      deep: Keyword.get_lazy(opts, :deep, &safe_latest_deep/0),
      sweeps: sweeps,
      spike_events:
        Keyword.get_lazy(opts, :spike_events, fn ->
          Measurements.recent_spike_events(Keyword.get(opts, :limit, @default_limit))
        end),
      stats: stats(sweeps),
      targets: targets(),
      wsl?: Net.wsl?()
    }
  end

  defp safe_latest_deep do
    Monitor.latest_deep()
  rescue
    _ -> nil
  end

  @doc "A filename with the generation timestamp baked in, e.g. `track_conn-isp-report-2026-06-05_1300Z.csv`."
  def filename(format, %DateTime{} = at) when format in [:csv, :html, :spikes] do
    stamp =
      at
      |> DateTime.truncate(:second)
      |> Calendar.strftime("%Y-%m-%d_%H%MZ")

    case format do
      :html -> "track_conn-isp-report-#{stamp}.html"
      :csv -> "track_conn-isp-report-#{stamp}.csv"
      :spikes -> "track_conn-spike-log-#{stamp}.csv"
    end
  end

  # --- CSV ----------------------------------------------------------------

  @doc """
  The sweep timeline as CSV, oldest row first (natural reading order for a
  timeline). One row per recorded measurement.
  """
  def to_csv(%{sweeps: sweeps}) do
    rows =
      sweeps
      |> Enum.reverse()
      |> Enum.map(&csv_row/1)

    [Enum.join(@csv_columns, ",") | rows]
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp csv_row(s) do
    [
      iso8601(s.inserted_at),
      s.status,
      s.culprit,
      s.headline,
      s.router_rtt_ms,
      s.router_loss_pct,
      s.internet_rtt_ms,
      s.internet_loss_pct,
      s.dns_ms,
      s.web_ms
    ]
    |> Enum.map(&csv_field/1)
    |> Enum.join(",")
  end

  @spikes_csv_columns ~w(
    timestamp_utc segment host kind peak_ms baseline_ms loss_pct samples
  )

  @doc """
  The logged instability events as CSV, oldest first — the timestamped proof of
  intermittent spikes/loss that the smoothed sweep timeline averages away.
  """
  def spikes_csv(%{spike_events: events}) do
    rows =
      events
      |> Enum.reverse()
      |> Enum.map(&spike_csv_row/1)

    [Enum.join(@spikes_csv_columns, ",") | rows]
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp spike_csv_row(e) do
    [
      iso8601(e.occurred_at),
      e.segment,
      e.host,
      e.kind,
      e.peak_ms,
      e.baseline_ms,
      e.loss_pct,
      e.samples
    ]
    |> Enum.map(&csv_field/1)
    |> Enum.join(",")
  end

  defp csv_field(nil), do: ""
  defp csv_field(n) when is_number(n), do: to_string(n)

  defp csv_field(value) do
    str = to_string(value)

    if String.contains?(str, [",", "\"", "\n", "\r"]) do
      ~s("#{String.replace(str, "\"", "\"\"")}")
    else
      str
    end
  end

  # --- HTML ---------------------------------------------------------------

  @doc """
  A self-contained, print-ready HTML document. No external CSS/JS — it renders
  identically offline and prints cleanly to PDF.
  """
  def to_html(report) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>track_conn — ISP report (#{esc(iso8601(report.generated_at))})</title>
    <style>#{styles()}</style>
    </head>
    <body>
    #{toolbar()}
    <main>
    #{header_section(report)}
    #{verdict_section(report.verdict)}
    #{deep_section(report.deep)}
    #{stability_section(report.spike_events)}
    #{history_section(report.stats)}
    #{footer_section(report)}
    </main>
    <script>
      // Lets the "Save as PDF" button reach the browser's print dialog.
      function trackConnPrint(){ window.print(); }
    </script>
    </body>
    </html>
    """
  end

  defp toolbar do
    """
    <div class="toolbar no-print">
      <button onclick="trackConnPrint()">🖨️ Save as PDF / Print</button>
      <a href="/report.csv">⬇️ Download raw data (CSV)</a>
      <a href="/spikes.csv">⬇️ Spike log (CSV)</a>
      <span class="hint">Tip: in the print dialog choose “Save as PDF” as the destination.</span>
    </div>
    """
  end

  defp header_section(report) do
    """
    <header>
      <h1>📡 track_conn — Connection report</h1>
      <p class="subtitle">Is the problem your equipment, your DNS, or your ISP? This report is the timestamped proof.</p>
      <p class="generated">Generated <strong>#{esc(human_time(report.generated_at))}</strong> (UTC) · #{esc(span_line(report.stats))}</p>
    </header>
    """
  end

  defp verdict_section(verdict) do
    status = status_string(verdict[:status])
    culprit = culprit_label(verdict[:culprit])
    action = verdict[:action]

    """
    <section class="verdict #{esc(status)}">
      <h2>Verdict</h2>
      <div class="badge-row">
        <span class="status-pill #{esc(status)}">#{esc(status_word(status))}</span>
        <span class="culprit">Likely cause: <strong>#{esc(culprit)}</strong></span>
      </div>
      <p class="headline">#{esc(verdict[:headline])}</p>
      #{maybe_p("detail", verdict[:detail])}
      #{if action, do: ~s(<p class="action"><strong>What to do:</strong> #{esc(action)}</p>), else: ""}
      #{segments_table(verdict[:segments])}
    </section>
    """
  end

  defp segments_table(segments) when is_list(segments) and segments != [] do
    rows =
      Enum.map_join(segments, "", fn seg ->
        """
        <tr class="#{esc(state_string(seg[:state]))}">
          <td>#{esc(state_symbol(seg[:state]))}</td>
          <td><strong>#{esc(seg[:label])}</strong><br><span class="muted">#{esc(seg[:about])}</span></td>
          <td class="mono">#{esc(seg[:target])}</td>
          <td class="mono">#{esc(seg[:summary])}</td>
          <td>#{esc(String.upcase(state_string(seg[:state])))}</td>
        </tr>
        """
      end)

    """
    <h3>The path from you to the internet — segment by segment</h3>
    <table class="ladder">
      <thead><tr><th></th><th>Segment</th><th>Target</th><th>Measurement (the proof)</th><th>State</th></tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    """
  end

  defp segments_table(_),
    do: ~s(<p class="muted">No measurements yet — start monitoring before exporting.</p>)

  defp deep_section(nil) do
    """
    <section class="deep">
      <h2>Per-hop trace</h2>
      <p class="muted">No deep diagnostic has been run in this session. Open the dashboard and click
      “Run deep diagnostic” to add a hop-by-hop trace (it names your ISP's routers) to this report.</p>
    </section>
    """
  end

  defp deep_section(%{ok?: false} = deep) do
    """
    <section class="deep">
      <h2>Per-hop trace</h2>
      <p class="headline">#{esc(deep[:headline])}</p>
      #{maybe_pre(deep[:detail])}
    </section>
    """
  end

  defp deep_section(%{ok?: true} = deep) do
    rows =
      Enum.map_join(deep.hops, "", fn hop ->
        note =
          if hop[:note],
            do: ~s(<tr class="note"><td></td><td colspan="4">↳ #{esc(hop[:note])}</td></tr>),
            else: ""

        """
        <tr class="#{esc(hop_class(hop))}">
          <td class="mono">#{esc(hop[:count])}</td>
          <td class="mono">#{esc(display_host(hop))}</td>
          <td>#{esc(zone_label(hop[:zone]))}</td>
          <td class="mono num">#{esc(fmt_pct(hop[:loss_pct], hop))}</td>
          <td class="mono num">#{esc(fmt_ms(hop[:avg]))}</td>
        </tr>
        #{note}
        """
      end)

    """
    <section class="deep">
      <h2>Per-hop trace to #{esc(deep[:target])}</h2>
      <p class="headline #{esc(status_string(deep[:status]))}">#{esc(deep[:headline])}</p>
      #{maybe_p("detail", deep[:detail])}
      <table class="hops">
        <thead><tr><th>#</th><th>Host</th><th>Zone</th><th>Loss</th><th>Avg</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
      <p class="muted small">Loss only counts when it persists to the destination — a single hop showing loss while
      later hops are clean is just a router ignoring traceroute, not a real fault.</p>
    </section>
    """
  end

  defp deep_section(_), do: ""

  defp stability_section([]) do
    """
    <section class="stability">
      <h2>Connection stability — logged spikes</h2>
      <p class="muted">No brief spikes or loss were caught by continuous sampling in this window —
      the connection held steady between checks.</p>
    </section>
    """
  end

  defp stability_section(events) when is_list(events) do
    rows =
      events
      |> Enum.take(50)
      |> Enum.map_join("", fn e ->
        """
        <tr class="#{esc(spike_class(e.kind))}">
          <td class="mono">#{esc(human_time(e.occurred_at))}</td>
          <td>#{esc(segment_label(e.segment))}</td>
          <td>#{esc(spike_detail(e))}</td>
        </tr>
        """
      end)

    """
    <section class="stability">
      <h2>Connection stability — logged spikes</h2>
      <p>#{length(events)} brief spike/loss event(s) caught by continuous sampling (~5×/sec) —
      the intermittent stutters that never show up in an "average" but ruin a call or game.</p>
      <table class="spikes">
        <thead><tr><th>When (UTC)</th><th>Where</th><th>What happened</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
      #{if length(events) > 50, do: ~s(<p class="muted small">Showing the 50 most recent — the full list is in the spike-log CSV.</p>), else: ~s(<p class="muted small">Full list with exact values is in the spike-log CSV export.</p>)}
    </section>
    """
  end

  defp stability_section(_), do: ""

  defp segment_label("router"), do: "Your router / local network"
  defp segment_label("internet"), do: "The open internet (via your ISP)"
  defp segment_label(other), do: to_string(other)

  defp spike_class("loss"), do: "loss-onset"
  defp spike_class(_), do: "latency-jump"

  defp spike_detail(%{kind: "latency", peak_ms: peak, baseline_ms: base}),
    do: "Latency spiked to #{fmt_ms(peak)} (normal ~#{fmt_ms(base)})"

  defp spike_detail(%{kind: "loss", loss_pct: pct}),
    do: "#{fmt_num(pct)}% packet loss in a ~2s burst"

  defp spike_detail(_), do: "—"

  defp history_section(stats) do
    """
    <section class="history">
      <h2>Recent history</h2>
      <table class="summary">
        <tbody>
          <tr><td>Measurements in this report</td><td class="mono num">#{stats.total}</td></tr>
          <tr><td>Healthy</td><td class="mono num">#{stats.healthy}</td></tr>
          <tr><td>Degraded</td><td class="mono num">#{stats.degraded}</td></tr>
          <tr><td>Down</td><td class="mono num">#{stats.down}</td></tr>
          <tr><td>Uptime (not down)</td><td class="mono num">#{stats.uptime}%</td></tr>
          <tr><td>Window covered</td><td>#{esc(span_line(stats))}</td></tr>
        </tbody>
      </table>
      <p class="muted small">The full measurement-by-measurement timeline (with timestamps) is in the CSV export.</p>
    </section>
    """
  end

  defp footer_section(report) do
    wsl_note =
      if report.wsl?,
        do:
          ~s(<p class="small muted">Note: running under WSL — the “router” hop may be the Windows host rather than the physical gateway.</p>),
        else: ""

    targets =
      Enum.map_join(report.targets, "", fn {label, target} ->
        ~s(<li><strong>#{esc(label)}:</strong> <span class="mono">#{esc(target)}</span></li>)
      end)

    """
    <footer>
      <h3>What was measured</h3>
      <ul class="targets">#{targets}</ul>
      #{wsl_note}
      <p class="small muted">Generated by track_conn — an open-source connection diagnostic. Times are UTC.</p>
    </footer>
    """
  end

  # --- snapshot helpers ---------------------------------------------------

  defp targets do
    [
      {"Your router / local network", Targets.router_target()},
      {"Open internet (raw IP, no DNS)", Targets.internet_target()},
      {"DNS name lookup", Targets.dns_target()},
      {"Real website", Targets.web_target()}
    ]
  end

  @doc false
  def stats(sweeps) do
    total = length(sweeps)
    healthy = Enum.count(sweeps, &(&1.status == "healthy"))
    degraded = Enum.count(sweeps, &(&1.status == "degraded"))
    down = Enum.count(sweeps, &(&1.status == "down"))
    up = total - down

    {first, last} = span(sweeps)

    %{
      total: total,
      healthy: healthy,
      degraded: degraded,
      down: down,
      uptime: if(total > 0, do: round(up / total * 100), else: 100),
      first: first,
      last: last
    }
  end

  # sweeps are newest-first; the window runs from the oldest to the newest row.
  defp span([]), do: {nil, nil}
  defp span(sweeps), do: {List.last(sweeps).inserted_at, List.first(sweeps).inserted_at}

  defp span_line(%{first: nil}), do: "no measurements recorded yet"

  defp span_line(%{first: first, last: last}) do
    "#{total_window(first, last)} of monitoring, #{human_time(first)} → #{human_time(last)} UTC"
  end

  defp total_window(first, last) do
    seconds = DateTime.diff(last, first, :second)

    cond do
      seconds >= 3600 -> "#{Float.round(seconds / 3600, 1)} h"
      seconds >= 60 -> "#{round(seconds / 60)} min"
      true -> "#{seconds} s"
    end
  end

  # --- formatting ---------------------------------------------------------

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp iso8601(other), do: to_string(other)

  defp human_time(%DateTime{} = dt) do
    dt |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  defp human_time(other), do: to_string(other)

  defp maybe_p(_class, nil), do: ""
  defp maybe_p(class, text), do: ~s(<p class="#{class}">#{esc(text)}</p>)

  defp maybe_pre(nil), do: ""
  defp maybe_pre(text), do: ~s(<pre>#{esc(text)}</pre>)

  defp display_host(%{host: h}) when h in ["???", nil], do: "(no response)"
  defp display_host(%{host: h}), do: h

  defp fmt_pct(loss, %{phantom_loss?: true}), do: "#{fmt_num(loss)}% (phantom)"
  defp fmt_pct(loss, _), do: "#{fmt_num(loss)}%"

  defp fmt_ms(nil), do: "—"
  defp fmt_ms(n) when is_number(n), do: "#{Float.round(n / 1, 1)}ms"
  defp fmt_ms(_), do: "—"

  defp fmt_num(n) when is_float(n), do: Float.round(n, 1)
  defp fmt_num(n) when is_number(n), do: n
  defp fmt_num(_), do: "—"

  defp hop_class(%{loss_onset?: true}), do: "loss-onset"
  defp hop_class(%{latency_jump?: true}), do: "latency-jump"
  defp hop_class(%{phantom_loss?: true}), do: "phantom"
  defp hop_class(_), do: ""

  # --- label/symbol tables (text only — this is a standalone document) ----

  defp status_string(s) when is_atom(s), do: Atom.to_string(s)
  defp status_string(s) when is_binary(s), do: s
  defp status_string(_), do: "unknown"

  defp state_string(s), do: status_string(s)

  defp status_word("healthy"), do: "HEALTHY"
  defp status_word("degraded"), do: "DEGRADED"
  defp status_word("down"), do: "DOWN"
  defp status_word(_), do: "UNKNOWN"

  defp state_symbol(s) do
    case state_string(s) do
      "healthy" -> "✓"
      "degraded" -> "▲"
      "down" -> "✕"
      _ -> "•"
    end
  end

  defp culprit_label(c) do
    case to_string(c || "none") do
      "none" -> "Nothing — all healthy"
      "local" -> "Your local network / router"
      "isp" -> "Your ISP"
      "dns" -> "DNS configuration"
      "web" -> "Bandwidth / destination site"
      other -> other
    end
  end

  defp zone_label(zone) do
    case to_string(zone || "") do
      "local" -> "Your network"
      "isp_edge" -> "ISP edge"
      "isp" -> "Your ISP"
      "transit" -> "Transit / CDN"
      "destination" -> "Destination"
      _ -> "—"
    end
  end

  # --- HTML escaping ------------------------------------------------------

  # Self-contained so this module has no web dependency. Covers the five
  # characters that matter for HTML text and double-quoted attributes.
  defp esc(nil), do: ""

  defp esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  # --- print-friendly stylesheet ------------------------------------------

  defp styles do
    """
    /* Screen: dark, to match the dashboard. Print: forced clean/light below so
       the PDF a user hands their ISP stays professional and ink-friendly. */
    :root {
      color-scheme: dark;
      --bg: oklch(25.26% 0.014 253.1);
      --card: oklch(30.33% 0.016 252.42);
      --line: oklch(40% 0.012 254);
      --ink: oklch(97.8% 0.029 256.8);
      --muted: oklch(72% 0.02 256);
      --primary: oklch(62% 0.2 277);
      --ok: oklch(72% 0.13 184);
      --warn: oklch(77% 0.16 70);
      --bad: oklch(67% 0.21 20);
      --radius: 0.75rem;
    }
    * { box-sizing: border-box; }
    body { font-family: "Segoe UI", system-ui, -apple-system, Roboto, sans-serif; color: var(--ink);
           margin: 0; padding: 0 1.25rem 4rem; line-height: 1.55;
           background: radial-gradient(ellipse 70% 40% at 50% -5%, color-mix(in oklab, var(--primary) 22%, transparent), transparent 70%), var(--bg);
           background-attachment: fixed; min-height: 100vh; }
    main { max-width: 54rem; margin: 0 auto; }
    h1 { font-size: 1.9rem; margin: 0 0 .25rem; letter-spacing: -.02em; }
    h2 { font-size: 1.15rem; margin: 0 0 .75rem; letter-spacing: -.01em; padding-bottom: .5rem; border-bottom: 1px solid var(--line); }
    h3 { font-size: 1rem; margin: 1.1rem 0 .4rem; }
    p { margin: .45rem 0; }
    a { color: color-mix(in oklab, var(--primary) 75%, white); }
    .subtitle { color: var(--muted); margin-top: 0; font-size: 1.02rem; }
    .generated { color: var(--muted); font-size: .9rem; }
    header { padding: 1.75rem 0 .25rem; }
    section, footer { background: linear-gradient(180deg, color-mix(in oklab, white 5%, transparent), transparent 55%), var(--card);
           border: 1px solid var(--line); border-radius: var(--radius); padding: 1.25rem 1.4rem; margin: 1rem 0;
           box-shadow: inset 0 1px 0 0 color-mix(in oklab, white 9%, transparent), 0 12px 32px -22px rgb(0 0 0 / .6); }
    .headline { font-size: 1.18rem; font-weight: 700; }
    .verdict.healthy .headline { color: var(--ok); }
    .verdict.degraded .headline { color: var(--warn); }
    .verdict.down .headline { color: var(--bad); }
    .headline.healthy { color: var(--ok); } .headline.degraded { color: var(--warn); } .headline.down { color: var(--bad); }
    .action { background: color-mix(in oklab, var(--warn) 16%, var(--card)); border: 1px solid color-mix(in oklab, var(--warn) 45%, transparent);
           padding: .6rem .85rem; border-radius: .5rem; }
    .badge-row { display: flex; gap: .75rem; align-items: center; flex-wrap: wrap; margin: .25rem 0 .75rem; }
    .status-pill { font-weight: 800; letter-spacing: .06em; padding: .25rem .8rem; border-radius: 1rem; color: #fff; font-size: .8rem; }
    .status-pill.healthy { background: var(--ok); color: #04201a; }
    .status-pill.degraded { background: var(--warn); color: #241400; }
    .status-pill.down { background: var(--bad); }
    .status-pill.unknown { background: #888; }
    /* Status cue = a colored wash down from the top edge, not a left accent bar. */
    section.verdict.healthy { background: linear-gradient(180deg, color-mix(in oklab, var(--ok) 14%, transparent), transparent 46%), var(--card); }
    section.verdict.degraded { background: linear-gradient(180deg, color-mix(in oklab, var(--warn) 14%, transparent), transparent 46%), var(--card); }
    section.verdict.down { background: linear-gradient(180deg, color-mix(in oklab, var(--bad) 16%, transparent), transparent 46%), var(--card); }
    .culprit { color: var(--muted); }
    table { width: 100%; border-collapse: collapse; margin: .6rem 0; font-size: .9rem; }
    th, td { text-align: left; padding: .5rem .55rem; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { font-size: .72rem; text-transform: uppercase; letter-spacing: .05em; color: var(--muted); }
    tbody tr:hover { background: color-mix(in oklab, var(--primary) 9%, transparent); }
    td.num { text-align: right; }
    .mono { font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .85em; font-variant-numeric: tabular-nums; }
    .muted { color: var(--muted); }
    .small { font-size: .82rem; }
    tr.healthy td:first-child { color: var(--ok); font-weight: 800; }
    tr.degraded td:first-child { color: var(--warn); font-weight: 800; }
    tr.down td:first-child { color: var(--bad); font-weight: 800; }
    tr.loss-onset { background: color-mix(in oklab, var(--bad) 16%, transparent); }
    tr.latency-jump { background: color-mix(in oklab, var(--warn) 13%, transparent); }
    tr.phantom { color: var(--muted); }
    tr.note td { border-bottom: none; color: var(--muted); font-size: .82rem; padding-top: 0; }
    pre { background: rgba(0,0,0,.25); padding: .7rem; border-radius: .5rem; overflow-x: auto; font-size: .82rem; white-space: pre-wrap; border: 1px solid var(--line); }
    ul.targets { margin: .25rem 0; padding-left: 1.1rem; }
    footer h3 { margin-top: 0; }
    .toolbar { position: sticky; top: 0; z-index: 5; background: color-mix(in oklab, var(--bg) 82%, transparent);
               -webkit-backdrop-filter: blur(8px); backdrop-filter: blur(8px); border-bottom: 1px solid var(--line);
               margin: 0 -1.25rem 1.5rem; padding: .7rem 1.25rem; display: flex; gap: .6rem; align-items: center; flex-wrap: wrap; }
    .toolbar button, .toolbar a { font: inherit; font-size: .9rem; padding: .4rem .9rem; border-radius: .5rem;
               border: 1px solid var(--line); background: var(--card); color: var(--ink); cursor: pointer; text-decoration: none; }
    .toolbar button { background: var(--primary); color: #fff; border-color: var(--primary); font-weight: 600; }
    .toolbar .hint { color: var(--muted); font-size: .82rem; }
    @media print {
      :root { color-scheme: light; --bg:#fff; --card:#fff; --line:#ddd; --ink:#1a1a1a; --muted:#666;
              --primary:#2563eb; --ok:#15803d; --warn:#b45309; --bad:#b91c1c; }
      .no-print { display: none !important; }
      body { padding: 0; background: #fff; }
      header { padding: 0 0 .25rem; }
      section, footer { border: none; border-radius: 0; padding: 0; margin: 1.25rem 0; background: #fff; box-shadow: none; page-break-inside: avoid; }
      section.verdict.healthy, section.verdict.degraded, section.verdict.down { background: #fff; }
      h2 { border-bottom: 2px solid var(--line); page-break-after: avoid; }
      .status-pill.healthy, .status-pill.degraded { color: #fff; }
      tbody tr:hover { background: none; }
      pre { background: #f5f5f5; border-color: #e5e5e5; }
    }
    """
  end
end
