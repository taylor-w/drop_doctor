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

  alias TrackConn.{Aggregate, Measurements, Probes.Ping, Probes.TcpStream, Stability}

  @topic "stability"
  # Keep ~the last minute of samples (≈5/s × 60s). Bounds memory and defines the
  # window every stat is computed over.
  @window 300
  # Fold + recompute + broadcast once this many fresh samples have streamed in
  # (≈ every 2s at 5 samples/sec) — the cadence at which we detect a spike/loss
  # event and push updated stats to dashboards.
  @flush 10
  # In TCP-fallback mode samples arrive at 1/s, so a 10-sample flush would freeze
  # the Live card and delay detection ~10s. Flush every 2 there to keep the same
  # ~2s cadence the ICMP path has.
  @tcp_flush 2
  # Default per-packet spacing (Unix `-i`, seconds). Windows ignores it (~1s).
  @interval 0.2
  # Back off this long before restarting after the ping process exits, so a host
  # that's briefly unresolvable doesn't make us spin.
  @retry_ms 1_000
  # If the ping process dies sooner than this after starting, treat it as the OS
  # refusing our (sub-second) interval — see `maybe_raise_floor/2`.
  @fast_death_ms 1_500
  # Corroboration judges the alt anchor with the *same* spike rule the detector
  # uses (`Stability.spike?/2`) so detection and corroboration can never disagree
  # about what counts as a spike — see `alt_verdict/2`.
  # TCP-fallback sampling is deliberately slow (1/s, not the ICMP 5/s): a TCP
  # connect is far heavier than an echo, so hammering a router with it is both
  # rude and self-defeating — the rare slow SYN it provokes looks like loss.
  @tcp_interval 1.0

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
      # A second reachable anchor (a *different* provider) used to corroborate
      # internet spikes: if it degraded at the same moment the problem is
      # provider-wide (your ISP); if it stayed clean it's just that one route.
      # Picked alongside the primary; nil when only one anchor is reachable.
      alt_host: nil,
      # Reachability check used to pick a live anchor; injectable for tests.
      reach_fun: Keyword.get(opts, :reach_fun, &reachable?/1),
      # TCP ports to fall back to when the host never answers ICMP (e.g. a
      # router that drops ping but accepts DNS/web-admin connections). Empty =
      # ICMP only. `probe_mode` flips to :tcp once we give up on ICMP.
      tcp_ports: Keyword.get(opts, :tcp_ports, []),
      probe_mode: :icmp,
      # Has this host *ever* answered ICMP this session? Only hosts that never
      # have are switched to the TCP sampler — so a transient outage on a normally
      # ICMP-answering anchor can't permanently downgrade it to coarse TCP.
      icmp_seen: false,
      # The most recent numeric window median. Used as the detection baseline when
      # the live window has gone fully silent during a sustained outage, so ongoing
      # loss/spikes are still recorded instead of vanishing with "normal".
      last_baseline: nil,
      # True while a corroboration probe is in flight, so we never spawn a second
      # (no pile-up under sustained spikes); events seen meanwhile record as `nil`.
      corroborating: false,
      interval: Keyword.get(opts, :interval, @interval),
      # Raised to 1.0 if the OS rejects sub-second pings (macOS/some hardened
      # Linux for non-root); the effective interval is max(interval, floor).
      interval_floor: 0.0,
      window: Keyword.get(opts, :window, @window),
      flush: Keyword.get(opts, :count, @flush),
      # Injectable so the sampling loop can be unit-tested without real pings.
      stream_fun: Keyword.get(opts, :stream_fun, &Ping.stream/3),
      # The streamer to swap in once we give up on ICMP; injectable for tests.
      tcp_stream_fun: Keyword.get(opts, :tcp_stream_fun, &TcpStream.stream/3),
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
  # and report back which answered, in preference order. Done once, after boot.
  def handle_info(:select_host, state) do
    parent = self()
    hosts = state.hosts
    reach = state.reach_fun
    spawn(fn -> send(parent, {:hosts_selected, Enum.filter(hosts, reach)}) end)
    {:noreply, state}
  end

  # The first reachable anchor becomes the primary the resident stream samples;
  # the next reachable one (a different provider) becomes the corroborator.
  def handle_info({:hosts_selected, reachable}, state) do
    primary = List.first(reachable) || state.host
    alt = Enum.find(reachable, &(&1 != primary))
    state = %{state | alt_host: alt}

    if primary != state.host and state.running do
      state =
        state
        |> stop_stream()
        |> Map.merge(%{host: primary, samples: [], pending: [], stats: Stability.empty()})
        |> start_stream()

      Phoenix.PubSub.broadcast(TrackConn.PubSub, @topic, {:stability, state.key, state.stats})

      Logger.info(
        "spike monitor (#{state.key}): sampling #{primary} (corroborate: #{alt || "—"})"
      )

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # A corroboration task finished (or crashed — the task's `after` always fires):
  # free the slot so the next flush's internet events can be corroborated again.
  def handle_info(:corroboration_done, state), do: {:noreply, %{state | corroborating: false}}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- internals ----------------------------------------------------------

  defp start_stream(%{running: true, reader: nil} = state) do
    interval = stream_interval(state)
    # `ports` is only used by the TCP streamer; Ping.stream ignores it.
    reader = state.stream_fun.(self(), state.host, interval: interval, ports: state.tcp_ports)
    ref = Process.monitor(reader)
    %{state | reader: reader, reader_ref: ref, reader_started_ms: now_ms()}
  end

  # Paused, or a reader already running — leave it alone.
  defp start_stream(state), do: state

  defp stream_interval(%{probe_mode: :tcp}), do: @tcp_interval
  defp stream_interval(state), do: max(state.interval_floor, state.interval)

  defp stop_stream(%{reader: nil} = state), do: state

  defp stop_stream(%{reader: reader, reader_ref: ref} = state) do
    if ref, do: Process.demonitor(ref, [:flush])
    Process.exit(reader, :kill)
    %{state | reader: nil, reader_ref: nil}
  end

  defp ingest(state, :ignore), do: state

  defp ingest(state, sample) do
    state = mark_icmp_seen(state, sample)
    pending = [sample | state.pending]

    if length(pending) >= flush_threshold(state) do
      flush(%{state | pending: pending})
    else
      %{state | pending: pending}
    end
  end

  # Record the first real ICMP reply; once set it never clears, so a host that has
  # proven it answers ICMP is never given up on in favour of TCP (see
  # `maybe_switch_to_tcp/1`). Only meaningful in ICMP mode.
  defp mark_icmp_seen(%{icmp_seen: false, probe_mode: :icmp} = state, {:ok, _}),
    do: %{state | icmp_seen: true}

  defp mark_icmp_seen(state, _sample), do: state

  defp flush_threshold(%{probe_mode: :tcp}), do: @tcp_flush
  defp flush_threshold(state), do: state.flush

  # Fold one batch of fresh samples into the window: detect spike/loss events
  # against the *prior* window's median (what "normal" was before this batch),
  # then recompute and broadcast stats.
  defp flush(state) do
    batch = Enum.reverse(state.pending)
    times = for {:ok, ms} <- batch, do: ms
    result = %{times: times, sent: length(batch), received: length(times)}

    # Detect against the most recent *known* normal: the current window's median,
    # or — when the window has gone fully silent in a sustained outage — the last
    # numeric baseline we saw, so ongoing loss/spikes are still recorded instead
    # of disappearing the moment "normal" ages out of the window.
    window_baseline = Aggregate.median(for {:ok, ms} <- state.samples, do: ms)
    baseline = window_baseline || state.last_baseline

    state =
      log_events(
        state,
        loggable_events(state, Stability.burst_events(baseline, result)),
        baseline
      )

    last_baseline = if is_number(window_baseline), do: window_baseline, else: state.last_baseline

    samples = Enum.take(state.samples ++ batch, -state.window)
    stats = Map.put(Stability.summarize(samples), :mode, state.probe_mode)
    Phoenix.PubSub.broadcast(TrackConn.PubSub, @topic, {:stability, state.key, stats})

    maybe_switch_to_tcp(%{
      state
      | pending: [],
        samples: samples,
        stats: stats,
        last_baseline: last_baseline
    })
  end

  # How many consecutive ICMP-silent samples before we conclude the host drops
  # ping and switch the resident sampler to TCP connects (~6s at 5 samples/sec).
  @icmp_giveup 30

  # If the host has answered no ICMP at all after a warm-up and we have TCP ports
  # to try, swap the ping stream for a TCP-connect stream so a ping-silent router
  # still yields live latency/jitter instead of a permanent "no reply".
  # Only a host that has *never* answered ICMP this session is switched to TCP —
  # the `icmp_seen: false` head guarantees a normally-answering anchor that hits a
  # transient outage keeps trying ICMP (and recovers when it returns) instead of
  # being permanently downgraded to coarse 1/s TCP connect-time sampling.
  defp maybe_switch_to_tcp(%{probe_mode: :icmp, tcp_ports: [_ | _], icmp_seen: false} = state) do
    if length(state.samples) >= @icmp_giveup and icmp_silent?(state.samples) do
      Logger.info("spike monitor (#{state.key}): #{state.host} drops ICMP — sampling over TCP")

      state
      |> stop_stream()
      |> Map.merge(%{
        stream_fun: state.tcp_stream_fun,
        probe_mode: :tcp,
        samples: [],
        pending: [],
        last_baseline: nil,
        stats: Map.put(Stability.empty(), :mode, :tcp)
      })
      |> start_stream()
    else
      state
    end
  end

  defp maybe_switch_to_tcp(state), do: state

  defp icmp_silent?(samples), do: not Enum.any?(samples, &match?({:ok, _}, &1))

  @doc """
  Filters which detected events are worth recording for the current probe mode.
  In TCP-fallback mode a "loss" is a connect that didn't finish the handshake in
  time — a retransmit-and-recover blip, not packet loss the user would feel — so
  it's dropped (logging it is noise, and alarming in an ISP report); genuine
  TCP-unreachability is caught by the 5s sweep, and real latency spikes still
  log. ICMP mode keeps everything. Public for unit testing.
  """
  def loggable_events(%{probe_mode: :tcp}, events),
    do: Enum.reject(events, &(&1.kind == :loss))

  def loggable_events(_state, events), do: events

  defp log_events(%{persist: false} = state, _events, _baseline), do: state
  defp log_events(state, [], _baseline), do: state

  # Internet events are corroborated against the alternate anchor before they're
  # recorded. The probe (≈3s) and the DB writes run in a *supervised* task off the
  # GenServer so sampling is never blocked and a crash is visible/cleaned up. Only
  # one corroboration runs at a time (`corroborating: false` head): while one is in
  # flight, later events record immediately with `nil` rather than spawning a
  # second probe — so the tasks can't pile up under a sustained disturbance and no
  # event is ever dropped.
  defp log_events(
         %{key: :internet, alt_host: alt, corroborating: false} = state,
         events,
         baseline
       )
       when is_binary(alt) do
    parent = self()
    base = event_base(state)

    Task.Supervisor.start_child(TrackConn.ProbeSupervisor, fn ->
      try do
        corroborated = corroborate(alt, baseline)
        Enum.each(events, &record_event(&1, base, corroborated))
      after
        send(parent, :corroboration_done)
      end
    end)

    %{state | corroborating: true}
  end

  defp log_events(state, events, _baseline) do
    base = event_base(state)
    Enum.each(events, &record_event(&1, base, nil))
    state
  end

  defp event_base(state),
    do: %{occurred_at: DateTime.utc_now(), segment: to_string(state.key), host: state.host}

  defp record_event(event, base, corroborated) do
    event
    |> Map.merge(base)
    |> Map.merge(%{kind: to_string(event.kind), corroborated: corroborated})
    |> Measurements.record_spike_event()
  end

  # Probe the alternate anchor, then judge it with `alt_verdict/2`.
  defp corroborate(alt, baseline), do: alt_verdict(Ping.run(alt, count: 3, timeout: 1), baseline)

  @doc """
  Given the alternate anchor's ping result and the primary's baseline, decide
  whether it corroborates the spike. Public for unit testing.

    * `true`  — it lost packets or spiked too → the fault is provider-wide (ISP)
    * `false` — it stayed clean → just this one route degraded, not your whole ISP
    * `nil`   — it didn't answer at all → can't corroborate either way
  """
  def alt_verdict(res, baseline) do
    cond do
      # Loss first: a total-loss result has `rtt_ms: nil`, so checking reachability
      # before loss (the old order) made this branch dead and mislabelled a genuine
      # both-providers-down outage as "couldn't corroborate".
      is_number(res[:loss_pct]) and res[:loss_pct] > 0 -> true
      not is_number(res[:rtt_ms]) -> nil
      Stability.spike?(res[:max_rtt_ms], baseline) -> true
      true -> false
    end
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
