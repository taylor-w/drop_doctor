defmodule TrackConn.Sweeper do
  @moduledoc """
  Runs one pass over the probe ladder: every probe concurrently, with a single
  bounded deadline so one hung probe can't stall the sweep (and therefore can't
  stall the monitor). A probe that times out or crashes yields a failure-shaped
  result for its kind rather than taking the whole sweep down with it.

  Pure with respect to the monitor: give it a ladder (and optionally a probe
  registry), get back `%{key => result}`. That makes the entire sweep testable
  with injected fake probes — no network required.
  """

  require Logger

  # hard ceiling for a whole sweep; individual probes have their own internal
  # timeouts well under this
  @deadline_ms 10_000

  @doc """
  Runs `ladder` (a list of `%{key:, kind:, target:, ...}` defs).

  Options:
    * `:probes` — kind => module registry (defaults to the configured one)
    * `:timeout` — overall deadline in ms
    * `:supervisor` — Task.Supervisor to run probes under
  """
  def run(ladder, opts \\ []) do
    registry = Keyword.get(opts, :probes, TrackConn.Probe.registry())
    timeout = Keyword.get(opts, :timeout, @deadline_ms)
    sup = Keyword.get(opts, :supervisor, TrackConn.ProbeSupervisor)

    pairs =
      Enum.map(ladder, fn defn ->
        task = Task.Supervisor.async_nolink(sup, fn -> probe(defn, registry) end)
        {defn, task}
      end)

    tasks = Enum.map(pairs, fn {_defn, task} -> task end)
    outcomes = Task.yield_many(tasks, timeout)

    pairs
    |> Enum.zip(outcomes)
    |> Map.new(fn {{defn, _task}, {task, outcome}} ->
      result =
        case outcome do
          {:ok, res} ->
            res

          {:exit, reason} ->
            Logger.warning("probe #{defn.key} crashed: #{inspect(reason)}")
            timeout_result(defn, "probe crashed")

          nil ->
            Task.shutdown(task, :brutal_kill)
            timeout_result(defn, "probe timed out")
        end

      {defn.key, Map.put(result, :def, defn)}
    end)
  end

  defp probe(%{kind: kind, target: target}, registry) do
    mod = Map.fetch!(registry, kind)
    mod.run(target, [])
  end

  defp timeout_result(%{kind: :ping}, msg),
    do: %{
      ok?: false,
      rtt_ms: nil,
      loss_pct: 100.0,
      sent: 0,
      received: 0,
      raw: msg,
      error: "timeout"
    }

  defp timeout_result(%{kind: :dns}, msg),
    do: %{ok?: false, ms: nil, address: nil, raw: msg, error: "timeout"}

  defp timeout_result(%{kind: :http}, msg),
    do: %{ok?: false, ms: nil, status: nil, bytes: 0, raw: msg, error: "timeout"}

  defp timeout_result(_, msg), do: %{ok?: false, raw: msg, error: "timeout"}
end
