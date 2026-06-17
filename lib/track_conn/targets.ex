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
        kind: :reach,
        target: router_target(),
        # Many routers never answer ICMP echo but do accept TCP (DNS :53, web
        # admin :80/:443) — so fall back to a TCP connect rather than reporting
        # the router unreachable.
        probe_opts: [anchors: [router_target()], tcp_ports: [53, 80, 443], label: "your router"],
        about: "The first hop out of your computer. Problems here are on your side."
      },
      %{
        key: :internet,
        label: "The open internet (via your ISP)",
        kind: :reach,
        target: internet_target(),
        probe_opts: [anchors: internet_anchors(), tcp_ports: [443], label: "open internet"],
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

  # Well-known anycast resolvers that almost always answer ICMP. We probe the
  # whole set and treat the internet as reachable if *any* of them responds, so
  # a single IP that a given network filters (some drop 1.1.1.1, others 8.8.8.8)
  # can't fake an outage on a connection that's actually fine.
  @default_internet_anchors ["1.1.1.1", "8.8.8.8", "9.9.9.9"]

  @doc """
  The set of open-internet anchors we probe (any-of). Honors `INTERNET_IP` (a
  single override) then `:internet_anchors` / `:internet` config, else a few
  well-known resolvers. Some networks and WSL setups silently drop ICMP to one
  anchor (e.g. 1.1.1.1) while others answer fine — probing several keeps the ISP
  verdict honest without the user choosing an address.
  """
  def internet_anchors do
    cond do
      ip = System.get_env("INTERNET_IP") -> [ip]
      list = get_in(config(), [:internet_anchors]) -> list
      single = get_in(config(), [:internet]) -> [single]
      true -> @default_internet_anchors
    end
  end

  @doc "The primary internet anchor — for display and the continuous sampler."
  def internet_target, do: hd(internet_anchors())

  def dns_target, do: get_in(config(), [:dns]) || "cloudflare.com"
  def web_target, do: get_in(config(), [:web]) || "https://www.google.com/generate_204"

  defp config, do: Application.get_env(:track_conn, :targets, %{})
end
