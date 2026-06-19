defmodule DropDoctor.Measurements.SpikeEvent do
  @moduledoc """
  One logged instability event on a monitored host — a latency spike or a brief
  burst of packet loss the continuous `DropDoctor.SpikeMonitor` caught between the
  5-second sweeps. The timestamped record you can hand an ISP to prove the
  intermittent problems that never show up in an "average".
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :occurred_at,
             :segment,
             :host,
             :kind,
             :peak_ms,
             :baseline_ms,
             :loss_pct,
             :samples,
             :corroborated
           ]}

  schema "spike_events" do
    # When it happened, and on which segment ("router" / "internet") + host.
    field :occurred_at, :utc_datetime_usec
    field :segment, :string
    field :host, :string
    # "latency" (a spike) or "loss" (brief packet loss).
    field :kind, :string
    # Latency events: the worst round-trip and the normal baseline at the time.
    field :peak_ms, :float
    field :baseline_ms, :float
    # Loss events: percentage of the burst that went unanswered.
    field :loss_pct, :float
    # How many packets the triggering burst contained.
    field :samples, :integer
    # Internet events only: was the disturbance confirmed against a second
    # provider's anchor? true = provider-wide (confident ISP), false = one route
    # only, nil = couldn't corroborate (router events / no second anchor).
    field :corroborated, :boolean

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @fields [
    :occurred_at,
    :segment,
    :host,
    :kind,
    :peak_ms,
    :baseline_ms,
    :loss_pct,
    :samples,
    :corroborated
  ]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @fields)
    |> validate_required([:occurred_at, :segment, :kind])
  end
end
