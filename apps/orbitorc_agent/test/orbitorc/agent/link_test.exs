defmodule Orbitorc.Agent.LinkTest do
  @moduledoc """
  The agent's link, driven through Slipstream's own dispatch path with the test standing in for the
  control plane.

  **Why through the library and not by calling the callbacks.** A callback that answers the wrong shape
  does not fail when called directly; it fails when Slipstream turns its return value into a socket
  and cannot. That is where a `{:ok, ref}` in a socket's place crashed the link after every reply —
  invisible to a unit test of the callback, invisible to a single command because the reconnect hid it,
  and fatal to the first thing that asked twice in a row.

  `assert_push/5` takes the ref pattern as its fourth argument and the timeout as its fifth.
  """
  use ExUnit.Case, async: false
  use Slipstream.SocketTest

  alias Orbitorc.Agent.{Config, Jobs, Link}

  @timeout 1_000

  setup do
    tmp = Path.join(System.tmp_dir!(), "orbitorc-link-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    config = %Config{
      control_plane: "ws://control-plane.invalid/agent/websocket",
      name: "box",
      token: "t",
      projects: %{},
      manifests: %{},
      jobs_dir: Path.join(tmp, "jobs")
    }

    # The box's lease lives in an application-wide process and would otherwise carry from one test to
    # the next: a lease claimed in one test turned the next test's "needs the lease" into a different
    # refusal. Every test starts with nobody holding the box.
    :sys.replace_state(Orbitorc.Agent.Leases, fn _ -> Orbitorc.Lease.new() end)

    start_supervised!({Jobs, root: config.jobs_dir, retention: 5})

    # Slipstream's test mode: the test process stands in for the control plane, and the link is driven
    # through the library's own dispatch path -- the path that turns a callback's return value into a
    # crash.
    pid = start_supervised!({Link, config: config, test_mode?: true})
    accept_connect(Link)

    # The link joins as the name its configuration gives, with a report -- the shape the control plane
    # checks. Asserting the join is also what accepts it.
    # The report shells out (the session check runs powershell on Windows), which is longer than the
    # default 100ms on a CI runner.
    assert_join("agent", %{"name" => "box", "report" => %{"platform" => _}}, :ok, 10_000)
    {:ok, pid: pid}
  end

  test "EVERY ANSWER LEAVES THE LINK ALIVE: three asks in a row", %{pid: pid} do
    push(Link, "agent", "status", %{"ref" => "r1", "caller" => "t"})
    assert_push("agent", "reply", %{"ref" => "r1", "result" => %{"ok" => true}}, _, @timeout)

    push(Link, "agent", "doctor", %{"ref" => "r2", "caller" => "t"})
    assert_push("agent", "reply", %{"ref" => "r2", "result" => %{"ok" => true}}, _, @timeout)

    push(Link, "agent", "status", %{"ref" => "r3", "caller" => "t"})
    assert_push("agent", "reply", %{"ref" => "r3", "result" => %{"ok" => true}}, _, @timeout)

    assert Process.alive?(pid)
  end

  test "a refusal is an answer, not a crash", %{pid: pid} do
    push(Link, "agent", "launch", %{
      "ref" => "r1",
      "caller" => "t",
      "project" => "nope",
      "mode" => "x"
    })

    assert_push(
      "agent",
      "reply",
      %{"ref" => "r1", "result" => %{"ok" => false, "error" => error}},
      _,
      @timeout
    )

    assert error =~ "needs the lease"
    assert Process.alive?(pid)
  end

  test "a verb the agent does not serve is refused by name, and the link stays up", %{pid: pid} do
    push(Link, "agent", "teleport", %{"ref" => "r1"})

    assert_push(
      "agent",
      "reply",
      %{"ref" => "r1", "result" => %{"ok" => false, "error" => error}},
      _,
      @timeout
    )

    assert error =~ "teleport"
    assert Process.alive?(pid)
  end

  test "a lease claimed over the link gates a launch over the link", %{pid: pid} do
    push(Link, "agent", "lease", %{"ref" => "r1", "caller" => "t", "action" => "claim"})
    assert_push("agent", "reply", %{"ref" => "r1", "result" => %{"ok" => true}}, _, @timeout)

    push(Link, "agent", "launch", %{
      "ref" => "r2",
      "caller" => "someone-else",
      "project" => "nope",
      "mode" => "x"
    })

    assert_push(
      "agent",
      "reply",
      %{"ref" => "r2", "result" => %{"ok" => false, "error" => error}},
      _,
      @timeout
    )

    assert error =~ "leased by t"
    assert Process.alive?(pid)
  end

  test "a job event on the box is forwarded up the link" do
    Phoenix.PubSub.broadcast(
      Orbitorc.PubSub,
      Jobs.topic(),
      {:job_event, 9, "ready", %{"ready_ms" => 3}}
    )

    assert_push(
      "agent",
      "job_event",
      %{"job" => 9, "event" => "ready", "detail" => %{"ready_ms" => 3}},
      _,
      @timeout
    )
  end

  test "a log line on the box is forwarded up the link" do
    Phoenix.PubSub.broadcast(Orbitorc.PubSub, Jobs.topic(), {:job_log, 9, "ARENA-STATE PLAYING"})
    assert_push("agent", "log", %{"job" => 9, "line" => "ARENA-STATE PLAYING"}, _, @timeout)
  end
end
