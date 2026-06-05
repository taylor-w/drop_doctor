defmodule TrackConn.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TrackConnWeb.Telemetry,
      TrackConn.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:track_conn, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:track_conn, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TrackConn.PubSub},
      # Supervises the short-lived Tasks each sweep spawns, so a hung/crashed
      # probe is isolated and never takes down the monitor.
      {Task.Supervisor, name: TrackConn.ProbeSupervisor},
      # Start to serve requests, typically the last entry
      TrackConnWeb.Endpoint
    ]

    # The connection monitor runs probe sweeps on an interval; the spike monitors
    # continuously sample the router and open internet for jitter/spikes between
    # sweeps. All disabled in tests (which inject fakes / would spawn real pings)
    # via :start_monitor config.
    children =
      if Application.get_env(:track_conn, :start_monitor, true) do
        children
        |> List.insert_at(-2, TrackConn.Monitor)
        |> List.insert_at(-2, spike_child(:router, TrackConn.Targets.router_target()))
        |> List.insert_at(-2, spike_child(:internet, TrackConn.Targets.internet_target()))
      else
        children
      end

    # In the packaged binary, pop open the dashboard once the Endpoint is up.
    # Enabled only where configured (prod/release) and overridable via env, so
    # dev/test never spawn a browser. Added last → starts after the Endpoint.
    children =
      if open_browser?() do
        children ++ [TrackConn.Launcher]
      else
        children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TrackConn.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TrackConnWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Two SpikeMonitors share one module, so each needs a distinct supervisor id.
  defp spike_child(key, host) do
    Supervisor.child_spec({TrackConn.SpikeMonitor, key: key, host: host},
      id: {TrackConn.SpikeMonitor, key}
    )
  end

  defp skip_migrations?() do
    # Run migrations on boot only where configured (prod/release). We can't rely
    # on the RELEASE_NAME env var here: Burrito's wrapper launches the release
    # directly and doesn't export it, so a config flag is the robust signal.
    # Dev/test leave this false and migrate via `mix ecto.migrate` / test setup.
    not Application.get_env(:track_conn, :migrate_on_boot, false)
  end

  # Auto-open the browser only when the app is configured to (prod release) and
  # the user hasn't opted out with TRACK_CONN_NO_BROWSER.
  defp open_browser?() do
    Application.get_env(:track_conn, :open_browser, false) and
      System.get_env("TRACK_CONN_NO_BROWSER") in [nil, ""]
  end
end
