defmodule DropDoctor.Format do
  @moduledoc """
  Shared display formatters for the dashboard and the exported report. Keeping
  them in one place means a tweak to how a speed or a latency is rendered (extra
  decimal, a unit, the em-dash placeholder) changes both surfaces at once — a
  live dashboard and the PDF a user hands their ISP can't be allowed to disagree
  on the same number.
  """

  @doc ~S|A megabit/s figure to one decimal, e.g. `"94.2"`; `"—"` for nil/non-numbers.|
  def mbps(n) when is_number(n), do: "#{Float.round(n / 1, 1)}"
  def mbps(_), do: "—"

  @doc ~S|A millisecond figure to one decimal with its unit, e.g. `"18.0ms"`; `"—"` otherwise.|
  def ms(n) when is_number(n), do: "#{Float.round(n / 1, 1)}ms"
  def ms(_), do: "—"
end
