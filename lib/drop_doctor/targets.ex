defmodule DropDoctor.Targets do
  @moduledoc """
  Builds the "ladder" of things to probe, from closest to your machine
  (the router) out to the open internet. Comparing where on this ladder
  things go wrong is the core of the diagnosis.

  Targets are configurable via application config (`:drop_doctor, :targets`); the
  router can be overridden with the `ROUTER_IP` env var and the open-internet
  probe with `INTERNET_IP`. Under WSL the physical router is discovered
  automatically from the Windows host (see `DropDoctor.Net`), so `ROUTER_IP` is
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
    safe_host(blank_to_nil(System.get_env("ROUTER_IP"))) ||
      safe_host(get_in(config(), [:router])) ||
      DropDoctor.Net.default_gateway() ||
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
      ip = safe_host(blank_to_nil(System.get_env("INTERNET_IP"))) -> [ip]
      (list = config_anchors()) != [] -> list
      single = safe_host(get_in(config(), [:internet])) -> [single]
      true -> @default_internet_anchors
    end
  end

  # Config anchors, dropping any that aren't a valid host (so one bad entry can't
  # poison the set or inject a CLI flag into the probes).
  defp config_anchors do
    (get_in(config(), [:internet_anchors]) || [])
    |> List.wrap()
    |> Enum.flat_map(fn a -> List.wrap(safe_host(a)) end)
  end

  # An env var set to "" is effectively unset; treat it as nil so it falls through
  # to config/defaults rather than becoming a bogus [""] anchor (which would make
  # internet_target/0 = hd([""]) probe an empty host, or hd([]) crash boot).
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(str), do: str

  # A target we hand to a system command (ping/mtr/tracert) must be a literal IP
  # or a DNS hostname — never a string a tool could read as a CLI flag. Reject
  # anything else (notably a leading "-"), so a stray env/config value can't
  # inject arguments into the probes; callers fall back to the next source. The
  # auto-detected gateway is already IP-validated in `DropDoctor.Net`.
  defp safe_host(nil), do: nil

  defp safe_host(host) when is_binary(host) do
    cond do
      match?({:ok, _}, host |> String.to_charlist() |> :inet.parse_address()) -> host
      Regex.match?(~r/^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$/, host) -> host
      true -> nil
    end
  end

  defp safe_host(_), do: nil

  @doc "The primary internet anchor — for display and the continuous sampler."
  def internet_target, do: hd(internet_anchors())

  def dns_target, do: safe_host(get_in(config(), [:dns])) || "cloudflare.com"
  def web_target, do: get_in(config(), [:web]) || "https://www.google.com/generate_204"

  # --- speed test ---------------------------------------------------------

  # The default bandwidth backend. Cloudflare's public speed endpoints need no
  # account or API key, are anycast (so they auto-resolve to a nearby edge — the
  # "pick a close server" behaviour a speed test wants, for free), and serve both
  # a sized download (`/__down?bytes=N`) and an upload sink (`/__up`). Measuring
  # real throughput is impossible without *some* remote peer; this is the one that
  # works for a self-contained local binary with no infrastructure to host.
  @default_speedtest_host "speed.cloudflare.com"

  @doc """
  The host the speed test exchanges bytes with. Honors `SPEEDTEST_HOST` then the
  `:speedtest_host` config, else Cloudflare. The value is validated as a bare
  host (no scheme/path/query), so an override can't inject a different URL — a
  power user can point at a self-hosted Cloudflare-compatible backend, nothing
  more. See [[public-repo-plan]] for the configurable-backend rationale.
  """
  def speedtest_host do
    safe_host(blank_to_nil(System.get_env("SPEEDTEST_HOST"))) ||
      safe_host(get_in(config(), [:speedtest_host])) ||
      @default_speedtest_host
  end

  @doc "Download URL for `bytes` of payload from the configured speed-test host."
  def speedtest_download_url(bytes) when is_integer(bytes) and bytes >= 0,
    do: "https://#{speedtest_host()}/__down?bytes=#{bytes}"

  @doc "Upload sink URL on the configured speed-test host."
  def speedtest_upload_url, do: "https://#{speedtest_host()}/__up"

  defp config, do: Application.get_env(:drop_doctor, :targets, %{})
end
