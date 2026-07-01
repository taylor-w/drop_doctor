defmodule DropDoctor.MixProject do
  use Mix.Project

  def project do
    [
      # Keep in step with the released git tag: the version names the release
      # path (`_build/prod/rel/drop_doctor/lib/drop_doctor-<version>`) and is
      # reported by the running binary. A stale version made every release reuse
      # the same rel path, which (with a cached _build) shipped old code.
      app: :drop_doctor,
      version: "0.2.2",
      elixir: "~> 1.15",
      description:
        "Is bad internet your fault, your DNS, or your ISP? A local tool that finds out — with timestamped proof.",
      source_url: "https://github.com/taylor-w/drop_doctor",
      homepage_url: "https://github.com/taylor-w/drop_doctor",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/taylor-w/drop_doctor"}
      ],
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Burrito wraps the assembled prod release into a single self-extracting
  # binary per OS — the "double-click to run" deliverable. On first launch the
  # wrapper unpacks the BEAM + app into a per-user cache dir and runs it.
  #
  # Build all targets:   MIX_ENV=prod mix release
  # Build one target:    BURRITO_TARGET=linux MIX_ENV=prod mix release
  # Output:              burrito_out/drop_doctor_<target>[.exe]
  defp releases do
    [
      drop_doctor: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux: [os: :linux, cpu: :x86_64],
            windows: [os: :windows, cpu: :x86_64],
            macos: [os: :darwin, cpu: :aarch64],
            macos_intel: [os: :darwin, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {DropDoctor.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Packages the prod release into a single self-extracting binary per OS
      # (the "double-click to run" deliverable). Build-time only.
      {:burrito, "~> 1.3", runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind drop_doctor", "esbuild drop_doctor"],
      "assets.deploy": [
        # Compile first so colocated JS hooks are (re)extracted to
        # _build/<env>/phoenix-colocated *before* esbuild bundles — otherwise a
        # stale/empty extraction silently drops every hook from the minified
        # bundle (dead timeline chart, no flash auto-dismiss). Mirrors assets.build.
        "compile",
        "tailwind drop_doctor --minify",
        "esbuild drop_doctor --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
