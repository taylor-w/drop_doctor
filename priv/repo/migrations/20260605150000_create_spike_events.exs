defmodule TrackConn.Repo.Migrations.CreateSpikeEvents do
  use Ecto.Migration

  # Discrete instability events caught by the continuous SpikeMonitor — the brief
  # latency spikes and packet loss that the smoothed sweep history averages away.
  # This is the timestamped "proof of intermittent problems" to hand an ISP.
  def change do
    create table(:spike_events) do
      add :occurred_at, :utc_datetime_usec, null: false
      add :segment, :string, null: false
      add :host, :string
      add :kind, :string, null: false
      add :peak_ms, :float
      add :baseline_ms, :float
      add :loss_pct, :float
      add :samples, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:spike_events, [:occurred_at])
  end
end
