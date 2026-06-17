defmodule TrackConn.DeepDiagnostic do
  @moduledoc """
  Orchestrates the on-demand per-hop diagnostic: trace the path with the OS's
  native tracer, then interpret it. Kept separate from the live monitor because
  it's slow (~10–15s) and user-triggered, not part of the continuous sweep.

  The tracer is chosen for the OS the binary is actually running on: `mtr` on
  Linux/macOS/WSL, and Windows' built-in `tracert` on the native Windows binary
  (where `mtr` doesn't exist). Both return the same hop-shaped result, so
  `PathReport` interprets either without special-casing.
  """
  alias TrackConn.PathReport
  alias TrackConn.Probes.{Mtr, Tracert}

  @doc "Run a per-hop trace to `target` and return an analyzed report."
  def run(target, opts \\ []) do
    target
    |> probe().run(opts)
    |> PathReport.analyze()
  end

  @doc "Whether the deep diagnostic can run on this machine."
  def available?, do: probe().available?()

  # The native path tracer for this OS. tracert ships with every Windows install;
  # everything else uses mtr.
  defp probe do
    case :os.type() do
      {:win32, _} -> Tracert
      _ -> Mtr
    end
  end
end
