defmodule Orbitorc.Agent.LanTest do
  use ExUnit.Case, async: true

  alias Orbitorc.Agent.{Config, Health, Platform}

  # The shapes below are what :inet.getifaddrs/0 returns on Windows, where every name is a device path.
  @hyper_v_switch {~c"\\DEVICE\\TCPIP_{F1833882-B11C-4030-8EA6-AA18B7F791BB}",
                   [
                     flags: [:up, :broadcast, :running, :multicast],
                     hwaddr: [0x00, 0x15, 0x5D, 0x01, 0x9C, 0x00],
                     addr: {10, 250, 0, 1}
                   ]}
  @ethernet {~c"\\DEVICE\\TCPIP_{E9E255F8-8955-45E8-82F3-0274764A0DE1}",
             [
               flags: [:up, :broadcast, :running, :multicast],
               hwaddr: [0xC4, 0xC6, 0xE6, 0x61, 0x81, 0xD0],
               addr: {192, 168, 1, 249}
             ]}
  @loopback {~c"\\DEVICE\\TCPIP_{0F69A75A-DC66-11EC-AF08-806E6F6E6963}",
             [flags: [:up, :loopback, :running], addr: {127, 0, 0, 1}]}
  @link_local {~c"\\DEVICE\\TCPIP_{B44CB4F7-BF8D-4C06-9368-91B3583CA2F7}",
               [
                 flags: [:broadcast, :multicast],
                 hwaddr: [0x10, 0x20, 0x30, 0x40, 0x50, 0x60],
                 addr: {169, 254, 194, 145}
               ]}

  test "a Hyper-V switch that enumerates first is skipped for the physical adapter" do
    assert Platform.pick_lan([@hyper_v_switch, @ethernet, @loopback]) == "192.168.1.249"
  end

  test "loopback and link-local addresses are never picked" do
    assert Platform.pick_lan([@loopback, @link_local, @ethernet]) == "192.168.1.249"
    assert Platform.pick_lan([@loopback, @link_local]) == nil
  end

  test "a box with only a Hyper-V adapter advertises nothing" do
    assert Platform.pick_lan([@hyper_v_switch, @loopback]) == nil
  end

  test "the name filter still skips a Unix tunnel" do
    utun = {~c"utun3", [flags: [:up, :pointtopoint, :running], addr: {10, 2, 0, 2}]}

    en0 =
      {~c"en0",
       [flags: [:up, :broadcast, :running], hwaddr: [0, 1, 2, 3, 4, 5], addr: {192, 168, 1, 245}]}

    assert Platform.pick_lan([utun, en0]) == "192.168.1.245"
  end

  describe "a lan pinned in the configuration" do
    setup do
      dir = Path.join(System.tmp_dir!(), "orbitorc-lan-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    defp config_with(dir, extra) do
      path = Path.join(dir, "config.json")

      File.write!(
        path,
        Jason.encode!(
          Map.merge(
            %{
              "control_plane" => "ws://localhost:4000/agent/websocket",
              "name" => "box",
              "token" => "t",
              "projects" => [%{"name" => "p", "repo" => Path.join(dir, "repo")}]
            },
            extra
          )
        )
      )

      Config.load(path)
    end

    test "is what the box reports", %{dir: dir} do
      {:ok, config, _problems} = config_with(dir, %{"lan" => "192.168.1.254"})
      assert config.lan == "192.168.1.254"
      assert Health.report(config)["lan"] == "192.168.1.254"
    end

    test "is optional", %{dir: dir} do
      {:ok, config, _problems} = config_with(dir, %{})
      assert config.lan == nil
    end

    test "refuses anything that is not a dotted IPv4 address", %{dir: dir} do
      for bad <- ["happytop", "192.168.1", "192.168.1.300", "::1", 42] do
        assert {:error, message} = config_with(dir, %{"lan" => bad})
        assert message =~ "lan must be a dotted IPv4 address"
      end
    end
  end
end
