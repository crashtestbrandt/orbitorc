defmodule OrbitorcWeb.AgentChannelTest do
  @moduledoc """
  The socket a box dials into, from the box's side.
  """
  use OrbitorcWeb.ChannelCase, async: false

  alias Orbitorc.{Fleet, Request}
  alias OrbitorcWeb.AgentSocket

  @token "test-token"

  defp connect_with(token) do
    connect(AgentSocket, %{"token" => token}, connect_info: %{x_headers: []})
  end

  defp report,
    do: %{
      "platform" => "linux",
      "session_ok" => true,
      "capabilities" => %{"launch.demo.server" => true}
    }

  test "a wrong token is refused" do
    assert :error = connect_with("nope")
  end

  test "no token at all is refused" do
    assert :error = connect(AgentSocket, %{}, connect_info: %{x_headers: []})
  end

  test "the token may arrive as an x-orbitorc-token header" do
    assert {:ok, _socket} =
             connect(AgentSocket, %{}, connect_info: %{x_headers: [{"x-orbitorc-token", @token}]})
  end

  test "A BOX MAY ONLY JOIN AS THE NAME ITS TOKEN BELONGS TO" do
    {:ok, socket} = connect_with(@token)

    assert {:error, %{reason: reason}} =
             subscribe_and_join(socket, "agent", %{"name" => "imposter", "report" => report()})

    assert reason =~ "belongs to testbox"
  end

  test "a joined box is in the fleet with what it reported, and leaves when its socket does" do
    {:ok, socket} = connect_with(@token)

    {:ok, reply, socket} =
      subscribe_and_join(socket, "agent", %{"name" => "testbox", "report" => report()})

    assert reply["name"] == "testbox"

    assert {:ok, %{name: "testbox", platform: "linux"}} = Fleet.fetch("testbox")

    Process.unlink(socket.channel_pid)
    close(socket)
    Process.sleep(50)
    assert Fleet.fetch("testbox") == {:error, :not_connected}
  end

  test "a second connection claiming the same name is refused rather than replacing the first" do
    {:ok, a} = connect_with(@token)
    {:ok, _, a} = subscribe_and_join(a, "agent", %{"name" => "testbox", "report" => report()})

    {:ok, b} = connect_with(@token)

    assert {:error, %{reason: reason}} =
             subscribe_and_join(b, "agent", %{"name" => "testbox", "report" => report()})

    assert reason =~ "already connected"

    Process.unlink(a.channel_pid)
    close(a)
  end

  test "a reply from the box resolves the request that asked" do
    {:ok, socket} = connect_with(@token)

    {:ok, _, socket} =
      subscribe_and_join(socket, "agent", %{"name" => "testbox", "report" => report()})

    {:ok, ref} = Request.open("testbox", 1_000)

    push(socket, "reply", %{"ref" => ref, "result" => %{"ok" => true, "value" => %{"jobs" => []}}})

    assert Request.await(ref, 1_000) == {:ok, %{"jobs" => []}}

    Process.unlink(socket.channel_pid)
    close(socket)
  end

  test "an ask from the control plane is pushed down to the box" do
    {:ok, socket} = connect_with(@token)

    {:ok, _, socket} =
      subscribe_and_join(socket, "agent", %{"name" => "testbox", "report" => report()})

    {:ok, box} = Fleet.fetch("testbox")
    send(box.pid, {:ask, "doctor", %{"ref" => "r1", "caller" => "t"}})
    assert_push "doctor", %{"ref" => "r1", "caller" => "t"}

    Process.unlink(socket.channel_pid)
    close(socket)
  end

  test "a job event from the box lands on the box's job topic, where a run is waiting" do
    {:ok, socket} = connect_with(@token)

    {:ok, _, socket} =
      subscribe_and_join(socket, "agent", %{"name" => "testbox", "report" => report()})

    Phoenix.PubSub.subscribe(Orbitorc.PubSub, "box:testbox:jobs")

    push(socket, "job_event", %{"job" => 7, "event" => "ready", "detail" => %{"ready_ms" => 505}})
    assert_receive {:job_event, "testbox", 7, "ready", %{"ready_ms" => 505}}, 1_000

    Process.unlink(socket.channel_pid)
    close(socket)
  end

  test "a re-report replaces what the fleet holds without reconnecting" do
    {:ok, socket} = connect_with(@token)

    {:ok, _, socket} =
      subscribe_and_join(socket, "agent", %{"name" => "testbox", "report" => report()})

    push(socket, "report", %{"report" => Map.put(report(), "lan", "10.1.1.1")})
    Process.sleep(50)
    assert {:ok, %{lan: "10.1.1.1"}} = Fleet.fetch("testbox")

    Process.unlink(socket.channel_pid)
    close(socket)
  end
end
