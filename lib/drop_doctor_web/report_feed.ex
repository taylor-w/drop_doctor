defmodule DropDoctorWeb.ReportFeed do
  @moduledoc """
  Transport-agnostic engine behind the live report's Server-Sent Events stream
  (`GET /report/live`).

  Split out of `ReportController` so the streaming behaviour is unit-testable
  without standing up an HTTP server (see `DropDoctorWeb.ReportFeedTest`). The
  controller stays a thin adapter: it clamps the window, subscribes the request
  process to the measurement topics, sets the SSE headers and hands a chunking
  `Plug.Conn` here.

  What the loop does:

    * **Coalesces** a burst of measurement broadcasts into a single render — a
      5s sweep often lands alongside several spike-sampling updates, and we want
      one render, not five.
    * **Diffs** before sending: only the report sections whose HTML actually
      changed go on the wire, so a quiet stream never re-ships the (potentially
      large) history table, and the per-render DB query is the only fixed cost.
    * **Heartbeats** when idle, which doubles as disconnect detection: the write
      fails once the client is gone, ending the request — and the process exit
      drops the PubSub subscriptions with it.
  """

  # Collapse a burst of broadcasts into one render. Bounds the per-viewer
  # render/query rate to ~1.3/s — the only cost that scales with how chatty the
  # monitors are. (Overridable per-run so tests can drive it deterministically.)
  @coalesce_ms 750

  # Idle keepalive *and* disconnect backstop: a comment line proves the stream
  # is alive, and its write fails once the client has gone — bounding how long a
  # vanished viewer lingers subscribed to roughly one heartbeat.
  @heartbeat_ms 20_000

  @typedoc "Opaque transport handle threaded through `:emit` (a `Plug.Conn` in production)."
  @type io :: term()
  @typedoc "Writes a frame; a non-`:ok` return means the client is gone."
  @type emit :: (io(), iodata() -> {:ok, io()} | {:error, term()})
  @typedoc "Renders the report's dynamic sections, keyed by DOM id."
  @type build :: (-> %{optional(String.t()) => iodata()})

  @doc """
  Run a `Plug.Conn`-backed SSE loop until the client disconnects, returning the
  final conn. Convenience wrapper that wires `:emit` to `Plug.Conn.chunk/2`; the
  conn must already be `send_chunked/2`. See `run/1` for the options.
  """
  def run_conn(conn, build_fun, opts \\ []) when is_function(build_fun, 0) do
    opts
    |> Keyword.merge(io: conn, emit: &Plug.Conn.chunk/2, build: build_fun)
    |> run()
  end

  @doc """
  Run the SSE loop until the client disconnects, returning the final `:io`.

  Required opts: `:io`, `:emit` (`#{inspect(__MODULE__)}.emit`), `:build`
  (`#{inspect(__MODULE__)}.build`). Optional: `:coalesce_ms`, `:heartbeat_ms`
  (timer overrides; default to this module's production values).

  The caller must have already subscribed the current process to the relevant
  measurement topics — this loop only matches the broadcast shapes
  (`{:sweep, _, _}` from `Monitor`, `{:stability, _, _}` from `SpikeMonitor`).
  """
  def run(opts) do
    state = %{
      io: Keyword.fetch!(opts, :io),
      emit: Keyword.fetch!(opts, :emit),
      build: Keyword.fetch!(opts, :build),
      coalesce_ms: Keyword.get(opts, :coalesce_ms, @coalesce_ms),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, @heartbeat_ms),
      armed: false,
      sent: %{}
    }

    # Initial snapshot: the page may have gone stale between its own render and
    # this subscription, so send the full set once; only diffs flow after.
    case flush(state) do
      {:ok, state} -> loop(state)
      {:error, _gone} -> state.io
    end
  end

  # Block on measurement broadcasts. A relevant one arms a single coalesced
  # flush; unrelated messages are ignored; an idle stretch heartbeats. Any failed
  # write means the client is gone — we return `io`, ending the request, and the
  # process exit unsubscribes us from PubSub.
  defp loop(state) do
    receive do
      {:sweep, _verdict, _row} ->
        arm(state)

      {:stability, _key, _stats} ->
        arm(state)

      :dd_flush ->
        case flush(state) do
          {:ok, state} -> loop(state)
          {:error, _gone} -> state.io
        end

      _other ->
        loop(state)
    after
      state.heartbeat_ms ->
        case emit(state, ": keepalive\n\n") do
          {:ok, state} -> loop(state)
          {:error, _gone} -> state.io
        end
    end
  end

  # First relevant broadcast since the last render schedules the coalesced flush;
  # further broadcasts inside the window are absorbed (timer already pending).
  defp arm(%{armed: true} = state), do: loop(state)

  defp arm(%{armed: false} = state) do
    Process.send_after(self(), :dd_flush, state.coalesce_ms)
    loop(%{state | armed: true})
  end

  # Render the report and stream only the sections whose HTML changed since the
  # last send. When nothing moved we skip the write entirely (the heartbeat stays
  # responsible for liveness/disconnect), so an idle-but-armed window costs one
  # query and zero bytes.
  defp flush(state) do
    payload = state.build.()
    changed = changed_slots(state.sent, payload)

    if map_size(changed) == 0 do
      {:ok, %{state | armed: false}}
    else
      case emit(state, ["data: ", Jason.encode!(changed), "\n\n"]) do
        {:ok, state} -> {:ok, %{state | armed: false, sent: payload}}
        {:error, _} = gone -> gone
      end
    end
  end

  @doc """
  The subset of `next` whose value differs from `prev` (new or changed keys).
  The report's slot set is fixed, so sections never disappear — only change —
  which is why a client can apply a partial map by id and leave the rest as-is.
  """
  def changed_slots(prev, next) do
    for {id, html} <- next, Map.get(prev, id) != html, into: %{}, do: {id, html}
  end

  defp emit(state, data) do
    case state.emit.(state.io, data) do
      {:ok, io} -> {:ok, %{state | io: io}}
      {:error, _} = gone -> gone
    end
  end
end
