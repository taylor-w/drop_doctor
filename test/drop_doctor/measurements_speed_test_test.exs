defmodule DropDoctor.MeasurementsSpeedTestTest do
  use DropDoctor.DataCase, async: true

  alias DropDoctor.Measurements

  defp result(overrides \\ %{}) do
    Map.merge(
      %{
        ok?: true,
        download_mbps: 123.4,
        upload_mbps: 12.3,
        latency_ms: 20.1,
        jitter_ms: 1.1,
        server: "speed.cloudflare.com",
        down_bytes: 100_000,
        up_bytes: 50_000,
        measured_at: DateTime.utc_now(),
        error: nil
      },
      overrides
    )
  end

  test "records a result and maps ok? onto the ok column" do
    assert {:ok, row} = Measurements.record_speed_test(result())
    assert row.ok == true
    assert row.download_mbps == 123.4
    assert row.upload_mbps == 12.3
    assert Measurements.count_speed_tests() == 1
  end

  test "latest_speed_test returns the newest by measured_at" do
    older = DateTime.add(DateTime.utc_now(), -60, :second)
    {:ok, _} = Measurements.record_speed_test(result(%{measured_at: older, download_mbps: 1.0}))
    {:ok, newest} = Measurements.record_speed_test(result(%{download_mbps: 999.0}))

    assert Measurements.latest_speed_test().id == newest.id
    assert Measurements.latest_speed_test().download_mbps == 999.0
  end

  test "recent_speed_tests is newest-first" do
    older = DateTime.add(DateTime.utc_now(), -60, :second)
    {:ok, _} = Measurements.record_speed_test(result(%{measured_at: older, download_mbps: 1.0}))
    {:ok, _} = Measurements.record_speed_test(result(%{download_mbps: 2.0}))

    assert [%{download_mbps: 2.0}, %{download_mbps: 1.0}] = Measurements.recent_speed_tests()
  end

  test "prune keeps speed tests regardless of age — they're durable proof, not sampled history" do
    stale = DateTime.add(DateTime.utc_now(), -7200, :second)
    {:ok, _} = Measurements.record_speed_test(result(%{measured_at: stale}))
    {:ok, _} = Measurements.record_speed_test(result())

    Measurements.prune(3600)
    # Both rows survive the prune — only reset/0 clears speed tests.
    assert Measurements.count_speed_tests() == 2
  end

  test "rejects an implausible (negative or absurd) measurement rather than storing it" do
    assert {:error, _} = Measurements.record_speed_test(result(%{download_mbps: -1.0}))
    assert {:error, _} = Measurements.record_speed_test(result(%{upload_mbps: 9_999_999.0}))
    assert {:error, _} = Measurements.record_speed_test(result(%{down_bytes: -5}))
    assert Measurements.count_speed_tests() == 0
  end

  test "reset wipes recorded speed tests" do
    {:ok, _} = Measurements.record_speed_test(result())
    assert Measurements.reset() >= 1
    assert Measurements.count_speed_tests() == 0
  end
end
