defmodule DropDoctorWeb.ReportFeedTest do
  # Pure engine tests: no HTTP server, no DB. The transport and the report
  # builder are both injected, so coalescing, diffing, heartbeating and
  # disconnect are exercised deterministically with tiny timers.
  use ExUnit.Case, async: true

  alias DropDoctorWeb.ReportFeed

  # Fast timers, with the heartbeat kept well above the coalesce window so a
  # `refute_receive` for "no extra render" can't accidentally catch a keepalive.
  @coalesce 20
  @heartbeat 300

  describe "changed_slots/2" do
    test "a fresh stream (no prior send) emits every slot" do
      assert ReportFeed.changed_slots(%{}, %{"a" => "1", "b" => "2"}) ==
               %{"a" => "1", "b" => "2"}
    end

    test "an unchanged render emits nothing" do
      same = %{"a" => "1", "b" => "2"}
      assert ReportFeed.changed_slots(same, same) == %{}
    end

    test "only the slots whose html moved are emitted" do
      prev = %{"a" => "1", "b" => "2", "c" => "3"}
      next = %{"a" => "1", "b" => "CHANGED", "c" => "3"}
      assert ReportFeed.changed_slots(prev, next) == %{"b" => "CHANGED"}
    end
  end

  describe "run/1 streaming" do
    test "sends a full snapshot as the first frame" do
      start_feed(payload: %{"dd-verdict" => "V", "dd-speed" => "S"})

      assert_receive {:frame, frame}
      assert decode_data(frame) == %{"dd-verdict" => "V", "dd-speed" => "S"}
    end

    test "coalesces a burst of broadcasts into a single render" do
      feed = start_feed(payload: %{"dd-verdict" => "v0"})
      assert_receive {:frame, _snapshot}

      set_payload(feed, %{"dd-verdict" => "v1"})
      send(feed.pid, {:sweep, %{}, %{}})
      send(feed.pid, {:stability, :router, %{}})
      send(feed.pid, {:sweep, %{}, %{}})

      assert_receive {:frame, frame}
      assert decode_data(frame) == %{"dd-verdict" => "v1"}
      # The three broadcasts produced exactly one render, not three.
      refute_receive {:frame, _}, @coalesce * 3
    end

    test "streams only the sections that actually changed" do
      feed = start_feed(payload: %{"dd-verdict" => "v0", "dd-speed" => "s0"})
      assert_receive {:frame, _snapshot}

      set_payload(feed, %{"dd-verdict" => "v0", "dd-speed" => "s1"})
      send(feed.pid, {:sweep, %{}, %{}})

      assert_receive {:frame, frame}
      assert decode_data(frame) == %{"dd-speed" => "s1"}
    end

    test "skips the render entirely when nothing changed" do
      feed = start_feed(payload: %{"dd-verdict" => "v0"})
      assert_receive {:frame, _snapshot}

      # Same payload: an armed flush finds no diff and writes nothing.
      send(feed.pid, {:sweep, %{}, %{}})
      refute_receive {:frame, _}, @coalesce * 3
    end

    test "heartbeats when idle to keep the connection (and disconnect check) alive" do
      start_feed(payload: %{"dd-verdict" => "v0"})
      assert_receive {:frame, _snapshot}

      assert_receive {:frame, ": keepalive\n\n"}, @heartbeat * 3
    end

    test "ignores unrelated messages without rendering" do
      feed = start_feed(payload: %{"dd-verdict" => "v0"})
      assert_receive {:frame, _snapshot}

      send(feed.pid, {:something_else, :noise})
      send(feed.pid, :random)
      refute_receive {:frame, _}, @coalesce * 3
      assert Process.alive?(feed.pid)
    end

    test "ends the stream (and so unsubscribes) when a write fails" do
      feed = start_feed(payload: %{"dd-verdict" => "v0"})
      assert_receive {:frame, _snapshot}
      ref = Process.monitor(feed.pid)

      # The client has gone: the next write fails. A changed payload guarantees a
      # write is attempted on the coalesced flush.
      close_transport(feed)
      set_payload(feed, %{"dd-verdict" => "v1"})
      send(feed.pid, {:sweep, %{}, %{}})

      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
    end

    test "a quiet stream still detects disconnect via the heartbeat write" do
      feed = start_feed(payload: %{"dd-verdict" => "v0"})
      assert_receive {:frame, _snapshot}
      ref = Process.monitor(feed.pid)

      # No broadcasts at all — only the idle heartbeat is left to notice the gone
      # client, and its failed write must end the stream.
      close_transport(feed)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, @heartbeat * 3
    end
  end

  # --- harness ------------------------------------------------------------

  # Starts the engine in its own process with a fake transport that forwards
  # every frame to the test as {:frame, binary} and a swappable payload.
  defp start_feed(opts) do
    test = self()
    {:ok, payload} = Agent.start_link(fn -> Keyword.fetch!(opts, :payload) end)
    {:ok, gate} = Agent.start_link(fn -> :open end)

    emit = fn io, data ->
      case Agent.get(gate, & &1) do
        :open -> send(test, {:frame, IO.iodata_to_binary(data)}) && {:ok, io}
        :closed -> {:error, :closed}
      end
    end

    pid =
      spawn(fn ->
        ReportFeed.run(
          io: :sink,
          emit: emit,
          build: fn -> Agent.get(payload, & &1) end,
          coalesce_ms: @coalesce,
          heartbeat_ms: @heartbeat
        )
      end)

    %{pid: pid, payload: payload, gate: gate}
  end

  defp set_payload(feed, new), do: Agent.update(feed.payload, fn _ -> new end)

  defp close_transport(feed), do: Agent.update(feed.gate, fn _ -> :closed end)

  defp decode_data("data: " <> rest), do: rest |> String.trim_trailing("\n") |> Jason.decode!()
end
