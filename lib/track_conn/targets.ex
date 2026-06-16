defmodule TrackConn.Targets do
  @moduledoc """
  Builds the "ladder" of things to probe, from closest to your machine
  (the router) out to the open internet. Comparing where on this ladder
  things go wrong is the core of the diagnosis.

  Targets are configurable via application config (`:track_conn, :targets`); the
  router can be overridden with the `ROUTER_IP` env var and the open-internet
  probe with `INTERNET_IP`. Under WSL the physical router is discovered
  automatically from the Windows host (see `TrackConn.Net`), so `ROUTER_IP` is
  only needed there as a manual fallback when the host can't be reached.
  """

  @doc """
  Returns the ladder as a list of segment definitions in order. The router
  target is resolved fresh each call so it tracks network changes.
  """
  def ladder do
    [
      %{
        key: :router,
        label: "Your router / local network",
        kind: :ping,
        target: router_target(),
        about: "The first hop out of your computer. Problems here are on your side."
      },
      %{
        key: :internet,
        label: "The open internet (via your ISP)",
        kind: :ping,
        target: internet_target(),
        about: "A raw IP address with no DNS involved. Problems here usually mean your ISP."
      },
      %{
        key: :dns,
        label: "DNS (turning names into addresses)",
        kind: :dns,
        target: dns_target(),
        about: "If this fails while the internet is fine, it's a DNS issue — often easy to fix."
      },
      %{
        key: :web,
        label: "Loading a real website",
        kind: :http,
        target: web_target(),
        about:
          "End-to-end experience. Slow here but fine elsewhere points at bandwidth or the site."
      }
    ]
  end

  @doc "The router/gateway IP we'll probe, honoring ROUTER_IP then auto-detection."
  def router_target do
    System.get_env("ROUTER_IP") ||
      get_in(config(), [:router]) ||
      TrackConn.Net.default_gateway() ||
      "192.168.1.1"
  end

  @doc """
  The raw IP we ping to test the open internet, honoring INTERNET_IP then config.
  Defaults to 1.1.1.1, but some networks (and WSL setups) silently drop ICMP to
  it while others — e.g. 8.8.8.8 — answer fine, so it's overridable.
  """
  def internet_target do
    System.get_env("INTERNET_IP") ||
      get_in(config(), [:internet]) ||
      "1.1.1.1"
  end

  def dns_target, do: get_in(config(), [:dns]) || "cloudflare.com"
  def web_target, do: get_in(config(), [:web]) || "https://www.google.com/generate_204"

  defp config, do: Application.get_env(:track_conn, :targets, %{})
end
