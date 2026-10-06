defmodule Orbitorc.Agent.SyncTagsTest do
  @moduledoc """
  A tag re-created on the remote does not block a sync.

  orbitnet's `v0.3.0` was re-tagged on GitHub, same commit and a new tag object, and a box holding the
  old object refused every sync with "would clobber existing tag".
  """
  use ExUnit.Case, async: true

  alias Orbitorc.Agent.Command

  setup do
    tmp = Path.join(System.tmp_dir!(), "orbitorc-tags-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    origin = Path.join(tmp, "origin")
    checkout = Path.join(tmp, "checkout")
    git!(tmp, ["init", "-q", "-b", "main", origin])
    File.write!(Path.join(origin, "README"), "one\n")
    git!(origin, ["add", "."])
    git!(origin, ["commit", "-q", "-m", "first"])
    git!(origin, ["tag", "-a", "v1", "-m", "first tagging"])
    git!(tmp, ["clone", "-q", origin, checkout])
    {:ok, origin: origin, checkout: checkout}
  end

  test "A TAG RE-CREATED ON THE REMOTE replaces the box's copy, and the sync succeeds", ctx do
    git!(ctx.origin, ["tag", "-f", "-a", "v1", "-m", "second tagging"])
    remote_tag = git!(ctx.origin, ["rev-parse", "v1"])
    refute git!(ctx.checkout, ["rev-parse", "v1"]) == remote_tag

    assert {:ok, synced} = Command.sync(ctx.checkout, "main")
    assert synced["sha"] == git!(ctx.origin, ["rev-parse", "HEAD"])
    assert git!(ctx.checkout, ["rev-parse", "v1"]) == remote_tag
  end

  # A CI runner has no git identity; the commits and tags here need one.
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
