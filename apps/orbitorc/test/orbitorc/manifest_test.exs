defmodule Orbitorc.ManifestTest do
  @moduledoc """
  The argv is the single thing most likely to be wrong in a remote harness, and the failure it
  produces is the worst kind: a job that launches, comes up, and reports a confident verdict about the
  wrong world. So every rule `build_argv/3` applies is pinned here, with no engine and no project
  anywhere near the test.
  """
  use ExUnit.Case, async: true

  alias Orbitorc.Manifest

  @engine "/opt/godot"
  @repo "/checkouts/demo"
  @log "/jobs/7/job.log"

  defp manifest(modes, extra \\ %{}) do
    {:ok, man} =
      Manifest.parse(Map.merge(%{"schema" => 1, "project" => "demo", "modes" => modes}, extra))

    man
  end

  defp argv(man, mode, opts \\ []) do
    opts = Keyword.merge([engine_bin: @engine, repo: @repo, log_path: @log], opts)
    {:ok, argv} = Manifest.build_argv(man, mode, opts)
    argv
  end

  describe "validation" do
    test "a manifest with no schema is refused by name" do
      assert {:error, msg} = Manifest.parse(%{"project" => "demo", "modes" => %{"a" => %{}}})
      assert msg =~ "no schema"
    end

    test "an unknown schema is refused rather than half-read" do
      assert {:error, msg} =
               Manifest.parse(%{"schema" => 99, "project" => "d", "modes" => %{"a" => %{}}})

      assert msg =~ "99"
    end

    test "a manifest with no modes is refused" do
      assert {:error, msg} = Manifest.parse(%{"schema" => 1, "project" => "demo", "modes" => %{}})
      assert msg =~ "no modes"
    end

    test "a mode whose argv is not a list is refused, naming the mode" do
      assert {:error, msg} =
               Manifest.parse(%{
                 "schema" => 1,
                 "project" => "demo",
                 "modes" => %{"server" => %{"argv" => "--go"}}
               })

      assert msg =~ "server"
      assert msg =~ "must be a list"
    end

    test "keys beginning with an underscore are comments and are dropped" do
      assert {:ok, man} =
               Manifest.parse(%{
                 "_comment" => ["read by people"],
                 "schema" => 1,
                 "project" => "demo",
                 "modes" => %{"server" => %{}}
               })

      assert man.project == "demo"
    end
  end

  describe "the engine prefix" do
    test "a from-source job names the engine, the project path and the log" do
      man = manifest(%{"server" => %{}}, %{"engine_project" => "demos/arena"})

      assert argv(man, "server") == [
               @engine,
               "--path",
               "/checkouts/demo/demos/arena",
               "--log-file",
               @log,
               "--"
             ]
    end

    test "a project at the checkout root takes the checkout itself" do
      man = manifest(%{"server" => %{}})
      assert Enum.at(argv(man, "server"), 2) == @repo
    end

    test "an exported build takes no project path, because it boots its own pack" do
      man = manifest(%{"client" => %{}})

      assert argv(man, "client", exported_bin: "/builds/game.exe") == [
               "/builds/game.exe",
               "--log-file",
               @log,
               "--"
             ]
    end

    test "every job writes a log file, whatever the mode" do
      man = manifest(%{"a" => %{"engine" => ["--headless"]}, "b" => %{}})
      assert "--log-file" in argv(man, "a")
      assert "--log-file" in argv(man, "b")
    end
  end

  describe "headless" do
    test "a mode that declares headless carries it without being asked" do
      man = manifest(%{"server" => %{"engine" => ["--headless"]}})
      assert "--headless" in argv(man, "server")
    end

    test "a rendering mode can be forced headless, which is what a bot fleet wants" do
      man = manifest(%{"client" => %{"gui" => true}})
      refute "--headless" in argv(man, "client")
      assert "--headless" in argv(man, "client", headless: true)
    end

    test "forcing headless on a mode that already declares it does not repeat the flag" do
      man = manifest(%{"server" => %{"engine" => ["--headless"]}})
      assert Enum.count(argv(man, "server", headless: true), &(&1 == "--headless")) == 1
    end
  end

  describe "substitution" do
    test "a placeholder with a value is interpolated" do
      man = manifest(%{"server" => %{"argv" => ["--port={port}"]}})
      assert argv(man, "server", params: %{"port" => 47900}) |> List.last() == "--port=47900"
    end

    test "a token whose placeholder has no value is dropped whole" do
      man = manifest(%{"server" => %{"argv" => ["--dedicated", "--port={port}"]}})
      assert List.last(argv(man, "server")) == "--dedicated"
    end

    test "a token with no placeholder is always emitted" do
      man = manifest(%{"server" => %{"argv" => ["--dedicated"]}})
      assert List.last(argv(man, "server")) == "--dedicated"
    end

    test "a default fills a parameter the caller left out" do
      man =
        manifest(%{"server" => %{"argv" => ["--port={port}"], "defaults" => %{"port" => 47900}}})

      assert List.last(argv(man, "server")) == "--port=47900"
    end

    test "a caller's value beats the default" do
      man =
        manifest(%{"server" => %{"argv" => ["--port={port}"], "defaults" => %{"port" => 47900}}})

      assert List.last(argv(man, "server", params: %{"port" => 1234})) == "--port=1234"
    end

    test "a dotted placeholder reaches into a nested parameter" do
      man = manifest(%{"bench" => %{"argv" => ["--bot={bench.bot}"]}})

      assert List.last(argv(man, "bench", params: %{"bench" => %{"bot" => "wander"}})) ==
               "--bot=wander"
    end

    test "a whole number formats without a trailing zero" do
      man = manifest(%{"server" => %{"argv" => ["--radius={r}"]}})
      assert List.last(argv(man, "server", params: %{"r" => 500.0})) == "--radius=500"
    end

    test "a fractional number keeps its fraction" do
      man = manifest(%{"server" => %{"argv" => ["--radius={r}"]}})
      assert List.last(argv(man, "server", params: %{"r" => 2.5})) == "--radius=2.5"
    end

    test "ZERO IS A VALUE, not an absence" do
      # A duration or a seed of zero is a real instruction. Dropping it would silently run a
      # different job than the one asked for -- a run until killed instead of an immediate finish.
      man = manifest(%{"bench" => %{"argv" => ["--duration={d}"]}})
      assert List.last(argv(man, "bench", params: %{"d" => 0})) == "--duration=0"
    end

    test "an explicit nil is an absence, and drops the token" do
      man = manifest(%{"bench" => %{"argv" => ["--duration={d}"]}})
      assert List.last(argv(man, "bench", params: %{"d" => nil})) == "--"
    end

    test "several placeholders in one token all resolve" do
      man = manifest(%{"relay" => %{"argv" => ["--target={host}:{port}"]}})

      assert List.last(argv(man, "relay", params: %{"host" => "10.0.0.2", "port" => 47800})) ==
               "--target=10.0.0.2:47800"
    end

    test "one missing placeholder drops a token the others would have filled" do
      man = manifest(%{"relay" => %{"argv" => ["--target={host}:{port}"]}})
      assert List.last(argv(man, "relay", params: %{"host" => "10.0.0.2"})) == "--"
    end
  end

  describe "conditional tokens" do
    test "an `if` token is emitted only when its parameter is truthy" do
      man = manifest(%{"s" => %{"argv" => [%{"arg" => "--bench", "if" => "bench"}]}})
      assert List.last(argv(man, "s")) == "--"
      assert List.last(argv(man, "s", params: %{"bench" => true})) == "--bench"
    end

    test "an `unless` token is suppressed when the richer parameter was given" do
      man =
        manifest(%{
          "s" => %{
            "argv" => ["--arena={arena}", %{"arg" => "--default-arena", "unless" => "arena"}]
          }
        })

      assert List.last(argv(man, "s")) == "--default-arena"
      assert argv(man, "s", params: %{"arena" => "cube"}) |> List.last() == "--arena=cube"
    end
  end

  describe "required parameters" do
    test "a missing required parameter refuses the launch and names it" do
      man = manifest(%{"client" => %{"argv" => ["--join={join}"], "required" => ["join"]}})

      assert {:error, msg} =
               Manifest.build_argv(man, "client",
                 engine_bin: @engine,
                 repo: @repo,
                 log_path: @log
               )

      assert msg =~ "join"
    end

    test "a required parameter satisfied by a default is not missing" do
      man =
        manifest(%{
          "client" => %{
            "argv" => ["--join={join}"],
            "required" => ["join"],
            "defaults" => %{"join" => "h:1"}
          }
        })

      assert List.last(argv(man, "client")) == "--join=h:1"
    end
  end

  describe "scripts and scenes" do
    test "a script mode runs the script rather than the main scene" do
      man =
        manifest(%{
          "relay" => %{"script" => "res://bench/relay.gd", "argv" => ["--listen={port}"]}
        })

      assert argv(man, "relay", params: %{"port" => 47910}) == [
               @engine,
               "--path",
               @repo,
               "--log-file",
               @log,
               "-s",
               "res://bench/relay.gd",
               "--",
               "--listen=47910"
             ]
    end

    test "a scene is positional and lands BEFORE the separator, where the engine reads it" do
      man = manifest(%{"probe" => %{"scene" => "{scene}"}})
      argv = argv(man, "probe", params: %{"scene" => "res://probes/smoke.tscn"})

      assert Enum.find_index(argv, &(&1 == "res://probes/smoke.tscn")) <
               Enum.find_index(argv, &(&1 == "--"))
    end

    test "a scene mode refuses an exported build, which boots its own main scene" do
      man = manifest(%{"probe" => %{"scene" => "{scene}"}})

      assert {:error, msg} =
               Manifest.build_argv(man, "probe",
                 log_path: @log,
                 exported_bin: "/b/game.exe",
                 params: %{"scene" => "res://a.tscn"}
               )

      assert msg =~ "own main scene"
    end
  end

  describe "passthrough" do
    test "extra arguments ride last, after everything the manifest built" do
      man = manifest(%{"probe" => %{"argv" => ["--probe"]}})

      assert argv(man, "probe", extra: ["--arena=orbit"]) |> Enum.take(-2) == [
               "--probe",
               "--arena=orbit"
             ]
    end
  end

  describe "queries" do
    test "an unknown mode is refused by name, listing what the project does declare" do
      man = manifest(%{"server" => %{}, "client" => %{}})

      assert {:error, msg} =
               Manifest.build_argv(man, "teleport",
                 engine_bin: @engine,
                 repo: @repo,
                 log_path: @log
               )

      assert msg =~ "teleport"
      assert msg =~ "client, server"
    end

    test "a mode with no ready line answers nil rather than an empty marker" do
      man = manifest(%{"probe" => %{}, "server" => %{"ready" => "UP"}})
      assert Manifest.ready_marker(man, "probe") == nil
      assert Manifest.ready_marker(man, "server") == "UP"
    end

    test "gui and env are read off the mode" do
      man = manifest(%{"c" => %{"gui" => true, "env" => %{"DEBUG" => 1}}})
      assert Manifest.needs_gui?(man, "c")
      assert Manifest.env(man, "c") == %{"DEBUG" => "1"}
      refute Manifest.needs_gui?(man, "c") == false and Manifest.env(man, "c") == %{}
    end
  end
end
