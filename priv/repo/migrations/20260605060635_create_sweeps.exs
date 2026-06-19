defmodule DropDoctor.Repo.Migrations.CreateSweeps do
  use Ecto.Migration

  def change do
    create table(:sweeps) do
      # Overall verdict
      add :status, :string, null: false
      add :culprit, :string, null: false
      add :headline, :string

      # Headline numbers, denormalized for fast charting/history without
      # decoding the JSON blob on every row.
      add :router_rtt_ms, :float
      add :router_loss_pct, :float
      add :internet_rtt_ms, :float
      add :internet_loss_pct, :float
      add :dns_ms, :float
      add :web_ms, :float

      # Full verdict (segments, evidence, raw probe output) for the detail view.
      add :verdict, :map

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:sweeps, [:inserted_at])
    create index(:sweeps, [:status])
  end
end
