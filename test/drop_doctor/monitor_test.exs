defmodule DropDoctor.MonitorTest do
  use ExUnit.Case, async: false
  alias DropDoctor.Monitor
  alias DropDoctor.Test.FakeProbes

  setup do
    name = :"monitor_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      start_supervised(
        {Monitor,
         name: name, persist: false, interval: 10_000, sweep_opts: [probes: FakeProbes.healthy()]}
      )

    %{name: name}
  end

  test "produces a healthy verdict from fake probes", %{name: name} do
    Monitor.subscribe(name)
    Monitor.sweep_now(name)

    assert_receive {:sweep, verdict, nil}, 2_000
    assert verdict.status == :healthy
    assert verdict.culprit == :none
    assert verdict.samples >= 1
    assert length(verdict.segments) == 4
  end

  test "latest/0 returns instantly and never blocks on the network", %{name: name} do
    verdict = Monitor.latest(name)
    assert is_map(verdict)
    assert Map.has_key?(verdict, :status)
  end

  test "pause and resume toggle the running state", %{name: name} do
    assert Monitor.running?(name)
    Monitor.pause(name)
    refute Monitor.running?(name)
    Monitor.resume(name)
    assert Monitor.running?(name)
  end
end
