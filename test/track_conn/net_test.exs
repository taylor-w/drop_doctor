defmodule TrackConn.NetTest do
  use ExUnit.Case, async: true

  alias TrackConn.Net

  describe "parse_ipconfig_gateway/1 — real-router discovery under WSL" do
    test "picks the physical-adapter gateway, skipping the blank WSL-adapter one" do
      # Captured `ipconfig.exe` shape: the WSL vEthernet adapter has a blank
      # Default Gateway, the physical Wi-Fi adapter carries the real router.
      out = """
      Ethernet adapter vEthernet (WSL):

         Connection-specific DNS Suffix  . :
         Link-local IPv6 Address . . . . . : fe80::1%58
         Default Gateway . . . . . . . . . :

      Wireless LAN adapter Wi-Fi:

         IPv4 Address. . . . . . . . . . . : 192.168.1.42
         Default Gateway . . . . . . . . . : 192.168.1.1
      """

      assert Net.parse_ipconfig_gateway(out) == "192.168.1.1"
    end

    test "skips an IPv6 default gateway and takes the IPv4 one" do
      out = """
         Default Gateway . . . . . . . . . : fe80::abcd%14
         Default Gateway . . . . . . . . . : 10.0.0.1
      """

      assert Net.parse_ipconfig_gateway(out) == "10.0.0.1"
    end

    test "returns nil when no usable gateway is present" do
      out = """
         Default Gateway . . . . . . . . . :
         Default Gateway . . . . . . . . . : 0.0.0.0
      """

      assert Net.parse_ipconfig_gateway(out) == nil
    end

    test "reads the IPv4 from an unlabelled continuation line below an IPv6 gateway" do
      # The dual-stack shape that broke native Windows: the labelled line carries
      # the IPv6 next-hop, the real IPv4 is the indented continuation beneath it.
      out = """
      Wireless LAN adapter Wi-Fi:

         IPv4 Address. . . . . . . . . . . : 192.168.0.42
         Default Gateway . . . . . . . . . : fe80::1%14
                                             192.168.0.1
      """

      assert Net.parse_ipconfig_gateway(out) == "192.168.0.1"
    end

    test "never returns an IPv6 fragment as a bogus host (the old :-split bug)" do
      out = """
         Default Gateway . . . . . . . . . : fe80::abcd%14
      """

      # Old code returned "abcd%14"; now we get nil (→ caller falls back safely).
      assert Net.parse_ipconfig_gateway(out) == nil
    end
  end
end
