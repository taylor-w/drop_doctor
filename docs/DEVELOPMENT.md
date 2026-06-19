# Development

How to run DropDoctor from source, test it, and build the distributable
binaries. For what the app does and how to *use* it, see the
[README](../README.md); for how the code is organized, see
[ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- **Elixir** ~1.18 / **Erlang/OTP** ~27
- `ping` (present on every OS)
- Works on Linux, macOS, Windows, and WSL

## Run from source

```bash
mix deps.get            # first time only
mix ecto.migrate        # first time only — creates the SQLite history file
mix phx.server
```

Then open **<http://localhost:4000>**. Set the `PORT` env var to use a different
port (e.g. `PORT=4040 mix phx.server`).

### WSL users

Inside WSL2 your *default gateway* is the Windows host's virtual switch (a
`172.x.x.x` address), **not your physical router**. The app detects this and
shows a banner. For true "router vs. ISP" attribution, point it at your real
router:

```bash
ROUTER_IP=192.168.1.1 mix phx.server
```

(Find your real router IP on Windows with `ipconfig` → "Default Gateway"; it's
commonly `192.168.1.1` or `192.168.0.1`.)

## Tests

```bash
mix test
```

The suite covers all attribution scenarios (healthy, local-down, Wi-Fi loss,
ISP-down, ISP-degraded, DNS-broken, DNS-slow, bandwidth), Linux/macOS/Windows
`ping` output parsing, the deep-trace phantom-loss/zone logic, and the report
exports (CSV shape + HTML rendering).

Before opening a PR, run the same checks CI runs:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

## Simulate faults (prove the diagnosis)

The most convincing way to trust the tool is to break a layer on purpose and
watch the verdict change. Add a line to `config/dev.exs` and restart the server:

- **Fake an ISP outage** — point the "internet" probe at an unroutable IP:
  ```elixir
  config :drop_doctor, :targets, %{internet: "10.255.255.1"}
  ```
  Expect: 🔴 *"This is your ISP — your router is fine but the internet is
  unreachable."* (router still green, internet red.)

- **Fake a local/router problem** — point "router" at a dead LAN IP:
  ```elixir
  config :drop_doctor, :targets, %{router: "192.168.99.99"}
  ```
  Expect: 🔴 *"The problem is on your side — your router isn't responding."*

- **Fake a DNS problem** — point "dns" at a non-existent name:
  ```elixir
  config :drop_doctor, :targets, %{dns: "this-name-does-not-exist.invalid"}
  ```
  Expect: 🔴 *"Your internet works, but DNS is the problem"* (router + internet
  green, DNS red).

- **Real-world test** — unplug your Wi-Fi/Ethernet for ~15s and watch the
  dashboard go red live, then recover, with the outage recorded in history.

> Verdicts are median-smoothed over the last 5 readings, so a real fault takes
> ~15–25s of *sustained* failure to confirm (and clears the same way). On first
> launch you'll briefly see **"Warming up…"** while the window fills.

## Build the binaries

The distributable binaries are produced with
[Burrito](https://github.com/burrito-elixir/burrito), which wraps a standard
Elixir release in a Zig-compiled self-extracting launcher. You need these in
your `PATH`:

- **Zig 0.15.2** (the exact version Burrito pins) — `zig`
- **xz** — `xz`
- **7-Zip** (`7z` / `7zz`) — only needed for the Windows target

Then, from the project directory:

```bash
mix deps.get
MIX_ENV=prod mix assets.deploy          # build + digest static assets
MIX_ENV=prod mix release                # builds every target in mix.exs
# …or one at a time:
BURRITO_TARGET=linux MIX_ENV=prod mix release
```

Outputs land in `burrito_out/` (gitignored — these are release artifacts, not
committed). A Linux host can cross-build all of Linux/Windows/macOS; building
*on* Windows isn't supported — use WSL there.

### What a packaged binary does at runtime

On first launch it unpacks itself into a per-user cache and starts the server on
**<http://localhost:4000>**, opening your browser automatically. It binds to
**loopback only** (`127.0.0.1`) — a personal tool, not exposed to the network —
and keeps its history database and a generated session key in a per-user data
folder (never next to the binary):

- **Windows:** `%APPDATA%\drop_doctor`
- **macOS:** `~/Library/Application Support/drop_doctor`
- **Linux:** `~/.local/share/drop_doctor`

## Cut a release

Releases are automated by [`.github/workflows/release.yml`](../.github/workflows/release.yml):
pushing a version tag cross-builds all four binaries and attaches them to a
GitHub Release.

```bash
git tag v0.1.0 && git push origin v0.1.0
```
