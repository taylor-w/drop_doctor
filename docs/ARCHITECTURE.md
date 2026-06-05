# Architecture

A tour of how track_conn is organized. For running and building it, see
[DEVELOPMENT.md](DEVELOPMENT.md).

It's a [Phoenix](https://www.phoenixframework.org/) LiveView app: a supervised
GenServer paces the network probes off the main loop, persists results to a
local SQLite file, and broadcasts updates to a single LiveView dashboard.

## Module map

```
lib/track_conn/
  net.ex                 # cross-platform gateway/router discovery (+ WSL detection)
  targets.ex             # the probe "ladder" definition
  probe.ex               # Probe behaviour + registry (probes are injectable/testable)
  probes/
    ping.ex              # ICMP via system `ping`, parses Linux/macOS/Windows output
    dns.ex               # resolution timing via OTP's built-in resolver
    http.ex              # real HTTP fetch timing via OTP's :httpc (no extra deps)
    mtr.ex               # per-hop trace via `mtr --json` (the deep diagnostic probe)
  sweeper.ex             # runs one ladder pass concurrently w/ a bounded deadline
  aggregate.ex           # median-smooths a rolling window (debounce / anti-false-alarm)
  stability.ex           # pure stats: jitter (IPDV), p95/p99, spike + brief-loss counts
  spike_monitor.ex       # continuous high-rate ping sampler — catches spikes between sweeps
  diagnosis.ex           # the brain: turns measurements into a plain-English verdict
  path_report.ex         # interprets an mtr trace (zones, phantom-loss, culprit hop)
  deep_diagnostic.ex     # orchestrates the on-demand per-hop trace + interpretation
  monitor.ex             # supervised GenServer: paces sweeps off-loop, persists, prunes, broadcasts
  measurements.ex        # history storage/queries + retention pruning (SQLite)
  measurements/sweep.ex  # the stored record
  report.ex              # builds the exportable ISP report (printable HTML + CSV)

lib/track_conn_web/live/dashboard_live.ex            # the single-screen LiveView dashboard
lib/track_conn_web/controllers/report_controller.ex  # serves /report (HTML) and /report.csv
```

## Design properties worth knowing

- **Self-healing.** The monitor runs under OTP supervision; if any probe or
  sweep crashes it's isolated (each probe runs in its own supervised Task) and
  monitoring resumes — no daemon to babysit.
- **Non-blocking.** Sweeps run *off* the monitor's main loop, so the dashboard
  reads the last-known verdict instantly and never waits on the network.
- **Trustworthy.** Verdicts come from the median of a rolling 5-reading window,
  so transient noise can't flip the light.
- **Bounded.** History is stored in a local SQLite file (survives restarts) and
  auto-pruned to a 48-hour retention window so it never grows without limit.

## The "blame the earliest broken layer" rule

The probes form a ladder ordered by distance from the user: router → open
internet (raw IP) → DNS → real HTTP. A break low on the ladder makes everything
above it look broken too, so `diagnosis.ex` evaluates **outward** and attributes
the fault to the *first* failing rung. This is what makes an "it's your ISP"
verdict defensible: the rung beneath it (your own equipment) was confirmed
healthy first.

The deep diagnostic (`path_report.ex`) extends the same idea per-hop: it
distinguishes your **local** network, your **ISP** (consecutive hops sharing a
registrable domain), and **transit/CDN** hops, and only counts packet loss that
*persists to the destination* — ignoring intermediate routers that rate-limit
trace traffic but forward real traffic fine.
