defmodule DropDoctor.Repo.Migrations.CreateSpeedTests do
  use Ecto.Migration

  # On-demand download/upload throughput snapshots, measured by the browser
  # `.SpeedTest` hook. One row per test the user runs — timestamped proof of the
  # speed actually delivered, to set against the tier an ISP sells. Unlike sweeps
  # these are rare and hand-triggered, so they're kept as durable evidence rather
  # than pruned to the 48h window (only `reset/0` clears them).
  def change do
    create table(:speed_tests) do
      add :measured_at, :utc_datetime_usec, null: false
      add :download_mbps, :float
      add :upload_mbps, :float
      add :latency_ms, :float
      add :jitter_ms, :float
      add :server, :string
      add :down_bytes, :integer
      add :up_bytes, :integer
      add :ok, :boolean, null: false, default: false
      add :error, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:speed_tests, [:measured_at])
  end
end
