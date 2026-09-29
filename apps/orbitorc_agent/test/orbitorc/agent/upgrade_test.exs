defmodule Orbitorc.Agent.UpgradeTest do
  @moduledoc """
  An upgrade against a release built in the test: the archive CI would attach, the checksum beside
  it, and a running release directory to replace. The fetch is a function, so no network; the swap on
  Windows is a script handed to a launcher, so no WMI.
  """
  use ExUnit.Case, async: true

  alias Orbitorc.Agent.Upgrade

  setup do
    tmp = Path.join(System.tmp_dir!(), "orbitorc-upgrade-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    root = Path.join(tmp, "orbitorc_agent")
    write_release(root, "0.1.0")
    {archive, sha} = tarball(tmp, "0.2.0")

    fetch = fn
      "https://r.invalid/agent.tar.gz" ->
        {:ok, archive}

      "https://r.invalid/agent.tar.gz.sha256" ->
        {:ok, "#{sha}  orbitorc_agent-Linux-X64.tar.gz\n"}

      other ->
        {:error, "no such url #{other}"}
    end

    {:ok, tmp: tmp, root: root, archive: archive, sha: sha, fetch: fetch}
  end

  test "ON UNIX THE SWAP IS DONE BEFORE THE EXIT: the new release is in place, the old beside it",
       ctx do
    assert {:ok, %{"version" => "0.2.0", "swap" => "done"}} =
             Upgrade.stage("https://r.invalid/agent.tar.gz", nil,
               root: ctx.root,
               platform: :linux,
               fetch: ctx.fetch
             )

    assert version_at(ctx.root) == "0.2.0"
    assert version_at(ctx.root <> ".old") == "0.1.0"
    refute File.exists?(ctx.root <> ".staging")
  end

  test "ON WINDOWS THE SWAP IS A SCRIPT FOR AFTER THE EXIT, launched outside the process", ctx do
    test = self()

    assert {:ok, %{"version" => "0.2.0", "swap" => "after exit"}} =
             Upgrade.stage("https://r.invalid/agent.tar.gz", ctx.sha,
               root: ctx.root,
               platform: :windows,
               fetch: ctx.fetch,
               os_pid: "4242",
               launch: fn script ->
                 send(test, {:launched, script})
                 :ok
               end
             )

    assert_receive {:launched, script}
    body = File.read!(script)

    # The module works on the expanded root (on Windows that is `c:/…`, whatever the test was given).
    root = Upgrade.win_path(Path.expand(ctx.root))
    assert body =~ "Wait-Process -Id 4242"

    # Whatever still runs out of the release is stopped first (an epmd outlived the first release and
    # held the directory), each move is checked, and a failed swap is logged rather than claimed.
    assert body =~ "Stop-Process"
    assert body =~ "Move-Item -Path '#{root}' -Destination '#{root}.old' -ErrorAction Stop"
    assert body =~ "SWAP FAILED"
    assert body =~ "Start-ScheduledTask -TaskName 'OrbitOrc Agent'"
    # Nothing moved yet: the running release is still the running release.
    assert version_at(ctx.root) == "0.1.0"
    assert File.dir?(Path.join([ctx.root <> ".staging", "orbitorc_agent", "bin"]))
  end

  test "A WRONG CHECKSUM STOPS EVERYTHING before anything is unpacked", ctx do
    wrong = String.duplicate("0", 64)

    assert {:error, reason} =
             Upgrade.stage("https://r.invalid/agent.tar.gz", wrong,
               root: ctx.root,
               platform: :linux,
               fetch: ctx.fetch
             )

    assert reason =~ "sha256 is"
    assert version_at(ctx.root) == "0.1.0"
    refute File.exists?(ctx.root <> ".staging")
  end

  test "not running from a release, or a fetch that fails, is a plain refusal", ctx do
    assert {:error, reason} = Upgrade.stage("https://r.invalid/agent.tar.gz", nil, root: nil)
    assert reason =~ "not running from a release"

    assert {:error, reason} =
             Upgrade.stage("https://r.invalid/missing.tar.gz", nil,
               root: ctx.root,
               fetch: ctx.fetch
             )

    assert reason =~ "no such url"
  end

  test "a malformed checksum is refused by name" do
    assert {:error, reason} = Upgrade.stage("https://r.invalid/a", "abc", root: nil)
    assert reason =~ "not running from a release" or reason =~ "64 hex"
  end

  # --- a release, as `mix release` lays it out and CI archives it ----------------------------------

  defp write_release(root, version) do
    File.mkdir_p!(Path.join(root, "bin"))
    File.mkdir_p!(Path.join([root, "releases", version]))
    File.write!(Path.join(root, "bin/orbitorc_agent"), "#!/bin/sh\necho #{version}\n")
    File.write!(Path.join(root, "releases/start_erl.data"), "15.0.1 #{version}\n")
  end

  defp tarball(tmp, version) do
    src = Path.join(tmp, "src")
    write_release(Path.join(src, "orbitorc_agent"), version)
    path = Path.join(tmp, "agent.tar.gz")

    # Walked rather than globbed: on Windows the temp directory is an 8.3 short name, and a glob
    # answers the long form, which relative_to cannot strip.
    files = files_under(Path.join(src, "orbitorc_agent"), "orbitorc_agent")
    :ok = :erl_tar.create(String.to_charlist(path), files, [:compressed])
    archive = File.read!(path)
    {archive, :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)}
  end

  defp files_under(dir, prefix) do
    Enum.flat_map(File.ls!(dir), fn name ->
      full = Path.join(dir, name)
      rel = Path.join(prefix, name)

      if File.dir?(full),
        do: files_under(full, rel),
        else: [{String.to_charlist(rel), String.to_charlist(full)}]
    end)
  end

  defp version_at(root) do
    root |> Path.join("releases/start_erl.data") |> File.read!() |> String.split() |> Enum.at(1)
  end
end
