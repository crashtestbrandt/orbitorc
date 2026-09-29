defmodule Orbitorc.Agent.SyncTest do
  @moduledoc """
  A sync over the link, against a real git remote.

  The box starts on a revision that carries no manifest -- the state of every fresh checkout -- and is
  synced to the branch that has one. Requiring the manifest before a sync left such a box unable to
  fetch the file that would have satisfied the requirement; the first fleet cutover hit exactly that.
  """
  use ExUnit.Case, async: false
  use Slipstream.SocketTest

  alias Orbitorc.Agent.{Config, Jobs, Link}

  # Real git and, on Windows, a powershell session check sit behind every one of these answers; a CI
  # runner there takes seconds where a Mac takes milliseconds.
  @timeout 20_000

  setup do
    tmp = Path.join(System.tmp_dir!(), "orbitorc-sync-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    # origin: main has two commits, the second adds the manifest. The box's checkout is at the first.
    origin = Path.join(tmp, "origin")
    checkout = Path.join(tmp, "checkout")
    git!(tmp, ["init", "-q", "-b", "main", origin])
    File.write!(Path.join(origin, "README"), "before\n")
    git!(origin, ["add", "."])
    git!(origin, ["commit", "-q", "-m", "first"])
    first = git!(origin, ["rev-parse", "HEAD"])
    git!(tmp, ["clone", "-q", origin, checkout])
    git!(checkout, ["checkout", "-q", "--detach", first])

    File.write!(
      Path.join(origin, "orbitorc.json"),
      Jason.encode!(%{"schema" => 1, "project" => "p", "modes" => %{"smoke" => %{}}})
    )

    git!(origin, ["add", "."])
    git!(origin, ["commit", "-q", "-m", "manifest"])
    second = git!(origin, ["rev-parse", "HEAD"])

    {:ok, config, [problem]} =
      Config.load(
        write_config(tmp, [
          %{"name" => "p", "repo" => checkout, "engine_bin" => "godot-not-here"}
        ])
      )

    assert problem =~ "p:"
    :sys.replace_state(Orbitorc.Agent.Leases, fn _ -> Orbitorc.Lease.new() end)
    start_supervised!({Jobs, root: Path.join(tmp, "jobs"), retention: 5})
    pid = start_supervised!({Link, config: config, problems: [problem], test_mode?: true})
    accept_connect(Link)
    assert_join("agent", %{"name" => "box"}, :ok, @timeout)
    {:ok, pid: pid, first: first, second: second}
  end

  test "A FRESH CHECKOUT CAN BE SYNCED TO ITS MANIFEST, and serves it at once", ctx do
    push(Link, "agent", "lease", %{"ref" => "r0", "caller" => "t", "action" => "claim"})
    assert_push("agent", "reply", %{"ref" => "r0", "result" => %{"ok" => true}}, _, @timeout)

    # Before: doctor says the checkout has no manifest.
    push(Link, "agent", "doctor", %{"ref" => "r1", "caller" => "t"})

    assert_push(
      "agent",
      "reply",
      %{"ref" => "r1", "result" => %{"ok" => true, "value" => before}},
      _,
      @timeout
    )

    assert before["projects"]["p"]["manifest"]["ok"] == false
    assert Enum.any?(before["problems"], &String.starts_with?(&1, "p:"))

    # The sync: a branch name, resolved to the remote's branch.
    push(Link, "agent", "sync", %{
      "ref" => "r2",
      "caller" => "t",
      "project" => "p",
      "revision" => "main"
    })

    assert_push(
      "agent",
      "reply",
      %{"ref" => "r2", "result" => %{"ok" => true, "value" => synced}},
      _,
      @timeout
    )

    assert synced["sha"] == ctx.second

    # After: the manifest the sync brought is served, the problem is gone, and the box re-reported.
    assert_push("agent", "report", %{"report" => report}, _, @timeout)
    assert report["projects"]["p"]["manifest"]["ok"] == true
    refute Enum.any?(report["problems"], &String.starts_with?(&1, "p:"))

    push(Link, "agent", "doctor", %{"ref" => "r3", "caller" => "t"})

    assert_push(
      "agent",
      "reply",
      %{"ref" => "r3", "result" => %{"ok" => true, "value" => after_}},
      _,
      @timeout
    )

    assert after_["projects"]["p"]["manifest"]["ok"] == true
    assert Process.alive?(ctx.pid)
  end

  defp write_config(dir, projects) do
    path = Path.join(dir, "config.json")

    File.write!(
      path,
      Jason.encode!(%{
        "control_plane" => "ws://control-plane.invalid/agent/websocket",
        "name" => "box",
        "token" => "t",
        "projects" => projects
      })
    )

    path
  end

  # A CI runner has no git identity; the commits here need one.
  @identity [
    {"GIT_AUTHOR_NAME", "orbitorc test"},
    {"GIT_AUTHOR_EMAIL", "test@orbitorc.invalid"},
    {"GIT_COMMITTER_NAME", "orbitorc test"},
    {"GIT_COMMITTER_EMAIL", "test@orbitorc.invalid"}
  ]

  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, env: @identity, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, status} -> flunk("git #{Enum.join(args, " ")} exited #{status}: #{out}")
    end
  end
end
