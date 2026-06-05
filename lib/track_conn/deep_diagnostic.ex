defmodule TrackConn.DeepDiagnostic do
  @moduledoc """
  Orchestrates the on-demand per-hop diagnostic: trace the path with `mtr`, then
  interpret it. Kept separate from the live monitor because it's slow (~10–15s)
  and user-triggered, not part of the continuous sweep.
  """
  alias TrackConn.PathReport
  alias TrackConn.Probes.Mtr

  @doc "Run a per-hop trace to `target` and return an analyzed report."
  def run(target, opts \\ []) do
    target
    |> Mtr.run(opts)
    |> PathReport.analyze()
  end

  @doc "Whether the deep diagnostic can run on this machine."
  def available?, do: Mtr.available?()
end
