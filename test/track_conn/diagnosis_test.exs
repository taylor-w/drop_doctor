defmodule TrackConn.DiagnosisTest do
  use ExUnit.Case, async: true
  alias TrackConn.Diagnosis

  # Build a sweep map shaped like the one the Monitor produces.
  defp defn(:router),
    do: %{
      key: :router,
      label: "Your router / local network",
      kind: :ping,
      target: "192.168.1.1",
      about: "x"
    }

  defp defn(:internet),
    do: %{
      key: :internet,
      label: "The open internet (via your ISP)",
      kind: :ping,
      target: "1.1.1.1",
      about: "x"
    }

  defp defn(:dns),
    do: %{key: :dns, label: "DNS", kind: :dns, target: "cloudflare.com", about: "x"}

  defp defn(:web),
    do: %{
      key: :web,
      label: "Loading a real website",
      kind: :http,
      target: "https://x",
      about: "x"
    }

  defp ping(loss, rtt), do: %{ok?: loss < 100, loss_pct: loss, rtt_ms: rtt}
  defp dnsr(ok, ms), do: %{ok?: ok, ms: ms, address: "1.2.3.4"}
  defp webr(ok, ms), do: %{ok?: ok, ms: ms, status: if(ok, do: 200, else: nil), bytes: 0}

  defp analyze(router, internet, dns, web) do
    Diagnosis.analyze(%{
      router: Map.put(router, :def, defn(:router)),
      internet: Map.put(internet, :def, defn(:internet)),
      dns: Map.put(dns, :def, defn(:dns)),
      web: Map.put(web, :def, defn(:web))
    })
  end

  test "all layers healthy -> no culprit" do
    v = analyze(ping(0, 0.3), ping(0, 14), dnsr(true, 20), webr(true, 200))
    assert v.culprit == :none
    assert v.status == :healthy
  end

  test "router unreachable -> blames local, not ISP" do
    v = analyze(ping(100, nil), ping(100, nil), dnsr(false, nil), webr(false, nil))
    assert v.culprit == :local
    assert v.status == :down
  end

  test "local packet loss -> degraded local" do
    v = analyze(ping(20, 8), ping(0, 14), dnsr(true, 20), webr(true, 200))
    assert v.culprit == :local
    assert v.status == :degraded
  end

  test "router fine but internet unreachable -> blames ISP" do
    v = analyze(ping(0, 0.3), ping(100, nil), dnsr(false, nil), webr(false, nil))
    assert v.culprit == :isp
    assert v.status == :down
  end

  test "internet degraded -> ISP degraded" do
    v = analyze(ping(0, 0.3), ping(8, 250), dnsr(true, 20), webr(true, 400))
    assert v.culprit == :isp
    assert v.status == :degraded
  end

  describe "ISP latency is judged on the differential, not the absolute RTT" do
    test "high internet RTT that's mostly a slow local hop is NOT blamed on the ISP" do
      # Router is 30ms (a busy Wi-Fi link, still under its 35ms warn) and the
      # internet reads 100ms — over the old absolute 90ms ceiling. But the ISP
      # only added 70ms over the router, so the provider must be exonerated.
      v = analyze(ping(0, 30), ping(0, 100), dnsr(true, 20), webr(true, 300))
      assert v.culprit == :none
      assert get_in(by_key(v), [:internet, :state]) == :healthy
    end

    test "a real ISP latency spike (small router, large delta) is still caught" do
      v = analyze(ping(0, 5), ping(0, 120), dnsr(true, 20), webr(true, 400))
      assert v.culprit == :isp
      assert v.status == :degraded
      # And the evidence names the ISP's own contribution, not just the total.
      assert get_in(by_key(v), [:internet, :summary]) =~ "ISP adds 115ms"
    end

    test "isp_latency_ms is exposed on the internet segment for the UI" do
      v = analyze(ping(0, 8), ping(0, 60), dnsr(true, 20), webr(true, 300))
      assert get_in(by_key(v), [:internet, :metrics, :isp_latency_ms]) == 52.0
    end

    test "a negative delta (router slower than internet) clamps to zero, not the ISP" do
      # Router answered slower than the internet hop that contains it — a local/
      # host artifact. ISP contribution floors at 0 rather than going negative.
      v = analyze(ping(0, 40), ping(0, 25), dnsr(true, 20), webr(true, 300))
      assert get_in(by_key(v), [:internet, :metrics, :isp_latency_ms]) == 0.0
    end
  end

  # Index a verdict's segment list by key for concise assertions.
  defp by_key(v), do: Map.new(v.segments, &{&1.key, &1})

  test "connectivity fine but DNS broken -> blames DNS" do
    v = analyze(ping(0, 0.3), ping(0, 14), dnsr(false, nil), webr(false, nil))
    assert v.culprit == :dns
  end

  test "DNS slow -> degraded DNS" do
    v = analyze(ping(0, 0.3), ping(0, 14), dnsr(true, 800), webr(true, 900))
    assert v.culprit == :dns
    assert v.status == :degraded
  end

  test "everything fine but web slow -> bandwidth/destination" do
    v = analyze(ping(0, 0.3), ping(0, 14), dnsr(true, 20), webr(true, 3000))
    assert v.culprit == :web
  end

  describe "cross-layer corroboration: a blocked ping can't fake an outage" do
    test "router+internet ping unreachable but DNS & web healthy -> not an outage" do
      # The WSL/ICMP-filtered case: pings to the router and the internet anchor
      # both fail, yet DNS resolves and a real page loads — so traffic is clearly
      # getting out. The verdict must stay healthy, not scream 'router down'.
      v = analyze(ping(100, nil), ping(100, nil), dnsr(true, 20), webr(true, 200))
      assert v.culprit == :none
      assert v.status == :healthy
      assert get_in(by_key(v), [:router, :state]) == :healthy
      assert get_in(by_key(v), [:internet, :state]) == :healthy
      assert get_in(by_key(v), [:router, :summary]) =~ "ICMP blocked"
    end

    test "still a real outage when DNS & web are ALSO failing" do
      # No corroboration — nothing downstream works — so the down stands.
      v = analyze(ping(100, nil), ping(100, nil), dnsr(false, nil), webr(false, nil))
      assert v.culprit == :local
      assert v.status == :down
    end

    test "genuine degradation is NOT cleared (only hard down is)" do
      # Router shows real packet loss while the page still loads. That's a real
      # local problem worth surfacing — corroboration must leave it alone.
      v = analyze(ping(20, 8), ping(0, 14), dnsr(true, 20), webr(true, 200))
      assert v.culprit == :local
      assert v.status == :degraded
    end
  end

  test "verdict always carries human-facing copy" do
    v = analyze(ping(0, 0.3), ping(100, nil), dnsr(false, nil), webr(false, nil))
    assert is_binary(v.headline)
    assert is_binary(v.detail)
    assert is_binary(v.action)
    assert length(v.evidence) == 4
    assert length(v.segments) == 4
  end
end
