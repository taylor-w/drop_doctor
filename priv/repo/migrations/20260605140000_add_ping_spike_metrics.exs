defmodule DropDoctor.Repo.Migrations.AddPingSpikeMetrics do
  use Ecto.Migration

  # Worst single round-trip (the latency spike) and jitter (RTT mean deviation)
  # for the two ping segments, so intermittent instability is recorded over time
  # — not just the smoothed average.
  def change do
    alter table(:sweeps) do
      add :router_max_rtt_ms, :float
      add :router_jitter_ms, :float
      add :internet_max_rtt_ms, :float
      add :internet_jitter_ms, :float
    end
  end
end
