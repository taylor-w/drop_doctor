import Config

# Don't run the live network monitor during tests; tests start their own with
# injected fake probes (see test/support/fake_probes.ex) so nothing touches the
# real network or the sandboxed DB unexpectedly.
config :track_conn, start_monitor: false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :track_conn, TrackConn.Repo,
  database: Path.expand("../track_conn_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :track_conn, TrackConnWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "jqvQdssEbMyN7RFu2MdUnGFONc6mY50NcgZKKRGyqcSG3WV3/NgwGfwULIvgSuRM",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
