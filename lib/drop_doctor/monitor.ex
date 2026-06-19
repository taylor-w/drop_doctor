defmodule DropDoctor.Monitor do
  @moduledoc """
  The heartbeat of the app. A supervised GenServer that paces sweeps, smooths
  them into a trustworthy verdict, persists, and broadcasts to dashboards.

  Design goals addressed here:

    * **Stays responsive (Tier 2).** Sweeps run in a supervised Task off the
      GenServer loop via `async_nolink`, so a slow or hung probe never blocks
      reads like `latest/0`. Reads return the last known verdict instantly —
      the UI never waits on the network.

    * **Trustworthy verdicts (Tier 1).** Keeps a rolling window of recent raw
      sweeps and diagnoses from their *median* (see `DropDoctor.Aggregate`), so a
      single noisy reading can't flip the light. The verdict carries `:samples`
      and `:provisional?` so the UI can be honest while the window fills.

    * **Bounded history (Tier 3).** Periodically prunes old rows, and broadcasts
      the persisted row so dashboards update from the message rather than
      re-querying the database every few seconds.

    * **Robust.** Runs under OTP supervision; a crashed sweep is logged and the
      next tick is scheduled normally.
  """
  use GenServer
  require Logger

  alias DropDoctor.{Aggregate, Diagnosis, Measurements, Sweeper, Targets}

  @topic "monitor"
  @default_interval :timer.seconds(5)
  @default_window 5
  # prune cadence and retention window
  @prune_every :timer.minutes(30)
  @retention_seconds 48 * 60 * 60

  # --- public API ---------------------------------------------------------

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @doc "Subscribe the caller to `{:sweep, verdict, sweep_row}` broadcasts."
  def subscribe(server \\ __MODULE__),
    do: Phoenix.PubSub.subscribe(DropDoctor.PubSub, topic(server))

  @doc "Most recent verdict — returns instantly, never blocks on the network."
  def latest(server \\ __MODULE__), do: GenServer.call(server, :latest)

  @doc "Trigger a sweep right now (async; result arrives via broadcast)."
  def sweep_now(server \\ __MODULE__), do: GenServer.cast(server, :sweep_now)

  @doc "Whether the periodic monitor is currently running."
  def running?(server \\ __MODULE__), do: GenServer.call(server, :running?)

  def pause(server \\ __MODULE__), do: GenServer.cast(server, :pause)
  def resume(server \\ __MODULE__), do: GenServer.cast(server, :resume)

  @doc """
  Remember the most recent deep (per-hop) trace so an exported report can
  include it. Deep traces are user-triggered and live only in the dashboard;
  stashing the latest here lets the report endpoint pick it up.
  """
  def put_deep(report, server \\ __MODULE__), do: GenServer.cast(server, {:put_deep, report})

  @doc "The most recent deep trace report, or `nil` if none has been run."
  def latest_deep(server \\ __MODULE__), do: GenServer.call(server, :latest_deep)

  @doc """
  Clean slate: forget the in-memory smoothing window and the stashed deep trace.
  Paired with `Measurements.reset/0` (which wipes the DB) so a reset doesn't
  leave the next few verdicts smoothed over already-deleted history.
  """
  def reset(server \\ __MODULE__), do: GenServer.cast(server, :reset)

  # --- callbacks ----------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      interval: Keyword.get(opts, :interval, @default_interval),
      window_size: Keyword.get(opts, :window_size, @default_window),
      persist: Keyword.get(opts, :persist, true),
      sweep_opts: Keyword.get(opts, :sweep_opts, []),
      topic: topic(opts[:name] || __MODULE__),
      window: [],
      latest: warming_verdict(),
      deep: nil,
      running: true,
      timer: nil,
      task: nil
    }

    if state.persist, do: Process.send_after(self(), :prune, @prune_every)
    {:ok, start_sweep(state)}
  end

  @impl true
  def handle_call(:latest, _from, state), do: {:reply, state.latest, state}
  def handle_call(:running?, _from, state), do: {:reply, state.running, state}
  def handle_call(:latest_deep, _from, state), do: {:reply, state.deep, state}

  @impl true
  def handle_cast(:sweep_now, state), do: {:noreply, start_sweep(state)}

  def handle_cast({:put_deep, report}, state), do: {:noreply, %{state | deep: report}}

  # Clean slate: drop the smoothing window and stashed trace. The live verdict
  # (`latest`) is kept so the banner keeps showing current health; it just goes
  # provisional again for the next few sweeps as the window refills.
  def handle_cast(:reset, state), do: {:noreply, %{state | window: [], deep: nil}}

  def handle_cast(:pause, state) do
    cancel_timer(state.timer)
    {:noreply, %{state | running: false, timer: nil}}
  end

  def handle_cast(:resume, %{running: false} = state),
    do: {:noreply, start_sweep(%{state | running: true})}

  def handle_cast(:resume, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state), do: {:noreply, start_sweep(state)}

  # sweep task finished successfully
  def handle_info({ref, raw_sweep}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = process_sweep(%{state | task: nil}, raw_sweep)
    {:noreply, schedule_tick(state)}
  end

  # sweep task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("sweep task crashed: #{inspect(reason)}")
    {:noreply, schedule_tick(%{state | task: nil})}
  end

  def handle_info(:prune, %{persist: true} = state) do
    case Measurements.prune(@retention_seconds) do
      n when n > 0 -> Logger.info("pruned #{n} old sweep(s)")
      _ -> :ok
    end

    Process.send_after(self(), :prune, @prune_every)
    {:noreply, state}
  end

  # stray messages from shutdown tasks
  def handle_info({ref, _}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # --- internals ----------------------------------------------------------

  # Start a sweep Task if we're running and none is in flight. Never blocks.
  defp start_sweep(%{running: true, task: nil} = state) do
    cancel_timer(state.timer)
    ladder = Targets.ladder()
    opts = state.sweep_opts

    task =
      Task.Supervisor.async_nolink(DropDoctor.ProbeSupervisor, fn -> Sweeper.run(ladder, opts) end)

    %{state | task: task, timer: nil}
  end

  defp start_sweep(state), do: state

  defp process_sweep(state, raw_sweep) do
    window = [raw_sweep | state.window] |> Enum.take(state.window_size)
    samples = length(window)

    verdict =
      window
      |> Aggregate.summarize()
      |> Diagnosis.analyze()
      |> Map.merge(%{samples: samples, provisional?: samples < state.window_size})

    row = maybe_persist(state, verdict)
    Phoenix.PubSub.broadcast(DropDoctor.PubSub, state.topic, {:sweep, verdict, row})

    %{state | window: window, latest: verdict}
  end

  defp maybe_persist(%{persist: true}, verdict) do
    case Measurements.record(verdict) do
      {:ok, row} ->
        row

      {:error, reason} ->
        Logger.warning("failed to persist sweep: #{inspect(reason)}")
        nil
    end
  end

  defp maybe_persist(_state, _verdict), do: nil

  defp schedule_tick(%{running: true} = state) do
    %{state | timer: Process.send_after(self(), :tick, state.interval)}
  end

  defp schedule_tick(state), do: state

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp topic(name), do: "#{@topic}:#{inspect(name)}"

  defp warming_verdict do
    %{
      status: :unknown,
      culprit: :none,
      headline: "Warming up…",
      detail: "Running the first measurements across your network path.",
      action: nil,
      evidence: [],
      segments: [],
      samples: 0,
      provisional?: true
    }
  end
end
