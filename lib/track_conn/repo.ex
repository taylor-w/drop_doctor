defmodule TrackConn.Repo do
  use Ecto.Repo,
    otp_app: :track_conn,
    adapter: Ecto.Adapters.SQLite3
end
