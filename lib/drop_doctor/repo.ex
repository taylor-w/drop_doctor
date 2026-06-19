defmodule DropDoctor.Repo do
  use Ecto.Repo,
    otp_app: :drop_doctor,
    adapter: Ecto.Adapters.SQLite3
end
