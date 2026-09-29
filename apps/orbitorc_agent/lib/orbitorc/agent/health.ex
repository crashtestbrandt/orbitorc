defmodule Orbitorc.Agent.Health do
  @moduledoc """
  What this box would report if asked right now.

  A fleet is only as trustworthy as its least honest box, so the report is deliberately wide: not "is
  the agent up" but "would a job launched here produce a result anybody should believe".

  ## The checks that catch a confident wrong answer

  | Check | What it catches |
  | --- | --- |
  | Graphical session | A rendering job that draws nothing **and reports success**. |
  | Checkout revision | Two boxes in one session running different code, which reads as a netcode disagreement. |
  | A dirty checkout | A result nobody can reproduce, attributed to a commit that does not contain it. |
  | Engine version | A version skew that changes physics or serialization under the measurement. |
  | Import freshness | A stale class cache resolves a class name to nothing, and the project dies at parse time or comes up empty. This is the one that produces a metrics file full of zeros. |
  | Declared requirements | A native library the project needs and this checkout has never built. Every class it registers resolves to nothing, so the job dies at load or comes up empty. |

  Every check is **reported, never fatal**. A box that refuses to start over one of them says nothing
  about why; a box that appears and names its own problem can be fixed.
  """

  alias Orbitorc.Agent.{Config, Platform}

  @doc "The full report a box sends when it joins, and again whenever asked."
  @spec report(Config.t(), [String.t()]) :: map()
  def report(%Config{} = config, problems \\ []) do
    {session_ok, session_detail} = Platform.session_ok()

    %{
      "platform" => Atom.to_string(Platform.kind()),
      "session_ok" => session_ok,
      "session_detail" => session_detail,
      "lan" => Platform.lan_address(),
      "game_port" => config.game_port,
      "relay_port" => config.relay_port,
      "exports" => Platform.exports(),
      "tools" => tools(),
      "projects" =>
        Map.new(config.projects, fn {name, spec} -> {name, project_report(config, name, spec)} end),
      "capabilities" => capabilities(config, session_ok),
      "problems" => problems
    }
  end

  defp capabilities(%Config{} = config, session_ok) do
    launch = Orbitorc.Capability.for_projects(config.manifests, session_ok)

    exports =
      Map.new(
        ["windows", "macos", "linux", "server"],
        &{"export.#{&1}", &1 in Platform.exports()}
      )

    Map.merge(launch, exports)
    |> Map.merge(%{
      "shot" => session_ok and shot_tools?(),
      "git" => Platform.tool?("git"),
      "just" => Platform.tool?("just")
    })
  end

  # A capture targets ONE WINDOW and never the screen: a screen grab returns whatever happened to be in
  # front, which is a confident answer about the wrong thing. On X11 that needs a window locator and a
  # reader; Wayland has no compositor-independent way to do it at all.
  defp shot_tools? do
    case Platform.kind() do
      :linux ->
        System.get_env("WAYLAND_DISPLAY") == nil and Platform.tool?("xdotool") and
          Platform.tool?("import")

      _ ->
        true
    end
  end

  defp tools do
    Map.new(["git", "just", "curl"], &{&1, Platform.tool?(&1)})
  end

  defp project_report(%Config{} = config, name, spec) do
    %{
      "repo" => spec.repo,
      "engine_bin" => spec.engine_bin,
      "engine" => engine(spec.engine_bin),
      "revision" => revision(spec.repo),
      "manifest" => manifest_report(config, name),
      "import" => import_freshness(config, name, spec),
      "requires" => requirements(config, name, spec)
    }
  end

  @doc """
  Whether everything a job here needs is actually present.

  A project declares these under `checks.requires` as paths relative to its checkout. They are
  **what a job needs in order to mean anything**, which is a different question from where a build
  lands: a project can have an export directory and no native library, and it is the library whose
  absence ruins the run.

  **A missing native library does not fail at launch; it fails at parse time.** Every class it
  registers resolves to nothing, a project that promotes that to an error dies during load, and one
  that does not comes up with an empty world. Both produce a confident wrong answer three steps from
  the cause, and the second writes a full metrics file of zeros.

  A project that declares nothing here is reported as fine. This check knows nothing about any
  project; it only checks what it was told to.
  """
  @spec requirements(Config.t(), String.t(), map()) :: map()
  def requirements(%Config{manifests: manifests}, name, spec) do
    case manifests |> Map.get(name) |> required_paths() do
      [] ->
        %{"ok" => true, "detail" => "this project declares nothing it requires"}

      paths ->
        missing = Enum.reject(paths, &present?(Path.join(spec.repo, &1)))

        if missing == [] do
          %{"ok" => true, "detail" => "#{length(paths)} declared requirement(s) present"}
        else
          %{
            "ok" => false,
            "missing" => missing,
            "detail" =>
              "missing from this checkout: #{Enum.join(missing, ", ")} — a job launched here would fail at load, not at launch"
          }
        end
    end
  end

  defp required_paths(nil), do: []

  defp required_paths(manifest) do
    case Map.get(manifest.checks, "requires") do
      paths when is_list(paths) -> Enum.map(paths, &to_string/1)
      _ -> []
    end
  end

  # A declared requirement may be a file, or a directory that has to hold something. An empty directory
  # is the shape a cleaned build leaves behind, and it satisfies neither.
  defp present?(path) do
    cond do
      File.regular?(path) -> true
      File.dir?(path) -> match?({:ok, [_ | _]}, File.ls(path))
      true -> Path.wildcard(path) != []
    end
  end

  defp engine(engine_bin) do
    case Platform.engine_version(engine_bin) do
      {:ok, version} -> %{"ok" => true, "version" => version}
      {:error, reason} -> %{"ok" => false, "detail" => reason}
    end
  end

  defp manifest_report(%Config{manifests: manifests}, name) do
    case Map.fetch(manifests, name) do
      {:ok, manifest} ->
        %{
          "ok" => true,
          "project" => manifest.project,
          "modes" => Orbitorc.Manifest.mode_names(manifest),
          "engine_project" => manifest.engine_project
        }

      :error ->
        %{
          "ok" => false,
          "detail" => "no usable #{Orbitorc.Manifest.manifest_name()} in the checkout"
        }
    end
  end

  @doc """
  The checkout's own account of itself: revision, branch, and whether anything is uncommitted.

  A dirty checkout is not refused — a developer measuring an unpushed change is the normal case — but it
  is **named**, because a result attributed to a commit that does not contain the change is worse than
  no result.
  """
  @spec revision(Path.t()) :: map()
  def revision(repo) do
    with {:ok, sha} <- git(repo, ["rev-parse", "HEAD"]),
         {:ok, branch} <- git(repo, ["rev-parse", "--abbrev-ref", "HEAD"]),
         {:ok, status} <- git(repo, ["status", "--porcelain"]) do
      dirty = status |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))

      %{
        "ok" => true,
        "sha" => String.trim(sha),
        "branch" => String.trim(branch),
        "dirty" => dirty != [],
        "dirty_count" => length(dirty)
      }
    else
      {:error, reason} -> %{"ok" => false, "detail" => reason}
    end
  end

  @doc """
  Whether the engine's import cache is newer than every script in the tree.

  **This is the check that produces a metrics file full of zeros.** A cache built from an older tree is
  missing any class added or renamed since, and a project whose class name resolves to nothing either
  dies at parse time or comes up with nothing in it. Either way a bringup timeout names the symptom
  three steps from the cause, and the second way produces a full CSV of flat zeros — a run that looks
  like a regression in whatever branch is under test.
  """
  @spec import_freshness(Config.t(), String.t(), map()) :: map()
  def import_freshness(%Config{manifests: manifests}, name, spec) do
    case Map.fetch(manifests, name) do
      :error ->
        %{"ok" => false, "detail" => "no manifest, so no project path to check"}

      {:ok, manifest} ->
        project_path = Orbitorc.Manifest.project_path(manifest, spec.repo)
        cache = Path.join(project_path, ".godot")

        case File.stat(cache, time: :posix) do
          {:ok, %{mtime: cache_mtime}} ->
            compare_to_scripts(project_path, cache_mtime)

          {:error, _} ->
            %{
              "ok" => false,
              "detail" => "no import cache; the project has never been imported here"
            }
        end
    end
  end

  defp compare_to_scripts(project_path, cache_mtime) do
    case newest_script(project_path) do
      nil ->
        %{"ok" => true, "detail" => "no scripts to be stale against"}

      {mtime, _path} when mtime <= cache_mtime ->
        %{"ok" => true, "detail" => "cache newer than every script"}

      {_mtime, path} ->
        %{
          "ok" => false,
          "detail" => "#{Path.relative_to(path, project_path)} is newer than the import cache"
        }
    end
  end

  defp newest_script(project_path) do
    project_path
    |> Path.join("**/*.{gd,cs}")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/.godot/"))
    |> Enum.reduce(nil, fn path, best ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} ->
          if best == nil or mtime > elem(best, 0), do: {mtime, path}, else: best

        _ ->
          best
      end
    end)
  end

  defp git(repo, args) do
    case System.find_executable("git") do
      nil ->
        {:error, "git is not on PATH"}

      git ->
        case System.cmd(git, ["-C", repo | args], stderr_to_stdout: true) do
          {out, 0} ->
            {:ok, out}

          {out, code} ->
            {:error, "git #{Enum.join(args, " ")} exited #{code}: #{String.trim(out)}"}
        end
    end
  end
end
