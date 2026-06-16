defmodule TrackConn.Repo.Migrations.AddSpikeCorroborated do
  use Ecto.Migration

  # Whether an internet spike was confirmed against a second provider's anchor:
  # true  = a different anchor degraded at the same moment (provider-wide → ISP),
  # false = the other anchor stayed clean (one route, not your whole ISP),
  # null  = couldn't corroborate (router events, or no second anchor reachable).
  def change do
    alter table(:spike_events) do
      add :corroborated, :boolean
    end
  end
end
