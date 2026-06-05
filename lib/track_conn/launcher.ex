defmodule TrackConn.Launcher do
  @moduledoc """
  Opens the dashboard in the user's default browser right after boot.

  This exists for the packaged "double-click" binary: a non-technical user
  launches the app and should land on the UI without knowing to type a URL.

  It's added to the supervision tree *after* the Endpoint, so by the time this
  starts the HTTP server is already accepting connections. Opening the browser
  is strictly best-effort — if no opener is available (headless box, locked-down
  WSL, etc.) we just log the URL and carry on. It never blocks or crashes boot.
  """
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {:ok, nil, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    url = dashboard_url()
    Logger.info("track_conn is running — open #{url} in your browser.")

    # Don't let a missing/odd opener take anything down: run it detached.
    Task.start(fn -> open_browser(url) end)

    {:noreply, state}
  end

  @doc "The local URL the dashboard is served on."
  def dashboard_url do
    TrackConnWeb.Endpoint.url()
  end

  # Hands the URL to the OS's default-browser opener. Returns :ok on a launched
  # opener, {:error, reason} otherwise.
  defp open_browser(url) do
    case openers() do
      [] ->
        Logger.info("No browser opener found; visit #{url} manually.")
        {:error, :no_opener}

      candidates ->
        try_openers(candidates, url)
    end
  end

  defp try_openers([], url) do
    Logger.info("Couldn't auto-open a browser; visit #{url} manually.")
    {:error, :all_failed}
  end

  defp try_openers([{cmd, args} | rest], url) do
    if System.find_executable(cmd) do
      case System.cmd(cmd, args ++ [url], stderr_to_stdout: true) do
        {_out, 0} -> :ok
        _ -> try_openers(rest, url)
      end
    else
      try_openers(rest, url)
    end
  end

  # Ordered list of {executable, leading_args} to try per platform.
  defp openers do
    case :os.type() do
      {:win32, _} ->
        # `start` is a cmd builtin; the "" is the (empty) window title arg.
        [{"cmd", ["/c", "start", ""]}]

      {:unix, :darwin} ->
        [{"open", []}]

      {:unix, _} ->
        # Plain Linux uses xdg-open; under WSL prefer wslview / Windows' start
        # so the URL opens in the Windows host browser.
        wsl = [{"wslview", []}, {"cmd.exe", ["/c", "start", ""]}]
        base = [{"xdg-open", []}, {"gio", ["open"]}]
        if wsl?(), do: wsl ++ base, else: base ++ wsl
    end
  end

  defp wsl? do
    case File.read("/proc/version") do
      {:ok, v} -> String.contains?(String.downcase(v), "microsoft")
      _ -> false
    end
  end
end
