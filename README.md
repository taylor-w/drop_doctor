# 📡 track_conn

**Is it you, your router, or your ISP? Find out — with proof.**

[![CI](https://github.com/taylor-w/track_conn/actions/workflows/ci.yml/badge.svg)](https://github.com/taylor-w/track_conn/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

When your internet feels bad, the hardest question is *whose fault it is*. The
ISP blames your equipment, you suspect the ISP, and nobody can prove anything.
track_conn settles it. It continuously checks every layer between your computer
and the open internet, tells you — in one plain sentence — where the problem
actually is, and keeps a timestamped history you can show your ISP.

It runs entirely on your own machine and opens in your browser. **No accounts,
no cloud, nothing leaves your network.**

---

## Get it running

Download the file for your operating system, then double-click it. That's it —
your browser opens to the dashboard. Nothing to install.

| Your OS | Download |
|---------|----------|
| Windows | [`track_conn_windows.exe`](https://github.com/taylor-w/track_conn/releases/latest/download/track_conn_windows.exe) |
| macOS (Apple Silicon, M1+) | [`track_conn_macos`](https://github.com/taylor-w/track_conn/releases/latest/download/track_conn_macos) |
| macOS (Intel) | [`track_conn_macos_intel`](https://github.com/taylor-w/track_conn/releases/latest/download/track_conn_macos_intel) |
| Linux (x86_64) | [`track_conn_linux`](https://github.com/taylor-w/track_conn/releases/latest/download/track_conn_linux) |

All downloads are on the **[latest release page](https://github.com/taylor-w/track_conn/releases/latest)**.
The app starts at **<http://localhost:4000>** and opens it for you. To quit, run
it from a terminal and press `Ctrl+C` twice, or end the process from your OS.

> **Your computer may warn you the first time** — the downloads aren't yet
> code-signed, so the OS flags apps from an "unknown developer". This is
> expected:
> - **Windows:** "Windows protected your PC" → **More info → Run anyway**.
> - **macOS:** "developer cannot be verified" → **right-click the app → Open**,
>   then **Open** again. (Or: `xattr -d com.apple.quarantine track_conn_macos`.)
> - **macOS/Linux:** you may first need to mark it runnable: `chmod +x track_conn_macos`.

Prefer to run from source, or want to build the binaries yourself? See
**[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)**.

---

## What it tells you

Open the dashboard and you get a **traffic light**, one plain-English sentence,
and live numbers for each layer. A healthy connection shows 🟢 *"Your connection
looks healthy."* When something breaks, the light turns red and names the
culprit — e.g. 🔴 *"This is your ISP — your router is fine but the internet is
unreachable."*

### How it knows

Every few seconds it checks a **ladder** of targets, from closest to you out to
the wider internet:

| Layer | What it checks | A problem here means |
|-------|----------------|----------------------|
| **Your router / local network** | Reaching your gateway | Your Wi-Fi, cable, network card, or router — **your side** |
| **The open internet** | Reaching a raw IP (`1.1.1.1`, no DNS) | The link past your equipment — **usually your ISP** |
| **DNS** | Looking up a website name | Name-lookup issues — often fixed by switching DNS |
| **Loading a real website** | An actual page request | Bandwidth saturation or a slow destination |

The key insight: a failure **close to you** makes everything beyond it look
broken too. So the diagnosis walks the ladder **outward** and blames the
*earliest* broken layer. That's why it won't blame your ISP when your own Wi-Fi
is really the problem — and why, when it *does* blame your ISP, that's a
meaningful, defensible conclusion.

Verdicts are **smoothed over the last few readings**, so a single blip can't
flip the light — a real fault takes ~15–25s of sustained failure to confirm
(and clears the same way).

### Dig deeper, when it's the ISP

When the verdict points at your ISP, **Run deep diagnostic** traces *every hop*
out to the internet and shows exactly where latency or loss starts — with your
ISP's own routers named in the path. It's smart about *phantom loss* (a middle
router that looks lossy but isn't actually dropping your traffic), so it won't
cry wolf. Takes ~15s. (Available on Linux, macOS, and WSL.)

### Save proof for your ISP

When you call support you want **timestamps, not "it feels slow."** The
dashboard's **Save proof for your ISP** card gives you:

- **A printable report** — the current verdict, the evidence, your latest deep
  trace, and a history summary. Open it and choose "Save as PDF" — every browser
  can do this.
- **A CSV timeline** — one timestamped row per measurement, so a technician can
  see exactly *when* the connection broke and for how long.

---

## Roadmap

- ✅ **Exportable report** (PDF/CSV) to hand to your ISP.
- ✅ **Packaged release** — a single double-click binary, no terminal needed.
- ⬜ **Latency/loss charts** over selectable time windows.
- ⬜ **Configurable thresholds & targets** from the UI (no config-file edits).

---

## For developers

- **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** — run from source, simulate
  faults, run the tests, build the binaries, and cut a release.
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — how the code is organized
  and the design properties (self-healing, non-blocking, bounded history).

Contributions are welcome — open an issue or PR. The checks CI enforces are
`mix format --check-formatted`, `mix compile --warnings-as-errors`, and
`mix test`.

## License

[MIT](LICENSE) © Taylor Wood.

Built open source, for everyone who's tired of being told "it looks fine on our end."
