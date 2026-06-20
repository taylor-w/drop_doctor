defmodule DropDoctor.Measurements.SpeedTest do
  @moduledoc """
  One recorded download/upload throughput snapshot — the stored form of a result
  measured by the browser `.SpeedTest` hook (in `DropDoctorWeb.DashboardLive`)
  and mapped server-side by `DropDoctor.Measurements.record_speed_test/1`, kept as
  timestamped proof of delivered speed against the tier an ISP sells.

  Because the figures arrive from the (untrusted) client, the changeset
  bounds-checks them: the timestamp is stamped server-side, and the throughput /
  latency / byte counts must be non-negative and within a sane ceiling, so a
  garbled or spoofed payload can't be stored as evidence.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :measured_at,
             :download_mbps,
             :upload_mbps,
             :latency_ms,
             :jitter_ms,
             :server,
             :down_bytes,
             :up_bytes,
             :ok,
             :error,
             :inserted_at
           ]}

  schema "speed_tests" do
    field :measured_at, :utc_datetime_usec
    field :download_mbps, :float
    field :upload_mbps, :float
    field :latency_ms, :float
    field :jitter_ms, :float
    field :server, :string
    field :down_bytes, :integer
    field :up_bytes, :integer
    field :ok, :boolean, default: false
    field :error, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @fields [
    :measured_at,
    :download_mbps,
    :upload_mbps,
    :latency_ms,
    :jitter_ms,
    :server,
    :down_bytes,
    :up_bytes,
    :ok,
    :error
  ]

  # A generous upper bound that still rejects nonsense: well above any real
  # consumer/business line (100 Gbps) so a legitimate measurement always passes,
  # but a garbled or spoofed figure does not get stored as "proof".
  @max_mbps 100_000.0

  def changeset(speed_test, attrs) do
    speed_test
    |> cast(attrs, @fields)
    |> validate_required([:measured_at, :ok])
    |> validate_number(:download_mbps,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_mbps
    )
    |> validate_number(:upload_mbps,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_mbps
    )
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
    |> validate_number(:jitter_ms, greater_than_or_equal_to: 0)
    |> validate_number(:down_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:up_bytes, greater_than_or_equal_to: 0)
  end
end
