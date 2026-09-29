defmodule Orbitorc.RealManifestTest do
  @moduledoc """
  The schema is only worth anything if it reproduces a command line somebody already runs by hand.

  These tests build argv from a manifest shaped exactly like the one a netcode project ships, and assert
  the result against the line its own single-box harness launches. A schema that could not express that
  line would be a schema that needs a special case per project, which is the thing the manifest exists
  to avoid.
  """
  use ExUnit.Case, async: true

  alias Orbitorc.Manifest

  @engine "/usr/local/bin/godot"
  @repo "/boxes/netcode"
  @log "/jobs/12/job.log"

  # The shape a netcode project's manifest takes: an authority, a conditioned link, and a bot client.
  @manifest %{
    "schema" => 1,
    "project" => "netcode",
    "engine_project" => "demos/arena",
    "ports" => %{"game" => 47_900, "relay" => 47_910},
    "modes" => %{
      "server" => %{
        "ready" => "-STATE PLAYING",
        "gui" => false,
        "env" => %{"DEBUG_WIRE" => "1"},
        "engine" => ["--headless"],
        "argv" => ["--dedicated={port}", "--quit-after={quit_after}", "--wire-log"],
        "defaults" => %{"port" => 47_900, "quit_after" => 200}
      },
      "relay" => %{
        "ready" => "RELAY: bound",
        "gui" => false,
        "script" => "res://addons/netcode/bench/relay_main.gd",
        "argv" => [
          "--relay-listen={listen}",
          "--relay-target={target}",
          "--relay-profile={profile}",
          "--relay-seed={seed}",
          "--relay-duration={duration}"
        ],
        "defaults" => %{
          "listen" => 47_910,
          "profile" => "congested_wifi",
          "seed" => 1,
          "duration" => 3600
        },
        "required" => ["target"]
      },
      "bench" => %{
        "ready" => "-STATE PLAYING",
        "gui" => true,
        "argv" => [
          "--join={join}",
          "--bench",
          "--bench-bot={bot}",
          "--bench-seed={seed}",
          "--bench-metrics={metrics}",
          "--bench-duration={duration}"
        ],
        "defaults" => %{"bot" => "strafe", "seed" => 1, "duration" => 25},
        "required" => ["join"]
      }
    }
  }

  setup do
    {:ok, manifest} = Manifest.parse(@manifest, "test")
    {:ok, manifest: manifest}
  end

  defp argv(manifest, mode, params \\ %{}, opts \\ []) do
    opts = Keyword.merge([engine_bin: @engine, repo: @repo, log_path: @log, params: params], opts)
    {:ok, argv} = Manifest.build_argv(manifest, mode, opts)
    argv
  end

  test "the authority's line matches what a single-box harness launches", %{manifest: manifest} do
    assert argv(manifest, "server") == [
             @engine,
             "--path",
             "/boxes/netcode/demos/arena",
             "--headless",
             "--log-file",
             @log,
             "--",
             "--dedicated=47900",
             "--quit-after=200",
             "--wire-log"
           ]
  end

  test "the authority carries the environment variable its send-path measurement needs", %{
    manifest: manifest
  } do
    # Every send-path column reads zero in a client CSV, because a client is not the authority and runs
    # none of it. This variable is the only way a send-path change can be compared at all.
    assert Manifest.env(manifest, "server") == %{"DEBUG_WIRE" => "1"}
  end

  test "the link runs as a script, not a session, and points at the authority", %{
    manifest: manifest
  } do
    assert argv(manifest, "relay", %{
             "target" => "192.168.1.9:47900",
             "seed" => 7,
             "duration" => 145
           }) == [
             @engine,
             "--path",
             "/boxes/netcode/demos/arena",
             "--log-file",
             @log,
             "-s",
             "res://addons/netcode/bench/relay_main.gd",
             "--",
             "--relay-listen=47910",
             "--relay-target=192.168.1.9:47900",
             "--relay-profile=congested_wifi",
             "--relay-seed=7",
             "--relay-duration=145"
           ]
  end

  test "the link refuses to start without a target rather than defaulting to one", %{
    manifest: manifest
  } do
    # A relay defaulted at loopback would condition a socket to nothing, and the run would measure a
    # link that was never in the path.
    assert {:error, msg} =
             Manifest.build_argv(manifest, "relay",
               engine_bin: @engine,
               repo: @repo,
               log_path: @log
             )

    assert msg =~ "target"
  end

  test "a bot client forced headless is what puts several on one box", %{manifest: manifest} do
    argv =
      argv(
        manifest,
        "bench",
        %{"join" => "192.168.1.9:47910", "seed" => 3, "metrics" => "/jobs/12/metrics.csv"},
        headless: true
      )

    assert argv == [
             @engine,
             "--path",
             "/boxes/netcode/demos/arena",
             "--log-file",
             @log,
             "--headless",
             "--",
             "--join=192.168.1.9:47910",
             "--bench",
             "--bench-bot=strafe",
             "--bench-seed=3",
             "--bench-metrics=/jobs/12/metrics.csv",
             "--bench-duration=25"
           ]
  end

  test "a bot client declares that it renders, so a box with no session refuses it unforced", %{
    manifest: manifest
  } do
    assert Manifest.needs_gui?(manifest, "bench")
    refute Manifest.needs_gui?(manifest, "server")
    refute Manifest.needs_gui?(manifest, "relay")
  end

  test "an omitted optional parameter drops its flag rather than sending an empty one", %{
    manifest: manifest
  } do
    argv = argv(manifest, "bench", %{"join" => "h:1"})
    refute Enum.any?(argv, &String.starts_with?(&1, "--bench-metrics"))
    assert "--bench-duration=25" in argv
  end

  test "A ZERO DURATION IS SENT, because it means something different from no duration", %{
    manifest: manifest
  } do
    argv = argv(manifest, "bench", %{"join" => "h:1", "duration" => 0})
    assert "--bench-duration=0" in argv
  end

  test "every mode declares how it proves it came up, or declares that it cannot", %{
    manifest: manifest
  } do
    for mode <- Manifest.mode_names(manifest) do
      assert Manifest.ready_marker(manifest, mode) != nil, "#{mode} declares no ready marker"
    end
  end

  describe "manifests found in sibling checkouts" do
    @siblings ["orbitnet", "orbitnav"]

    # Walk up from wherever the test runs until a directory holding the siblings is found, so this works
    # from the umbrella root and from the app directory alike.
    defp sibling_root do
      File.cwd!()
      |> Path.expand()
      |> Stream.unfold(fn
        "/" -> nil
        dir -> {dir, Path.dirname(dir)}
      end)
      |> Enum.find(fn dir -> Enum.any?(@siblings, &File.dir?(Path.join(dir, &1))) end)
    end

    test "a sibling that ships a manifest parses, and every mode it declares is launchable" do
      root = sibling_root()

      found =
        for name <- @siblings,
            root != nil,
            path = Path.join([root, name, Manifest.manifest_name()]),
            File.exists?(path) do
          assert {:ok, raw} = path |> File.read!() |> Jason.decode(), "#{name}: unreadable JSON"

          assert {:ok, manifest} = Manifest.parse(raw, path),
                 "#{name}: #{inspect(Manifest.parse(raw, path))}"

          for mode <- Manifest.mode_names(manifest) do
            result =
              Manifest.build_argv(manifest, mode,
                engine_bin: @engine,
                repo: @repo,
                log_path: @log,
                params: %{
                  "target" => "10.0.0.2:47900",
                  "join" => "10.0.0.2:47910",
                  "scene" => "res://probes/smoke.tscn"
                }
              )

            assert match?({:ok, _}, result), "#{name}/#{mode} would not build: #{inspect(result)}"
          end

          # Every mode says how it proves it came up, or says plainly that it cannot.
          for mode <- Manifest.mode_names(manifest) do
            assert Manifest.ready_marker(manifest, mode) != nil or
                     get_in(manifest.modes, [mode, "ready"]) == "",
                   "#{name}/#{mode} neither declares a ready marker nor declares that it has none"
          end

          name
        end

      # A test that passes by finding nothing is not a test. If the siblings are not checked out here,
      # say so rather than reporting green.
      assert found != [],
             "no sibling manifest was found under #{inspect(root)} — this test would otherwise pass by checking nothing"
    end
  end
end
