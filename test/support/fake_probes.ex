defmodule DropDoctor.Test.FakeProbes do
  @moduledoc """
  Deterministic fake probes so the sweep/monitor can be tested without touching
  the network. Each implements `DropDoctor.Probe`.
  """

  defmodule HealthyPing do
    @behaviour DropDoctor.Probe
    @impl true
    def run(_target, _opts),
      do: %{
        ok?: true,
        rtt_ms: 5.0,
        loss_pct: 0.0,
        sent: 3,
        received: 3,
        raw: "fake ping",
        error: nil
      }
  end

  defmodule HealthyDns do
    @behaviour DropDoctor.Probe
    @impl true
    def run(_target, _opts),
      do: %{ok?: true, ms: 20.0, address: "1.2.3.4", raw: "fake dns", error: nil}
  end

  defmodule HealthyHttp do
    @behaviour DropDoctor.Probe
    @impl true
    def run(_target, _opts),
      do: %{ok?: true, ms: 150.0, status: 200, bytes: 0, raw: "fake http", error: nil}
  end

  defmodule SlowPing do
    @behaviour DropDoctor.Probe
    @impl true
    def run(_target, _opts) do
      Process.sleep(5_000)
      %{ok?: true, rtt_ms: 1.0, loss_pct: 0.0, sent: 3, received: 3, raw: "too late", error: nil}
    end
  end

  @doc "A registry of all-healthy fakes."
  def healthy do
    # :reach is ping-shaped, so the healthy ping fake doubles as a healthy
    # internet-reachability result.
    %{ping: HealthyPing, reach: HealthyPing, dns: HealthyDns, http: HealthyHttp}
  end
end
