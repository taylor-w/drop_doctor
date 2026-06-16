defmodule TrackConn.SpikeMonitor do
  @moduledoc """
  Continuous, high-rate stability sampler for one host.

  The 5-second sweep (`TrackConn.Monitor`) answers "whose fault is the outage?"
  and deliberately smooths out blips. That smoothing means a brief lag spike in
  the gap between sweeps is never seen — which is exactly what ruins an online
  game. This GenServer closes that gap: it runs **one long-lived `ping` process**
  per host, reads its per-packet replies as they stream in, keeps a rolling buffer
  of the most recent samples, and continuously derives jitter / spikes / tail
  latency / brief loss via `TrackConn.Stability`.

  ## Why a resident process, not repeated bursts

  An earlier version spawned a fresh `ping` every ~2s. That made the *measured*
  RTT sensitive to host CPU scheduling: under load (e.g. mid-game) the short-lived
  process was descheduled between sending a packet and reading its reply and
  reported latency the network never saw — inflating "local" spikes during exactly
  the moments the user cares about. A single resident process stays warm, removes
  the per-burst startup, and is lighter on the host, so the samples reflect the
  wire rather than the scheduler. See `TrackConn.Probes.Ping.stream/3`.

  Samples are folded into the window in small batches (one `:flush` worth at a
  time) so event detection and broadcasts keep the same cadence as before. One
  instance runs per monitored host (the router and the open internet); live stats
  are broadcast on `topic/0` as `{:stability, key, stats}`.
  """
  use GenServer
  require Logger

  alias TrackConn.{Aggregate, Measurements, Probes.Ping, Stability}

  @topic "stability"
  # Keep ~the last minute of samples (≈5/s × 60s). Bounds memory and defines the
  # window every stat is computed over.
  @window 300
  # Fold + recompute + broadcast once this many fresh samples have streamed in
  # (≈ every 2s at 5 samples/sec) — the cadence at which we detect a spike/loss
  # event and push updated stats to dashboards.
  @flush 10
  # Default per-packet spacing (Unix `-i`, seconds). Windows ignores it (~1s).
  @interval 0.2
  # Back off this long before restarting after the ping process exits, so a host
  # that's briefly unresolvable doesn't make us spin.
  @retry_ms 1_000
  # If the ping process dies sooner than this after starting, treat it as the OS
  # refusing our (sub-second) interval — see `maybe_raise_floor/2`.
  @fast_death_ms 1_500

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

  @doc "Drop the rolling sample buffer for one host (clean slate for live stats)."
  def reset(key), do: GenServer.cast(server_name(key), :reset)

  @doc "Reset every host monitor's live buffer — paired with a history wipe."
  def reset_all, do: Enum.each(@hosts, &reset/1)

  @doc "The registered process name for a host key."
  def server_name(key), do: :"#{__MODULE__}.#{key}"

  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, opts, name: server_name(key))
  end

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :host)
    # A host may have several interchangeable candidates (the open-internet
    # anchors). We start on the first and, if more were given, asynchronously
    # switch to the first one that actually answers — so the continuous sampler
    # tracks the same reachable target the 5s reachability probe uses, instead of
    # flat-lining at 100% loss on an anchor this network happens to filter.
    hosts = Keyword.get(opts, :hosts, [host])

    state = %{
      key: Keyword.fetch!(opts, :key),
      host: hd(hosts),
      hosts: hosts,
      # Reachability check used to pick a live anchor; injectable for tests.
      reach_fun: Keyword.get(opts, :reach_fun, &reachable?/1),
      interval: Keyword.get(opts, :interval, @interval),
      # Raised to 1.0 if the OS rejects sub-second pings (macOS/some hardened
      # Linux for non-root); the effective interval is max(interval, floor).
      interval_floor: 0.0,
      window: Keyword.get(opts, :window, @window),
      flush: Keyword.get(opts, :count, @flush),
      # Injectable so the sampling loop can be unit-tested without real pings.
      stream_fun: Keyword.get(opts, :stream_fun, &Ping.stream/3),
      # Persist detected spike/loss events (off in tests, which have no DB sandbox).
      persist: Keyword.get(opts, :persist, true),
      running: true,
      samples: [],
      pending: [],
      stats: Stability.empty(),
      reader: nil,
      reader_ref: nil,
      reader_started_ms: nil
    }

    if length(hosts) > 1, do: send(self(), :select_host)
    {:ok, start_stream(state)}
  end

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}
  def handle_call(:running?, _from, state), do: {:reply, state.running, state}

  @impl true
  def handle_cast(:pause, state), do: {:noreply, stop_stream(%{state | running: false})}
  def handle_cast(:resume, state), do: {:noreply, start_stream(%{state | running: true})}

  # Clean slate: empty the rolling buffer and any half-collected batch, and
  # broadcast empty stats so any live view drops back to "sampling…". The stream
  # keeps running.
  def handle_cast(:reset, state) do
    stats = Stability.empty()
    Phoenix.PubSub.broadcast(TrackConn.PubSub, @topic, {:stability, state.key, stats})
    {:noreply, %{state | samples: [], pending: [], stats: stats}}
  end

  @impl true
  # A line from the *current* reader: parse it into a sample and fold in.
  def handle_info({:stream_line, reader, line}, %{reader: reader} = state) do
    {:noreply, ingest(state, Ping.parse_stream_line(line))}
  end

  # A line from a reader we've already replaced/stopped — ignore.
  def handle_info({:stream_line, _stale, _line}, state), do: {:noreply, state}

  # The ping process ended. The reader's :DOWN (below) drives the restart; this is
  # informational, so we just drop it.
  def handle_info({:stream_down, _reader, _reason}, state), do: {:noreply, state}

  # Our reader died (ping exited or crashed). Restart shortly if still running,
  # raising the interval floor first if it died suspiciously fast.
  def handle_info({:DOWN, ref, :process, pid, reason}, %{reader_ref: ref, reader: pid} = state) do
    state = maybe_raise_floor(%{state | reader: nil, reader_ref: nil}, reason)
    if state.running, do: Process.send_after(self(), :restart_stream, @retry_ms)
    {:noreply, state}
  end

  def handle_info(:restart_stream, state), do: {:noreply, start_stream(state)}

  # Probe the candidate hosts off-process (a reachability check can block ~1s/host)
  # and report back the first that answers. Done once, shortly after boot.
  def handle_info(:select_host, state) do
    parent = self()
    hosts = state.hosts
    reach = state.reach_fun
    spawn(fn -> if h = Enum.find(hosts, reach), do: send(parent, {:host_selected, h}) end)
    {:noreply, state}
  end

  # Already sampling the chosen host — nothing to do.
  def handle_info({:host_selected, host}, %{host: host} = state), do: {:noreply, state}

  # Switch the resident stream to the reachable anchor and start its window fresh.
  def handle_info({:host_selected, host}, %{running: true} = state) do
    state =
      state
      |> stop_stream()
      |> Map.merge(%{host: host, samples: [], pending: [], stats: Stability.empty()})
      |> start_stream()

    Phoenix.PubSub.broadcast(TrackConn.PubSub, @topic, {:stability, state.key, state.stats})
    Logger.info("spike monitor (#{state.key}): sampling #{host} — first reachable anchor")
    {:noreply, state}
  end

  def handle_info({:host_selected, host}, state), do: {:noreply, %{state | host: host}}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- internals ----------------------------------------------------------

  defp start_stream(%{running: true, reader: nil} = state) do
    interval = max(state.interval_floor, state.interval)
    reader = state.stream_fun.(self(), state.host, interval: interval)
    ref = Process.monitor(reader)
    %{state | reader: reader, reader_ref: ref, reader_started_ms: now_ms()}
  end

  # Paused, or a reader already running — leave it alone.
  defp start_stream(state), do: state

  defp stop_stream(%{reader: nil} = state), do: state

  defp stop_stream(%{reader: reader, reader_ref: ref} = state) do
    if ref, do: Process.demonitor(ref, [:flush])
    Process.exit(reader, :kill)
    %{state | reader: nil, reader_ref: nil}
  end

  defp ingest(state, :ignore), do: state

  defp ingest(state, sample) do
    pending = [sample | state.pending]

    if length(pending) >= state.flush do
      flush(%{state | pending: pending})
    else
      %{state | pending: pending}
    end
  end

  # Fold one batch of fresh samples into the window: detect spike/loss events
  # against the *prior* window's median (what "normal" was before this batch),
  # then recompute and broadcast stats.
  defp flush(state) do
    batch = Enum.reverse(state.pending)
    times = for {:ok, ms} <- batch, do: ms
    result = %{times: times, sent: length(batch), received: length(times)}

    baseline = Aggregate.median(for {:ok, ms} <- state.samples, do: ms)
    log_events(state, Stability.burst_events(baseline, result))

    samples = Enum.take(state.samples ++ batch, -state.window)
    stats = Stability.summarize(samples)
    Phoenix.PubSub.broadcast(TrackConn.PubSub, @topic, {:stability, state.key, stats})

    %{state | pending: [], samples: samples, stats: stats}
  end

  defp log_events(%{persist: false}, _events), do: :ok
  defp log_events(_state, []), do: :ok

  defp log_events(state, events) do
    now = DateTime.utc_now()

    for event <- events do
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
  # users, so the ping exits almost immediately. If the reader died well under a
  # second after starting and we're still below the 1s floor, raise the floor so
  # every later attempt respects it — still gap-free, just coarser.
  defp maybe_raise_floor(%{interval_floor: floor, reader_started_ms: started} = state, _reason)
       when floor < 1.0 and is_integer(started) do
    if now_ms() - started < @fast_death_ms do
      Logger.info(
        "spike monitor (#{state.key}): ping exited immediately — falling back to 1s interval"
      )

      %{state | interval_floor: 1.0}
    else
      state
    end
  end

  defp maybe_raise_floor(state, _reason), do: state

  # A quick "does this host answer ICMP at all" check for anchor selection.
  defp reachable?(host), do: match?(%{ok?: true}, Ping.run(host, count: 2, timeout: 1))

  defp now_ms, do: System.monotonic_time(:millisecond)
end
