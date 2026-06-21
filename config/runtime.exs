import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/drop_doctor start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :drop_doctor, DropDoctorWeb.Endpoint, server: true
end

config :drop_doctor, DropDoctorWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  # drop_doctor ships as a double-clickable Burrito binary, so prod must run with
  # ZERO required env vars or terminal interaction: a non-technical user just
  # launches it. Everything below therefore *defaults* sensibly and only treats
  # env vars as optional overrides for power users / server deployments.

  # Per-user, writable data directory — the read-only extracted Burrito payload
  # is NOT writable, so the DB and secret must live here. `:filename.basedir`
  # resolves the right place on each OS:
  #   Linux:   ~/.local/share/drop_doctor
  #   macOS:   ~/Library/Application Support/drop_doctor
  #   Windows: %APPDATA%\drop_doctor
  data_dir =
    System.get_env("DROP_DOCTOR_DATA_DIR") || :filename.basedir(:user_data, "drop_doctor")

  File.mkdir_p!(data_dir)

  database_path = System.get_env("DATABASE_PATH") || Path.join(data_dir, "drop_doctor.db")

  config :drop_doctor, DropDoctor.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base signs/encrypts cookies and LiveView sessions. There's no
  # human to provide one, so generate a strong key on first launch and persist
  # it next to the DB — sessions then survive restarts. An env var still wins.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      (
        secret_file = Path.join(data_dir, "secret_key_base")

        case File.read(secret_file) do
          {:ok, key} when byte_size(key) >= 64 ->
            key

          _ ->
            key = :crypto.strong_rand_bytes(48) |> Base.encode64()
            File.write!(secret_file, key)
            # Owner-only on POSIX; harmless no-op on Windows.
            _ = File.chmod(secret_file, 0o600)
            key
        end
      )

  config :drop_doctor, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Always serve when launched as a release — the binary's whole purpose is the
  # web UI, and there's no terminal to set PHX_SERVER on a double-click.
  config :drop_doctor, DropDoctorWeb.Endpoint,
    server: true,
    url: [
      host: "localhost",
      port: String.to_integer(System.get_env("PORT", "4000")),
      scheme: "http"
    ],
    http: [
      # Bind to loopback only: this is a personal diagnostic tool, not a service
      # to expose on the LAN.
      ip: {127, 0, 0, 1}
    ],
    secret_key_base: secret_key_base
end
