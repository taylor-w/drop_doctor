defmodule DropDoctor.Report do
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

  alias DropDoctor.{Format, Measurements, Monitor, Net, SpikeAnalysis, Targets}

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
        opts
        |> Keyword.get_lazy(:spike_events, fn ->
          Measurements.recent_spike_events(Keyword.get(opts, :limit, @default_limit))
        end)
        |> SpikeAnalysis.annotate(),
      speed_tests:
        Keyword.get_lazy(opts, :speed_tests, fn ->
          Measurements.recent_speed_tests(Keyword.get(opts, :limit, @default_limit))
        end),
      stats: stats(sweeps),
      targets: targets(),
      wsl?: Net.wsl?(),
      wsl_unresolved?: Net.wsl_router_unresolved?()
    }
  end

  defp safe_latest_deep do
    Monitor.latest_deep()
  rescue
    _ -> nil
  end

  @doc "A filename with the generation timestamp baked in, e.g. `drop_doctor-isp-report-2026-06-05_1300Z.csv`."
  def filename(format, %DateTime{} = at) when format in [:csv, :html, :spikes, :speeds] do
    stamp =
      at
      |> DateTime.truncate(:second)
      |> Calendar.strftime("%Y-%m-%d_%H%MZ")

    case format do
      :html -> "drop_doctor-isp-report-#{stamp}.html"
      :csv -> "drop_doctor-isp-report-#{stamp}.csv"
      :spikes -> "drop_doctor-spike-log-#{stamp}.csv"
      :speeds -> "drop_doctor-speed-tests-#{stamp}.csv"
    end
  end

  # --- CSV ----------------------------------------------------------------

  @doc """
  The sweep timeline as CSV, oldest row first (natural reading order for a
  timeline). One row per recorded measurement.
  """
  def to_csv(%{sweeps: sweeps}) do
    sweeps
    |> Enum.reverse()
    |> Enum.map(&csv_row/1)
    |> build_csv(@csv_columns)
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
    timestamp_utc segment host kind peak_ms baseline_ms loss_pct samples source co_occurring corroborated
  )

  @doc """
  The logged instability events as CSV, oldest first — the timestamped proof of
  intermittent spikes/loss that the smoothed sweep timeline averages away.
  """
  def spikes_csv(%{spike_events: events}) do
    events
    |> Enum.reverse()
    |> Enum.map(&spike_csv_row/1)
    |> build_csv(@spikes_csv_columns)
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
      e.samples,
      Map.get(e, :source),
      Map.get(e, :co_occurring?),
      Map.get(e, :corroborated)
    ]
    |> Enum.map(&csv_field/1)
    |> Enum.join(",")
  end

  @speeds_csv_columns ~w(
    timestamp_utc download_mbps upload_mbps latency_ms jitter_ms server ok error
  )

  @doc """
  The recorded speed tests as CSV, oldest first — the timestamped record of the
  download/upload throughput actually delivered, to set against the tier sold.
  """
  def speeds_csv(%{speed_tests: tests}) do
    tests
    |> Enum.reverse()
    |> Enum.map(&speed_csv_row/1)
    |> build_csv(@speeds_csv_columns)
  end

  # Assemble a CSV body shared by every export: the header row, then the data
  # rows, CRLF-terminated with a trailing newline so Excel opens it cleanly. One
  # definition so a change to framing/quoting can't be applied to two of three.
  defp build_csv(rows, columns) do
    [Enum.join(columns, ",") | rows]
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
  end

  defp speed_csv_row(t) do
    [
      iso8601(t.measured_at),
      t.download_mbps,
      t.upload_mbps,
      t.latency_ms,
      t.jitter_ms,
      t.server,
      t.ok,
      t.error
    ]
    |> Enum.map(&csv_field/1)
    |> Enum.join(",")
  end

  defp csv_field(nil), do: ""
  defp csv_field(n) when is_number(n), do: to_string(n)

  defp csv_field(value) do
    str = value |> to_string() |> neutralize_formula()

    if String.contains?(str, [",", "\"", "\n", "\r"]) do
      ~s("#{String.replace(str, "\"", "\"\"")}")
    else
      str
    end
  end

  # CSV formula injection: this report is meant to be handed to an ISP and opened
  # in Excel/Sheets, where a cell beginning with = + - @ (or tab/CR) is run as a
  # formula (DDE / data-exfil). Prefix such a *text* field with a single quote so
  # the spreadsheet treats it as literal text. Numbers use the is_number clause
  # above and are never neutralized.
  defp neutralize_formula(<<c, _::binary>> = str) when c in [?=, ?+, ?-, ?@, ?\t, ?\r],
    do: "'" <> str

  defp neutralize_formula(str), do: str

  # --- HTML ---------------------------------------------------------------

  @doc """
  A self-contained, print-ready HTML document. No external CSS/JS — it renders
  identically offline and prints cleanly to PDF.

  When served by the running app the document also wires itself to a live feed
  (`live_update_script/0` → the `/report/live` SSE endpoint) so an open tab shows
  new sweeps, spikes and speed tests without a manual refresh. That wiring is
  inert offline: a saved copy opened from disk (`file://`) never connects and
  stays the frozen snapshot it was when saved.
  """
  def to_html(report) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="DropDoctor connection report — timestamped proof of internet drops, latency spikes and jitter, with where the fault lies, ready to share with your ISP.">
    <title>DropDoctor — ISP report (#{esc(iso8601(report.generated_at))})</title>
    <script>#{theme_script()}</script>
    <style>#{styles()}</style>
    <script>#{view_controls_script()}</script>
    </head>
    <body>
    #{toolbar()}
    <main>
    #{render_slots(live_sections(report))}
    #{footer_section(report)}
    </main>
    <script>
      // Lets the "Save as PDF" button reach the browser's print dialog.
      function dropDoctorPrint(){ window.print(); }
    </script>
    <script>#{live_update_script()}</script>
    </body>
    </html>
    """
  end

  @doc """
  The report's dynamic sections keyed by their DOM id — the exact fragments the
  live endpoint streams so an open `/report` tab can update in place. Built from
  the same `live_sections/1` the printed page renders, so a connected client and
  a fresh page load can never disagree, and there's no second renderer to keep
  in step.
  """
  def live_payload(report), do: Map.new(live_sections(report))

  # The dynamic body of the report as an ordered list of `{dom_id, html}` slots.
  # `to_html/1` renders these into the page (each wrapped in a stable element the
  # live feed can target); `live_payload/1` ships the same map over SSE. Defined
  # once so the page and the live feed always render byte-identical sections.
  defp live_sections(report) do
    [
      {"dd-header", header_section(report)},
      {"dd-verdict", verdict_section(report.verdict)},
      {"dd-speed", speed_section(report.speed_tests)},
      {"dd-deep", deep_section(report.deep)},
      {"dd-stability", stability_section(report.spike_events)},
      {"dd-history", history_section(report.stats)}
    ]
  end

  # Each slot gets a stable id the live script swaps by `innerHTML`. The wrapper
  # is `display:contents` (see styles/0), so it adds no box of its own and the
  # page lays out exactly as if the sections were inline here.
  defp render_slots(sections) do
    Enum.map_join(sections, "\n", fn {id, html} ->
      ~s(<div id="#{id}" class="dd-slot">#{html}</div>)
    end)
  end

  # Subscribes the open report to the live feed and swaps in changed sections as
  # they arrive. Deliberately defensive and self-contained:
  #
  #   * Only connects over http(s) — a report saved to disk and opened from
  #     `file://` stays a static snapshot (the whole point of the export).
  #   * Sets `innerHTML` only when a section actually changed, so the page
  #     doesn't churn (and a stream-safe "hover to peek" isn't interrupted)
  #     every heartbeat.
  #   * After a swap, dispatches `dd:updated` so the timezone/privacy script
  #     re-formats the freshly-inserted timestamps (privacy blur/redaction is
  #     pure CSS, so swapped nodes inherit it with no JS).
  #   * EventSource reconnects on its own; we just reflect the state in a small
  #     no-print "Live" indicator.
  defp live_update_script do
    """
    (() => {
      if (location.protocol !== "http:" && location.protocol !== "https:") return;
      if (!("EventSource" in window)) return;

      const badge = document.getElementById("dd-live-status");
      const setState = (s) => { if (badge) badge.setAttribute("data-state", s); };

      // Stream the same window the page was rendered with.
      const params = new URLSearchParams(location.search);
      const qs = params.has("limit") ? "?limit=" + encodeURIComponent(params.get("limit")) : "";

      let es;
      const connect = () => {
        es = new EventSource("#{live_path()}" + qs);
        es.onopen = () => setState("live");
        es.onerror = () => setState("reconnecting"); // EventSource retries by itself
        es.onmessage = (e) => {
          let slots;
          try { slots = JSON.parse(e.data); } catch (_) { return; }
          let changed = false;
          for (const id in slots) {
            const el = document.getElementById(id);
            if (el && el.innerHTML !== slots[id]) { el.innerHTML = slots[id]; changed = true; }
          }
          if (changed) document.dispatchEvent(new Event("dd:updated"));
        };
      };
      connect();

      window.addEventListener("pagehide", () => { if (es) es.close(); });
    })();
    """
  end

  @doc "Path of the live (Server-Sent Events) report feed."
  def live_path, do: "/report/live"

  # Per-colorway --primary overrides for the report, mirrored from the dashboard's
  # palettes (DropDoctor.Themes) so the two stay in step. The light/dark neutral
  # groups carry bg/ink/lines; only the accent changes per colorway, per mode.
  defp colorway_theme_css do
    DropDoctor.Themes.colorways()
    |> Enum.map_join("\n", fn cw ->
      ~s(      :root[data-theme="#{cw.name}-light"] { --primary: #{cw.primary_light}; }\n) <>
        ~s(      :root[data-theme="#{cw.name}-dark"] { --primary: #{cw.primary_dark}; })
    end)
  end

  # Match the dashboard's selected theme. The app stores two keys:
  # localStorage["phx:theme"] (mode: light | dark | absent = system) and
  # localStorage["tc:colorway"] (palette | absent = default). We resolve the same
  # combined data-theme the dashboard does (e.g. "winter-dark"); the stylesheet
  # below tints itself to match. Runs in <head> before paint, so there's no
  # flash, and follows the app live (OS flips, and edits in the dashboard tab).
  # Print always forces a clean light palette via @media print regardless.
  defp theme_script do
    """
    (() => {
      try {
        const root = document.documentElement;
        const mq = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)");
        const mode = () => {
          const m = localStorage.getItem("phx:theme");
          return (m === "light" || m === "dark") ? m : (mq && mq.matches ? "dark" : "light");
        };
        const apply = () => {
          const cw = localStorage.getItem("tc:colorway") || "default";
          root.setAttribute("data-theme", cw === "default" ? mode() : cw + "-" + mode());
        };
        apply();
        if (mq) mq.addEventListener("change", () => {
          if (!["light", "dark"].includes(localStorage.getItem("phx:theme"))) apply();
        });
        window.addEventListener("storage", (e) => {
          if (e.key === "phx:theme" || e.key === "tc:colorway") apply();
        });
      } catch (_) { document.documentElement.setAttribute("data-theme", "dark"); }
    })();
    """
  end

  # Stream-safe privacy + timezone, mirroring the dashboard. Self-contained.
  defp view_controls_script do
    """
    (() => {
      const root = document.documentElement;
      root.setAttribute("data-privacy", localStorage.getItem("tc:privacy") || "off");
      root.setAttribute("data-tz", localStorage.getItem("tc:tz") || "utc"); // report default: UTC
      const pad = (n) => String(n).padStart(2, "0");
      const fmt = (d, style, utc) => {
        const Y = utc ? d.getUTCFullYear() : d.getFullYear();
        const Mo = pad((utc ? d.getUTCMonth() : d.getMonth()) + 1);
        const Da = pad(utc ? d.getUTCDate() : d.getDate());
        const H = pad(utc ? d.getUTCHours() : d.getHours());
        const Mi = pad(utc ? d.getUTCMinutes() : d.getMinutes());
        const S = pad(utc ? d.getUTCSeconds() : d.getSeconds());
        if (style === "time") return H + ":" + Mi + ":" + S;
        if (style === "date") return Y + "-" + Mo + "-" + Da;
        return Y + "-" + Mo + "-" + Da + " " + H + ":" + Mi + ":" + S;
      };
      const zone = (utc) => utc ? "UTC" : (Intl.DateTimeFormat().resolvedOptions().timeZone || "local");
      const apply = () => {
        const utc = (root.getAttribute("data-tz") || "utc") === "utc";
        document.querySelectorAll("[data-utc]").forEach((el) => {
          const iso = el.getAttribute("data-utc"); if (!iso) return;
          const d = new Date(iso); if (isNaN(d.getTime())) return;
          const t = fmt(d, el.getAttribute("data-utc-style") || "datetime", utc);
          if (el.textContent !== t) el.textContent = t;
        });
        document.querySelectorAll("[data-tz-zone]").forEach((el) => {
          const t = zone(utc); if (el.textContent !== t) el.textContent = t;
        });
      };
      document.addEventListener("click", (e) => {
        const p = e.target.closest("[data-privacy-set]");
        if (p) { const m = p.getAttribute("data-privacy-set"); root.setAttribute("data-privacy", m); try { localStorage.setItem("tc:privacy", m); } catch (_) {} return; }
        const t = e.target.closest("[data-tz-toggle]");
        if (t) { const m = (root.getAttribute("data-tz") || "utc") === "utc" ? "local" : "utc"; root.setAttribute("data-tz", m); try { localStorage.setItem("tc:tz", m); } catch (_) {} apply(); }
      });
      if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", apply); else apply();
      // Re-format timestamps after the live feed swaps in fresh sections.
      document.addEventListener("dd:updated", apply);
    })();
    """
  end

  defp toolbar do
    """
    <div class="toolbar no-print">
      <button onclick="dropDoctorPrint()">#{ico("printer")} Save as PDF / Print</button>
      <a href="/report.csv">#{ico("download")} Download raw data (CSV)</a>
      <a href="/spikes.csv">#{ico("zap")} Spike log (CSV)</a>
      <a href="/speeds.csv">#{ico("gauge")} Speed tests (CSV)</a>
      <span class="hint">Tip: in the print dialog choose “Save as PDF” as the destination.</span>
      <span id="dd-live-status" class="dd-live no-print" data-state="connecting" aria-live="polite" title="This report updates live as new measurements arrive — no need to refresh.">
        <span class="dd-live-dot" aria-hidden="true"></span><span class="dd-live-text"></span>
      </span>
      <div class="tc-controls">
        <span class="tc-seg" role="group" aria-label="Stream-safe privacy" title="Stream-safe: hide IPs, hostnames & times so you can screen-share. Blur = hover to peek; lock = redact.">
          <button type="button" data-privacy-set="off" title="Show all values">#{ico("eye")}</button>
          <button type="button" data-privacy-set="blur" title="Stream-safe: blur IPs, hostnames & times (hover to peek)">#{ico("eye-off")}</button>
          <button type="button" data-privacy-set="strict" title="Strict: redact IPs, hostnames & times (no peek)">#{ico("lock")}</button>
        </span>
        <button type="button" class="tc-seg-btn" data-tz-toggle title="Switch displayed times between UTC and your local time">#{ico("clock")} <span class="tc-tz-local">Local</span><span class="tc-tz-utc">UTC</span></button>
      </div>
    </div>
    """
  end

  # The dashboard's satellite-dish lucide icon (lucide.dev, ISC), inlined so the
  # report stays a single self-contained document.
  defp logo_svg do
    ~s(<svg class="logo" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 10a7.31 7.31 0 0 0 10 10Z"/><path d="m9 15 3-3"/><path d="M17 13a6 6 0 0 0-6-6"/><path d="M21 13A10 10 0 0 0 11 3"/></svg>)
  end

  # Inline lucide icons for the toolbar (lucide.dev, ISC), matching the dashboard.
  defp ico(name) do
    ~s(<svg class="ico" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">#{ico_path(name)}</svg>)
  end

  defp ico_path("printer"),
    do:
      ~S(<path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"/><path d="M6 9V3a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v6"/><rect x="6" y="14" width="12" height="8" rx="1"/>)

  defp ico_path("download"),
    do:
      ~S(<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/>)

  defp ico_path("zap"),
    do:
      ~S(<path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>)

  defp ico_path("eye"),
    do:
      ~S(<path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"/><circle cx="12" cy="12" r="3"/>)

  defp ico_path("eye-off"),
    do:
      ~S(<path d="M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49"/><path d="M14.084 14.158a3 3 0 0 1-4.242-4.242"/><path d="M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143"/><path d="m2 2 20 20"/>)

  defp ico_path("lock"),
    do:
      ~S(<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>)

  defp ico_path("clock"),
    do: ~S(<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>)

  defp ico_path("gauge"),
    do: ~S(<path d="m12 14 4-4"/><path d="M3.34 19a10 10 0 1 1 17.32 0"/>)

  # ISO-8601 UTC for the client-side timezone toggle (NaiveDateTime assumed UTC).
  defp iso_utc(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso_utc(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt) <> "Z"
  defp iso_utc(other), do: to_string(other)

  # A timestamp the JS can re-render in local/UTC; tc-secret so stream-safe hides it.
  defp time_el(dt, style \\ "datetime") do
    ~s(<span class="tc-secret" data-utc="#{esc(iso_utc(dt))}" data-utc-style="#{style}">#{esc(human_time(dt))}</span>)
  end

  defp secret(html), do: ~s(<span class="tc-secret">#{html}</span>)

  defp header_section(report) do
    """
    <header>
      <h1>#{logo_svg()} DropDoctor — Connection report</h1>
      <p class="subtitle">Is the problem your equipment, your DNS, or your ISP? This report is the timestamped proof.</p>
      <p class="generated">Generated <strong>#{time_el(report.generated_at)}</strong> (<span class="tc-secret" data-tz-zone>UTC</span>) · #{span_line(report.stats)}</p>
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
          <td class="mono">#{if seg[:key] == :router, do: secret(esc(seg[:target])), else: esc(seg[:target])}</td>
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
          <td class="mono">#{secret(esc(display_host(hop)))}</td>
          <td>#{zone_badge(hop[:zone])}</td>
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

  defp speed_section([]) do
    """
    <section class="speed">
      <h2>Speed test</h2>
      <p class="muted">No download/upload speed test has been run in this session. Open the dashboard
      and click “Test speed” to add a measured-throughput snapshot to this report.</p>
    </section>
    """
  end

  defp speed_section(tests) when is_list(tests) and tests != [] do
    latest = List.first(tests)

    rows =
      tests
      |> Enum.take(20)
      |> Enum.map_join("", fn t ->
        """
        <tr class="#{if t.ok, do: "", else: "down"}">
          <td class="mono">#{time_el(t.measured_at)}</td>
          <td class="mono num">#{esc(fmt_mbps(t.download_mbps))}</td>
          <td class="mono num">#{esc(fmt_mbps(t.upload_mbps))}</td>
          <td class="mono num">#{esc(fmt_ms(t.latency_ms))}</td>
          <td class="mono num">#{esc(fmt_ms(t.jitter_ms))}</td>
          <td class="mono">#{esc(t.server)}</td>
        </tr>
        """
      end)

    """
    <section class="speed">
      <h2>Speed test — delivered throughput</h2>
      <p class="headline">Latest: <strong>#{esc(fmt_mbps(latest.download_mbps))} Mbps</strong> down ·
      <strong>#{esc(fmt_mbps(latest.upload_mbps))} Mbps</strong> up
      <span class="muted">(#{time_el(latest.measured_at)} <span class="tc-secret" data-tz-zone>UTC</span>)</span></p>
      <p class="muted small">Measured with parallel connections against #{esc(latest.server)} — the same
      method speed tests use. Set these against the speed tier your plan advertises.</p>
      <table class="speeds">
        <thead><tr><th>When (<span class="tc-secret" data-tz-zone>UTC</span>)</th><th>Down (Mbps)</th><th>Up (Mbps)</th><th>Latency</th><th>Jitter</th><th>Server</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
      #{if length(tests) > 20, do: ~s(<p class="muted small">Showing the 20 most recent — the full list is in the speed-tests CSV.</p>), else: ~s(<p class="muted small">Full list with exact values is in the speed-tests CSV export.</p>)}
    </section>
    """
  end

  defp speed_section(_), do: ""

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
          <td class="mono">#{time_el(e.occurred_at)}</td>
          <td>#{esc(segment_label(e.segment))}</td>
          <td>#{esc(spike_detail(e))}</td>
          <td>#{source_tag(e)}</td>
        </tr>
        """
      end)

    """
    <section class="stability">
      <h2>Connection stability — logged spikes</h2>
      <p>#{length(events)} brief spike/loss event(s) caught by continuous sampling (~5×/sec) —
      the intermittent stutters that never show up in an "average" but ruin a call or game.</p>
      #{source_summary(events)}
      <table class="spikes">
        <thead><tr><th>When (<span class="tc-secret" data-tz-zone>UTC</span>)</th><th>Where</th><th>What happened</th><th>Likely source</th></tr></thead>
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

  # A coloured tag attributing the event to its likely source. ISP-side events
  # get the warning colour (the ones worth raising with your provider); local /
  # host-freeze events are muted, so a machine hiccup logged on both segments no
  # longer reads as an ISP fault.
  defp source_tag(e) do
    case Map.get(e, :source) do
      nil ->
        ""

      source ->
        ~s(<span class="src src-#{source}">#{esc(SpikeAnalysis.source_label(source))}</span>)
    end
  end

  # The honest breakdown: of all the logged spikes, who caused each one? We answer
  # the only question that matters — was it me, my ISP, or the wider internet — as a
  # scannable list rather than one dense paragraph, and we hide any bucket that's
  # empty so a clean category never shows up as a confusing "0 were…".
  defp source_summary(events) do
    %{isp: isp, isp_unconfirmed: one_route, local: local, host_freeze: freeze, total: total} =
      SpikeAnalysis.summarize(events)

    if total == 0 do
      ""
    else
      you = local + freeze

      buckets =
        [
          {isp, "src-isp", "Your ISP",
           "confirmed on a second provider's path at the same instant — so the whole provider stumbled, not just one site. These are the ones worth raising with them."},
          {one_route, "src-isp_unconfirmed", "The wider internet",
           "only this one route stuttered while a second provider stayed clean — likely a single destination or a peering hop out there, not your ISP as a whole."},
          {you, "src-local", "Your side — this machine or Wi-Fi", you_detail(freeze)}
        ]
        |> Enum.filter(fn {n, _cls, _label, _detail} -> n > 0 end)
        |> Enum.map_join("", fn {n, cls, label, detail} ->
          ~s(<li class="#{cls}"><strong>#{n}</strong> <span class="txt">— <b>#{label}.</b> #{detail}</span></li>)
        end)

      """
      <p class="muted small">Who caused each one? Every spike is checked against a second
      provider's path and against your own router at the same instant, so we can place the blame:</p>
      <ul class="source-breakdown">#{buckets}</ul>
      """
    end
  end

  # The "your side" line. When some events were multi-second freezes on both
  # segments at once we call that out — it's the clearest sign of a local stall.
  defp you_detail(0),
    do:
      ~s(landed on your own router at the same instant, so it never left your house — it can't be your provider.)

  defp you_detail(freeze),
    do:
      ~s(landed on your own router at the same instant — including #{freeze} multi-second freeze#{if freeze == 1, do: "", else: "s"} where both segments stalled together. These never left your house, so they can't be your provider.)

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
          <tr><td>Window covered</td><td>#{span_line(stats)}</td></tr>
        </tbody>
      </table>
      <p class="muted small">The full measurement-by-measurement timeline (with timestamps) is in the CSV export.</p>
    </section>
    """
  end

  defp footer_section(report) do
    wsl_note =
      cond do
        report.wsl_unresolved? ->
          ~s(<p class="small muted">Note: running under WSL and the Windows host was unreachable, so the “router” hop is the WSL virtual switch rather than your physical gateway — set ROUTER_IP to fix attribution.</p>)

        report.wsl? ->
          ~s(<p class="small muted">Note: running under WSL — the “router” hop is your physical gateway, auto-detected from the Windows host.</p>)

        true ->
          ""
      end

    targets =
      Enum.map_join(report.targets, "", fn {label, target} ->
        # The router/local address can reveal your subnet; hide it under stream-safe.
        value =
          if String.starts_with?(label, "Your router"),
            do: secret(~s(<span class="mono">#{esc(target)}</span>)),
            else: ~s(<span class="mono">#{esc(target)}</span>)

        ~s(<li><strong>#{esc(label)}:</strong> #{value}</li>)
      end)

    """
    <footer>
      <h3>What was measured</h3>
      <ul class="targets">#{targets}</ul>
      #{wsl_note}
      <p class="small muted">Generated by DropDoctor — an open-source connection diagnostic. Times are <span class="tc-secret" data-tz-zone>UTC</span>.</p>
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
    ~s(#{total_window(first, last)} of monitoring, #{time_el(first)} → #{time_el(last)} <span class="tc-secret" data-tz-zone>UTC</span>)
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

  defp fmt_ms(n), do: Format.ms(n)
  defp fmt_mbps(n), do: Format.mbps(n)

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

  defp zone_badge(zone) do
    key = to_string(zone || "unknown")
    key = if key in ~w(local isp_edge isp transit destination), do: key, else: "unknown"
    ~s(<span class="zone #{key}">#{esc(zone_label(zone))}</span>)
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
    /* Light theme — mirrors the dashboard's daisyUI "light" palette. Scoped to
       @media screen so it never fights the print block's professional palette.
       theme_script() sets data-theme on <html> to track the running app. */
    @media screen {
      :root[data-theme="light"], :root[data-theme$="-light"] {
        color-scheme: light;
        --bg: oklch(96% 0.001 286.375);
        --card: oklch(98% 0 0);
        --line: oklch(88% 0.004 286.32);
        --ink: oklch(21% 0.006 285.885);
        --muted: oklch(47% 0.018 286);
        --primary: oklch(70% 0.213 47.604);
        --ok: oklch(70% 0.14 182.503);
        --warn: oklch(66% 0.179 58.318);
        --bad: oklch(58% 0.253 17.585);
      }
      /* Links lighten the primary toward white on dark; darken it on light. */
      :root[data-theme="light"] a, :root[data-theme$="-light"] a {
        color: color-mix(in oklab, var(--primary) 78%, black);
      }
      /* Per-colorway accent: the neutral groups above carry bg/ink/lines for the
         light and dark modes; here each colorway just retints --primary (and thus
         the page glow, headings accent and links) so the report tracks whatever
         palette the dashboard is on. Generated from DropDoctor.Themes. */
    #{colorway_theme_css()}
    }
    * { box-sizing: border-box; }
    body { font-family: "Segoe UI", system-ui, -apple-system, Roboto, sans-serif; color: var(--ink);
           margin: 0; padding: 0 1.25rem 4rem; line-height: 1.55;
           background-color: color-mix(in oklab, var(--primary) 9%, var(--bg));
           background-image:
             radial-gradient(ellipse 75% 45% at 50% -6%, color-mix(in oklab, var(--primary) 30%, transparent), transparent 72%),
             radial-gradient(color-mix(in oklab, var(--ink) 5%, transparent) 1px, transparent 1px);
           background-size: 100% 100%, 24px 24px;
           background-attachment: fixed; min-height: 100vh; }
    main { max-width: 54rem; margin: 0 auto; }
    h1 { font-size: 1.9rem; margin: 0 0 .25rem; letter-spacing: -.02em; display: flex; align-items: center; gap: .55rem; }
    .logo { width: 1.7rem; height: 1.7rem; flex: none; color: var(--primary); }
    .ico { width: 1rem; height: 1rem; flex: none; }
    h2 { font-size: 1.15rem; margin: 0 0 .75rem; letter-spacing: -.01em; padding-bottom: .5rem; border-bottom: 1px solid color-mix(in oklab, var(--primary) 24%, var(--line)); }
    h3 { font-size: 1rem; margin: 1.1rem 0 .4rem; }
    p { margin: .45rem 0; }
    a { color: color-mix(in oklab, var(--primary) 75%, white); }
    .subtitle { color: var(--muted); margin-top: 0; font-size: 1.02rem; }
    .generated { color: var(--muted); font-size: .9rem; }
    header { padding: 1.75rem 0 .25rem; }
    section, footer { background: linear-gradient(180deg, color-mix(in oklab, white 5%, transparent), transparent 55%), color-mix(in oklab, var(--primary) 7%, var(--card));
           border: 1px solid color-mix(in oklab, var(--primary) 13%, var(--line)); border-radius: var(--radius); padding: 1.25rem 1.4rem; margin: 1rem 0;
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
    /* Soft zone chips, matching the dashboard's deep-diagnostic badges. */
    .zone { display: inline-flex; align-items: center; font-size: .72rem; font-weight: 600; padding: .1rem .5rem; border-radius: .4rem; white-space: nowrap;
            border: 1px solid color-mix(in oklab, currentColor 30%, transparent); background: color-mix(in oklab, currentColor 13%, transparent); }
    .zone.local { color: var(--primary); }
    .zone.isp_edge, .zone.isp { color: var(--warn); }
    .zone.destination { color: var(--ok); }
    .zone.transit, .zone.unknown { color: var(--muted); }
    /* Likely-source chips for the spike log — same shape as zone chips. ISP-side
       events stand out (warn); local / host-freeze events are muted. */
    .src { display: inline-flex; align-items: center; font-size: .72rem; font-weight: 600; padding: .1rem .5rem; border-radius: .4rem; white-space: nowrap;
           border: 1px solid color-mix(in oklab, currentColor 30%, transparent); background: color-mix(in oklab, currentColor 13%, transparent); }
    /* ISP-side events (the ones worth raising with your provider) get the warn
       colour and stand out; local / host-freeze noise is muted so it recedes. */
    .src-isp { color: var(--warn); }
    /* Confirmed on one route only — real, but not proven provider-wide, so it
       reads cooler than a corroborated ISP fault. */
    .src-isp_unconfirmed { color: color-mix(in oklab, var(--warn) 50%, var(--muted)); }
    .src-local, .src-host_freeze { color: var(--muted); }
    /* The "who caused each spike" breakdown. Each row borrows its accent from the
       same .src-* colour used on the log chips, so the count + border pick up the
       category tint while the sentence itself stays readable ink. */
    ul.source-breakdown { list-style: none; margin: .55rem 0 .2rem; padding: 0; display: grid; gap: .45rem; }
    ul.source-breakdown li { padding: .5rem .65rem; border-radius: .5rem;
      border: 1px solid color-mix(in oklab, currentColor 26%, transparent);
      background: color-mix(in oklab, currentColor 9%, transparent); }
    ul.source-breakdown li strong { font-size: 1.05rem; font-weight: 800; }
    ul.source-breakdown li .txt { color: var(--ink); font-size: .88rem; }
    ul.source-breakdown li .txt b { font-weight: 700; }
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
    .toolbar > button, .toolbar > a { font: inherit; font-size: .75rem; font-weight: 600; height: 2rem; padding: 0 .75rem; border-radius: .25rem;
               display: inline-flex; align-items: center; line-height: 1; gap: .4rem;
               border: 1px solid color-mix(in oklab, var(--ink) 16%, transparent);
               background-color: color-mix(in oklab, var(--ink) 6%, transparent);
               background-image: linear-gradient(180deg, color-mix(in oklab, white 6%, transparent), transparent 60%);
               box-shadow: inset 0 1px 0 0 color-mix(in oklab, white 8%, transparent);
               color: var(--ink); cursor: pointer; text-decoration: none; transition: background-color .15s, border-color .15s; }
    .toolbar > button:hover, .toolbar > a:hover { border-color: color-mix(in oklab, var(--ink) 28%, transparent);
               background-color: color-mix(in oklab, var(--ink) 12%, transparent); }
    .toolbar > button { color: #fff; border-color: color-mix(in oklab, var(--primary) 38%, transparent);
               background-color: color-mix(in oklab, var(--primary) 80%, var(--card));
               background-image: linear-gradient(180deg, color-mix(in oklab, white 9%, transparent), transparent 60%);
               box-shadow: inset 0 1px 0 0 color-mix(in oklab, white 12%, transparent); }
    .toolbar > button:hover { background-color: color-mix(in oklab, var(--primary) 92%, var(--card)); border-color: color-mix(in oklab, var(--primary) 55%, transparent); }
    .toolbar .hint { color: var(--muted); font-size: .82rem; }
    /* Live-update slots: a structural wrapper the live feed swaps by id. Adds no
       box of its own, so the page lays out exactly as if the sections were inline. */
    .dd-slot { display: contents; }
    /* "Live" indicator — reflects the SSE connection state; hidden in print. */
    .dd-live { display: inline-flex; align-items: center; gap: .4rem; font-size: .75rem; font-weight: 600; color: var(--muted); user-select: none; }
    .dd-live-dot { width: .5rem; height: .5rem; border-radius: 9999px; background: currentColor; flex: none; }
    .dd-live-text::after { content: "Connecting…"; }
    .dd-live[data-state="live"] { color: var(--ok); }
    .dd-live[data-state="live"] .dd-live-dot { animation: dd-pulse 2s ease-in-out infinite; }
    .dd-live[data-state="live"] .dd-live-text::after { content: "Live"; }
    .dd-live[data-state="reconnecting"] { color: var(--warn); }
    .dd-live[data-state="reconnecting"] .dd-live-text::after { content: "Reconnecting…"; }
    @keyframes dd-pulse { 0%, 100% { opacity: 1; } 50% { opacity: .35; } }
    @media (prefers-reduced-motion: reduce) { .dd-live-dot { animation: none !important; } }
    /* View controls: stream-safe privacy + timezone toggle (match the dashboard). */
    .tc-controls { display: inline-flex; align-items: center; gap: .5rem; margin-left: auto; }
    .tc-seg { display: inline-flex; align-items: center; gap: 2px; padding: 2px; border-radius: 9999px; border: 1px solid var(--line); background: color-mix(in oklab, var(--ink) 6%, transparent); }
    .tc-seg button { display: inline-flex; align-items: center; justify-content: center; padding: .25rem .4rem; border-radius: 9999px; border: none; background: none; color: var(--ink); opacity: .5; cursor: pointer; line-height: 0; }
    .tc-seg button:hover { opacity: .85; }
    [data-privacy="off"] .tc-seg button[data-privacy-set="off"],
    [data-privacy="blur"] .tc-seg button[data-privacy-set="blur"],
    [data-privacy="strict"] .tc-seg button[data-privacy-set="strict"] { opacity: 1; background: var(--card); box-shadow: inset 0 1px 0 0 color-mix(in oklab, white 10%, transparent); }
    .tc-seg svg { width: 1rem; height: 1rem; }
    .tc-seg-btn { display: inline-flex; align-items: center; gap: .3rem; padding: .3rem .6rem; border-radius: 9999px; border: 1px solid var(--line);
                  background: color-mix(in oklab, var(--ink) 6%, transparent); color: var(--ink); font: inherit; font-size: .78rem; font-weight: 600; cursor: pointer; opacity: .85; }
    .tc-seg-btn:hover { opacity: 1; }
    .tc-seg-btn svg { width: 1rem; height: 1rem; }
    .tc-tz-utc { display: none; }
    [data-tz="utc"] .tc-tz-local { display: none; }
    [data-tz="utc"] .tc-tz-utc { display: inline; }
    /* Stream-safe: blur (hover to peek) or redact personal/identifying values. */
    [data-privacy="blur"] .tc-secret { filter: blur(6px); cursor: help; user-select: none; transition: filter .12s ease; }
    [data-privacy="blur"] .tc-secret:hover { filter: none; user-select: text; }
    [data-privacy="strict"] .tc-secret { color: transparent !important; background-color: color-mix(in oklab, var(--ink) 45%, transparent); border-radius: 3px; user-select: none; }
    [data-privacy="strict"] .tc-secret * { visibility: hidden; }
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
      /* The printed proof always shows real values, regardless of stream-safe. */
      .tc-secret { filter: none !important; color: inherit !important; background: none !important; }
      .tc-secret * { visibility: visible !important; }
    }
    """
  end
end
