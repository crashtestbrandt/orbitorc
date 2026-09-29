defmodule Orbitorc.FleetTest do
  use ExUnit.Case, async: false

  alias Orbitorc.{Capability, Fleet}

  setup do
    # PubSub comes up with the application; the fleet and the request table are started per test so
    # each one sees an empty fleet.
    start_supervised!(Orbitorc.Request)
    start_supervised!(Fleet)
    :ok
  end

  defp report(overrides \\ %{}) do
    Map.merge(
      %{
        "platform" => "linux",
        "session_ok" => true,
        "lan" => "192.168.1.9",
        "game_port" => 47_900,
        "capabilities" => %{"launch.demo.server" => true, "launch.demo.bench" => true}
      },
      overrides
    )
  end

  # A box joins from a process that stands in for its channel; killing it is the box going away.
  defp connect(name, overrides \\ %{}) do
    test = self()

    pid =
      spawn(fn ->
        Fleet.join(name, report(overrides))
        send(test, :joined)
        receive do: (:stop -> :ok)
      end)

    receive do: (:joined -> :ok), after: (1_000 -> flunk("#{name} never joined"))
    pid
  end

  test "a box that joined is listed with what it reported" do
    connect("win")
    assert [%{name: "win", platform: "linux", lan: "192.168.1.9"}] = Fleet.list()
  end

  test "PRESENCE IS THE CONNECTION: a box that dies leaves without anybody polling" do
    pid = connect("win")
    assert [%{name: "win"}] = Fleet.list()

    ref = Process.monitor(pid)
    send(pid, :stop)
    receive do: ({:DOWN, ^ref, _, _, _} -> :ok)

    # No heartbeat to expire and no timeout to tune -- the next read is already correct.
    Process.sleep(20)
    assert Fleet.list() == []
    assert Fleet.fetch("win") == {:error, :not_connected}
  end

  test "two boxes claiming one name is refused rather than silently letting the second win" do
    connect("win")
    test = self()

    spawn(fn ->
      send(test, {:result, Fleet.join("win", report())})
      receive do: (:stop -> :ok)
    end)

    assert_receive {:result, {:error, {:duplicate, _pid}}}, 1_000
  end

  test "a box can replace its report without reconnecting" do
    connect("win")
    Fleet.update("win", report(%{"lan" => "10.0.0.5"}))
    assert {:ok, %{lan: "10.0.0.5"}} = Fleet.fetch("win")
  end

  describe "capable" do
    test "lists only boxes that report the capability" do
      connect("win")
      connect("headless", %{"capabilities" => %{"launch.demo.server" => true}})

      assert Fleet.capable("demo", "server") |> Enum.map(& &1.name) |> Enum.sort() == [
               "headless",
               "win"
             ]

      assert Fleet.capable("demo", "bench") |> Enum.map(& &1.name) == ["win"]
    end

    test "a capability reported false is not a capability" do
      connect("noseat", %{"capabilities" => %{"launch.demo.bench" => false}})
      assert Fleet.capable("demo", "bench") == []
    end

    test "an unreported capability is refused rather than tried" do
      connect("win")
      assert Capability.permits?(%{}, "launch.demo.anything") == false
    end
  end

  test "fleet changes are announced, so a dashboard needs no polling either" do
    Phoenix.PubSub.subscribe(Orbitorc.PubSub, Fleet.topic())
    pid = connect("win")
    assert_receive {:fleet, {:joined, %{name: "win"}}}, 1_000
    send(pid, :stop)
    assert_receive {:fleet, {:left, "win"}}, 1_000
  end
end
