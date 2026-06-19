defmodule DropDoctor.Probes.Mtr do
  @moduledoc """
  Per-hop path measurement via `mtr` (My TraceRoute) in JSON report mode.

  Where the ladder probes answer *which layer* is at fault, this answers
  *exactly which hop*. `mtr --report --json -c N <target>` sends N rounds of
  probes and reports per-hop loss and latency, with reverse-DNS names so the
  user can literally see their ISP's routers in the path.

  This is an on-demand "deep diagnostic", not part of the 5s loop — it takes
  ~10–15s. It runs unprivileged on Linux/macOS/WSL. On systems without `mtr`
  it returns a friendly, non-crashing error.
  """

  @default_cycles 10

  @doc "True if the `mtr` binary is available on this machine."
  def available?, do: System.find_executable("mtr") != nil

  @doc """
  Traces the path to `target`. Returns:

      %{ok?: boolean, target: String.t(), hops: [hop], raw: String.t(), error: String.t() | nil}

  where each hop is `%{count, host, loss_pct, sent, last, avg, best, worst, stdev}`.
  """
  def run(target, opts \\ []) do
    cycles = Keyword.get(opts, :cycles, @default_cycles)
    # mtr self-terminates after `cycles` rounds, but guard against a hung
    # resolver with an outer timeout.
    timeout = Keyword.get(opts, :timeout, cycles * 3_000 + 10_000)

    cond do
      not available?() ->
        error(target, "mtr is not installed", install_hint())

      true ->
        task = Task.async(fn -> exec(target, cycles) end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> error(target, "timeout", "mtr did not finish in #{timeout}ms")
        end
    end
  end

  defp exec(target, cycles) do
    args = ["--report", "--json", "-c", to_string(cycles), target]

    case System.cmd("mtr", args, stderr_to_stdout: true) do
      {out, 0} -> parse(out, target)
      {out, _code} -> error(target, "mtr exited non-zero", out)
    end
  rescue
    e -> error(target, "exception", Exception.message(e))
  end

  @doc "Parses mtr `--json` output into the hop list. Public for testing."
  def parse(out, target) do
    case Jason.decode(out) do
      {:ok, %{"report" => %{"hubs" => hubs}}} ->
        %{ok?: true, target: target, hops: Enum.map(hubs, &parse_hop/1), raw: out, error: nil}

      _ ->
        error(target, "could not parse mtr output", out)
    end
  end

  defp parse_hop(h) do
    %{
      count: h["count"],
      host: h["host"],
      loss_pct: h["Loss%"] || 0.0,
      sent: h["Snt"] || 0,
      last: h["Last"],
      avg: h["Avg"],
      best: h["Best"],
      worst: h["Wrst"],
      stdev: h["StDev"]
    }
  end

  defp error(target, err, raw),
    do: %{ok?: false, target: target, hops: [], raw: raw, error: err}

  defp install_hint do
    "Install mtr: Linux `sudo apt install mtr` / macOS `brew install mtr` / Windows: use WinMTR."
  end
end
