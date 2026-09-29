defmodule Orbitorc.Agent.ConfigTest do
  use ExUnit.Case, async: true

  alias Orbitorc.Agent.{Config, Health}

  setup do
    dir = Path.join(System.tmp_dir!(), "orbitorc-cfg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp write_config(dir, projects) do
    path = Path.join(dir, "config.json")

    File.write!(
      path,
      Jason.encode!(%{
        "control_plane" => "ws://localhost:4000/agent/websocket",
        "name" => "box",
        "token" => "t",
        "projects" => projects
      })
    )

    path
  end

  defp write_manifest(repo, extra \\ %{}) do
    File.mkdir_p!(repo)

    File.write!(
      Path.join(repo, "orbitorc.json"),
      Jason.encode!(
        Map.merge(%{"schema" => 1, "project" => "p", "modes" => %{"smoke" => %{}}}, extra)
      )
    )
  end

  test "a good configuration loads, with its manifests", %{dir: dir} do
    repo = Path.join(dir, "p")
    write_manifest(repo)
    path = write_config(dir, [%{"name" => "p", "repo" => repo}])

    assert {:ok, config, []} = Config.load(path)
    assert config.name == "box"
    assert Map.keys(config.manifests) == ["p"]
    assert {:ok, _spec, manifest} = Config.fetch_project(config, "p")
    assert manifest.project == "p"
  end

  test "A PROJECT WITH NO MANIFEST IS REPORTED, NOT FATAL: the others still serve", %{dir: dir} do
    good = Path.join(dir, "good")
    write_manifest(good)
    bad = Path.join(dir, "bad")
    File.mkdir_p!(bad)

    path =
      write_config(dir, [%{"name" => "good", "repo" => good}, %{"name" => "bad", "repo" => bad}])

    assert {:ok, config, [problem]} = Config.load(path)
    assert problem =~ "bad:"
    assert Map.keys(config.manifests) == ["good"]
    assert {:error, msg} = Config.fetch_project(config, "bad")
    assert msg =~ "no usable orbitorc.json"
  end

  test "an unknown project names what the box does serve", %{dir: dir} do
    repo = Path.join(dir, "p")
    write_manifest(repo)
    {:ok, config, _} = Config.load(write_config(dir, [%{"name" => "p", "repo" => repo}]))

    assert {:error, msg} = Config.fetch_project(config, "q")
    assert msg =~ "it serves p"
  end

  test "a configuration missing its control plane, name or token is refused by name", %{dir: dir} do
    path = Path.join(dir, "config.json")

    File.write!(
      path,
      Jason.encode!(%{
        "name" => "box",
        "token" => "t",
        "projects" => [%{"name" => "p", "repo" => dir}]
      })
    )

    assert {:error, msg} = Config.load(path)
    assert msg =~ "control_plane"
  end

  test "a configuration with no projects is refused: the box could serve nothing", %{dir: dir} do
    path = Path.join(dir, "config.json")

    File.write!(
      path,
      Jason.encode!(%{
        "control_plane" => "ws://x",
        "name" => "box",
        "token" => "t",
        "projects" => []
      })
    )

    assert {:error, msg} = Config.load(path)
    assert msg =~ "no projects"
  end

  test "a missing file says where it looked", %{dir: dir} do
    assert {:error, msg} = Config.load(Path.join(dir, "nope.json"))
    assert msg =~ "nope.json"
  end

  describe "declared requirements" do
    test "a missing requirement is named, with what it means for a job", %{dir: dir} do
      repo = Path.join(dir, "p")

      write_manifest(repo, %{
        "checks" => %{"requires" => ["addons/native/bin", "harness/addons/p"]}
      })

      {:ok, config, _} = Config.load(write_config(dir, [%{"name" => "p", "repo" => repo}]))

      report = Health.requirements(config, "p", %{repo: repo})
      assert report["ok"] == false
      assert report["missing"] == ["addons/native/bin", "harness/addons/p"]
      assert report["detail"] =~ "fail at load, not at launch"
    end

    test "an EMPTY directory does not satisfy a requirement — it is what a cleaned build leaves",
         %{dir: dir} do
      repo = Path.join(dir, "p")
      write_manifest(repo, %{"checks" => %{"requires" => ["addons/native/bin"]}})
      File.mkdir_p!(Path.join(repo, "addons/native/bin"))
      {:ok, config, _} = Config.load(write_config(dir, [%{"name" => "p", "repo" => repo}]))

      assert %{"ok" => false} = Health.requirements(config, "p", %{repo: repo})

      File.write!(Path.join(repo, "addons/native/bin/lib.so"), "x")
      assert %{"ok" => true} = Health.requirements(config, "p", %{repo: repo})
    end

    test "a project that declares nothing is fine", %{dir: dir} do
      repo = Path.join(dir, "p")
      write_manifest(repo)
      {:ok, config, _} = Config.load(write_config(dir, [%{"name" => "p", "repo" => repo}]))
      assert %{"ok" => true} = Health.requirements(config, "p", %{repo: repo})
    end
  end
end
