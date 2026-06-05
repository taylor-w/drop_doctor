defmodule TrackConn.Measurements.Sweep do
  @moduledoc """
  One complete pass over the probe ladder, plus the verdict derived from it.
  This is the unit of history — the timeline you can show your ISP.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :status,
             :culprit,
             :headline,
             :router_rtt_ms,
             :router_loss_pct,
             :router_max_rtt_ms,
             :router_jitter_ms,
             :internet_rtt_ms,
             :internet_loss_pct,
             :internet_max_rtt_ms,
             :internet_jitter_ms,
             :dns_ms,
             :web_ms,
             :verdict,
             :inserted_at
           ]}

  schema "sweeps" do
    field :status, :string
    field :culprit, :string
    field :headline, :string
    field :router_rtt_ms, :float
    field :router_loss_pct, :float
    field :router_max_rtt_ms, :float
    field :router_jitter_ms, :float
    field :internet_rtt_ms, :float
    field :internet_loss_pct, :float
    field :internet_max_rtt_ms, :float
    field :internet_jitter_ms, :float
    field :dns_ms, :float
    field :web_ms, :float
    field :verdict, :map

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @fields [
    :status,
    :culprit,
    :headline,
    :router_rtt_ms,
    :router_loss_pct,
    :router_max_rtt_ms,
    :router_jitter_ms,
    :internet_rtt_ms,
    :internet_loss_pct,
    :internet_max_rtt_ms,
    :internet_jitter_ms,
    :dns_ms,
    :web_ms,
    :verdict
  ]

  def changeset(sweep, attrs) do
    sweep
    |> cast(attrs, @fields)
    |> validate_required([:status, :culprit])
  end
end
