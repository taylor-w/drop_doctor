defmodule TrackConn.SpikeMonitor do
  @moduledoc """
  Continuous, high-rate stability sampler for one host.

  The 5-second sweep (`TrackConn.Monitor`) answers "whose fault is the outage?"
  and deliberately smooths out blips. That smoothing means a brief lag spike in
  the ~4s gap between sweeps is never seen — which is exactly what ruins an
  online game. This GenServer closes that gap: it runs `ping` in **back-to-back
  short bursts** (~5 samples/second, no meaningful gaps), keeps a rolling buffer
  of the most recent samples, and continuously derives jitter / spikes / tail
  latency / brief loss via `TrackConn.Stability`.

  We use repeated short bursts rather than one long-running `ping` process on
  purpose: each burst self-terminates (no orphaned OS processes to babysit, no
  extra dependency), and it reuses the same `System.cmd` path as the rest of the
  app. The only gap is the sub-millisecond hand-off between bursts.

  One instance runs per monitored host (the router and the open internet). Live
  stats are broadcast on `topic/0` as `{:stability, key, stats}`.
  """
  use GenServer
  require Logger

  alias TrackConn.{Aggregate, Measurements, Probes.Ping, Stability}

  @topic "stability"
  # Keep ~the last minute of samples (≈5/s × 60s). Bounds memory and defines the
  # window every stat is computed over.
  @window 300
  @burst_count 10
  # Back off this long before retrying after a burst error (e.g. host briefly
  # unresolvable), so we don't spin.
  @retry_ms 1_000

  @doc "PubSub topic carrying `{:stability, key, stats}` updates."
  def topic, do: @topic

  # The host keys started by the application supervisor.
  @hosts [:router, :internet]

  @doc "Latest stats for a monitored host key (`:router` / `:internet`)."
  def stats(key), do: GenServer.call(server_name(key), :stats)

  @doc "Whether the given monitor is actively sampling."
  def running?(key), do: GenServer.call(server_name(key), :running?)

  @doc "Pause / resume continuous sampling for one host (no-op if not started)."
  def pause(key), do: GenServer.cast(server_name(key), :pause)
  def resume(key), do: GenServer.cast(server_name(key), :resume)

  @doc "Pause / resume every host monitor — kept in lock-step with the sweep Monitor."
  def pause_all, do: Enum.each(@hosts, &pause/1)
  def resume_all, do: Enum.each(@hosts, &resume/1)

  @doc "The registered process name for a host key."
  def server_name(key), do: :"#{__MODULE__}.#{key}"

  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, opts, name: server_name(key))
  end

  @impl true
  def init(opts) do
    state = %{
      key: Keyword.fetch!(opts, :key),
      host: Keyword.fetch!(opts, :host),
      interval: Keyword.get(opts, :interval, 0.2),
      window: Keyword.get(opts, :window, @window),
      count: Keyword.get(opts, :count, @burst_count),
      # Injectable so the sampling loop can be unit-tested without real pings.
      burst_fun: Keyword.get(opts, :burst_fun, &Ping.burst/2),
      # Persist detected spike/loss events (off in tests, which have no DB sandbox).
      persist: Keyword.get(opts, :persist, true),
      running: true,
      samples: [],
      stats: Stability.empty(),
      task: nil
    }

    {:ok, start_burst(state)}
  end

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}
  def handle_call(:running?, _from, state), do: {:reply, state.running, state}

  @impl true
  def handle_cast(:pause, state), do: {:noreply, %{state | running: false}}
  def handle_cast(:resume, state), do: {:noreply, start_burst(%{state | running: true})}

  @impl true
  def handle_info(:burst, state), do: {:noreply, start_burst(state)}

  # Burst finished: fold its samples into the rolling window, recompute, emit,
  # and immediately kick off the next burst (continuous coverage).
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      %{state | task: nil}
      |> maybe_relax_interval(result)
      |> absorb(result)

    {:noreply, start_burst(state)}
  end

  # Burst crashed: retry shortly without touching the buffer.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("spike burst (#{state.key}) crashed: #{inspect(reason)}")
    Process.send_after(self(), :burst, @retry_ms)
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- internals ----------------------------------------------------------

  defp start_burst(%{task: nil, running: true} = state) do
    %{host: host, count: count, interval: interval, burst_fun: burst_fun} = state

    task =
      Task.Supervisor.async_nolink(TrackConn.ProbeSupervisor, fn ->
        burst_fun.(host, count: count, interval: interval)
      end)

    %{state | task: task}
  end

  # Paused, or a burst already in flight — don't start another.
  defp start_burst(state), do: state

  defp absorb(state, %{times: times, received: received, sent: sent} = result) do
    # Detect events against the *prior* buffer's median (what "normal" was before
    # this burst), then fold the new samples in.
    baseline = Aggregate.median(for {:ok, ms} <- state.samples, do: ms)
    log_events(state, baseline, result)

    # Replies become {:ok, rtt}; un-replied packets become :loss markers.
    new = Enum.map(times, &{:ok, &1}) ++ List.duplicate(:loss, max(sent - received, 0))
    samples = Enum.take(state.samples ++ new, -state.window)
    stats = Stability.summarize(samples)

    Phoenix.PubSub.broadcast(TrackConn.PubSub, @topic, {:stability, state.key, stats})
    %{state | samples: samples, stats: stats}
  end

  defp log_events(%{persist: false}, _baseline, _result), do: :ok

  defp log_events(state, baseline, result) do
    now = DateTime.utc_now()

    for event <- Stability.burst_events(baseline, result) do
      event
      |> Map.merge(%{
        kind: to_string(event.kind),
        occurred_at: now,
        segment: to_string(state.key),
        host: state.host
      })
      |> Measurements.record_spike_event()
    end

    :ok
  end

  # macOS (and some hardened Linux) reject sub-second intervals for non-root
  # users. If a burst comes back empty *because of that* (not a real outage),
  # fall back to a 1s interval and keep going — still gap-free, just coarser.
  defp maybe_relax_interval(%{interval: i} = state, %{times: [], raw: raw}) when i < 1.0 do
    if raw =~ ~r/too short|not permitted|Operation not permitted/i do
      Logger.info(
        "spike monitor (#{state.key}): sub-second ping not permitted, using 1s interval"
      )

      %{state | interval: 1.0}
    else
      state
    end
  end

  defp maybe_relax_interval(state, _result), do: state
end
