defmodule DropDoctor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DropDoctorWeb.Telemetry,
      DropDoctor.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:drop_doctor, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:drop_doctor, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DropDoctor.PubSub},
      # Supervises the short-lived Tasks each sweep spawns, so a hung/crashed
      # probe is isolated and never takes down the monitor.
      {Task.Supervisor, name: DropDoctor.ProbeSupervisor},
      # Start to serve requests, typically the last entry
      DropDoctorWeb.Endpoint
    ]

    # The connection monitor runs probe sweeps on an interval; the spike monitors
    # continuously sample the router and open internet for jitter/spikes between
    # sweeps. All disabled in tests (which inject fakes / would spawn real pings)
    # via :start_monitor config.
    children =
      if Application.get_env(:drop_doctor, :start_monitor, true) do
        # Clean up any resident pings orphaned by a previous run before starting
        # our own, so they can't accumulate across restarts into an ICMP flood
        # that gets our probe targets rate-limited. See Probes.Ping.stream/3.
        DropDoctor.Probes.Ping.reap_orphaned_streams()

        children
        |> List.insert_at(-2, DropDoctor.Monitor)
        |> List.insert_at(
          -2,
          spike_child(:router, DropDoctor.Targets.router_target(), nil, [53, 80, 443])
        )
        |> List.insert_at(
          -2,
          spike_child(
            :internet,
            DropDoctor.Targets.internet_target(),
            DropDoctor.Targets.internet_anchors(),
            [443]
          )
        )
      else
        children
      end

    # In the packaged binary, pop open the dashboard once the Endpoint is up.
    # Enabled only where configured (prod/release) and overridable via env, so
    # dev/test never spawn a browser. Added last → starts after the Endpoint.
    children =
      if open_browser?() do
        children ++ [DropDoctor.Launcher]
      else
        children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DropDoctor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DropDoctorWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Two SpikeMonitors share one module, so each needs a distinct supervisor id.
  # `hosts` lets the internet monitor pick a reachable anchor; the router has a
  # single target.
  defp spike_child(key, host, hosts, tcp_ports) do
    opts =
      [key: key, host: host] ++
        if(hosts, do: [hosts: hosts], else: []) ++
        if(tcp_ports != [], do: [tcp_ports: tcp_ports], else: [])

    Supervisor.child_spec({DropDoctor.SpikeMonitor, opts}, id: {DropDoctor.SpikeMonitor, key})
  end

  defp skip_migrations?() do
    # Run migrations on boot only where configured (prod/release). We can't rely
    # on the RELEASE_NAME env var here: Burrito's wrapper launches the release
    # directly and doesn't export it, so a config flag is the robust signal.
    # Dev/test leave this false and migrate via `mix ecto.migrate` / test setup.
    not Application.get_env(:drop_doctor, :migrate_on_boot, false)
  end

  # Auto-open the browser only when the app is configured to (prod release) and
  # the user hasn't opted out with DROP_DOCTOR_NO_BROWSER.
  defp open_browser?() do
    Application.get_env(:drop_doctor, :open_browser, false) and
      System.get_env("DROP_DOCTOR_NO_BROWSER") in [nil, ""]
  end
end
