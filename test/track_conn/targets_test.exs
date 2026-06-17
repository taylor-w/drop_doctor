defmodule TrackConn.TargetsTest do
  # async: false — mutates process env vars and application config.
  use ExUnit.Case, async: false
  alias TrackConn.Targets

  setup do
    # Snapshot and restore the env/config this test perturbs so it can't leak.
    saved_env = {System.get_env("INTERNET_IP"), System.get_env("ROUTER_IP")}
    saved_cfg = Application.get_env(:track_conn, :targets)

    on_exit(fn ->
      {ip, router} = saved_env
      put_env("INTERNET_IP", ip)
      put_env("ROUTER_IP", router)

      if saved_cfg do
        Application.put_env(:track_conn, :targets, saved_cfg)
      else
        Application.delete_env(:track_conn, :targets)
      end
    end)

    put_env("INTERNET_IP", nil)
    :ok
  end

  describe "internet_anchors/0 robustness" do
    test "an empty :internet_anchors config falls back to defaults (no hd([]) crash)" do
      Application.put_env(:track_conn, :targets, %{internet_anchors: []})
      anchors = Targets.internet_anchors()
      assert anchors != []
      # internet_target/0 = hd(anchors) must not raise — this is the boot path.
      assert is_binary(Targets.internet_target())
    end

    test "a blank INTERNET_IP env is treated as unset, not a [\"\"] anchor" do
      put_env("INTERNET_IP", "")
      Application.put_env(:track_conn, :targets, %{internet_anchors: ["9.9.9.9"]})
      assert Targets.internet_anchors() == ["9.9.9.9"]
    end

    test "a real INTERNET_IP override still wins" do
      put_env("INTERNET_IP", "203.0.113.7")
      assert Targets.internet_anchors() == ["203.0.113.7"]
    end
  end

  describe "router_target/0 robustness" do
    test "a blank ROUTER_IP env is ignored rather than probed as an empty host" do
      put_env("ROUTER_IP", "")
      Application.put_env(:track_conn, :targets, %{router: "10.0.0.1"})
      assert Targets.router_target() == "10.0.0.1"
    end
  end

  defp put_env(key, nil), do: System.delete_env(key)
  defp put_env(key, val), do: System.put_env(key, val)
end
