defmodule TrackConn.Probe do
  @moduledoc """
  Behaviour for a single measurement against one target.

  Making probes a behaviour (rather than hardcoded calls in the monitor) is what
  lets the whole sweep be unit-tested without touching the network — tests
  inject a fake probe registry — and lets new probe types (mtr, speedtest, a
  future Rust sidecar) drop in without changing the monitor.

  Implementations must return a map. The keys depend on the probe kind, but the
  monitor and diagnosis rely on a common shape per kind:

    * ping  => `%{ok?:, rtt_ms:, loss_pct:, sent:, received:, raw:, error:}`
    * dns   => `%{ok?:, ms:, address:, raw:, error:}`
    * http  => `%{ok?:, ms:, status:, bytes:, raw:, error:}`
  """

  @callback run(target :: String.t(), opts :: keyword()) :: map()

  @doc "The default mapping of ladder `kind` => probe module."
  def default_registry do
    %{
      ping: TrackConn.Probes.Ping,
      dns: TrackConn.Probes.Dns,
      http: TrackConn.Probes.Http
    }
  end

  @doc "The active registry, allowing tests/config to inject fakes."
  def registry do
    Application.get_env(:track_conn, :probes, default_registry())
  end
end
