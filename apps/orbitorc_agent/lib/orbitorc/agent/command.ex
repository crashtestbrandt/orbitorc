defmodule Orbitorc.Agent.Command do
  @moduledoc """
  A short-lived operation that runs to completion, as distinct from a job that runs until stopped.

  A sync, a build and a capture all finish on their own and are interesting for their exit status and
  their output. A session does not: it runs until the window closes or somebody stops it, and it is
  interesting for what it streams. The two need different handling, so they are different modules —
  a job is supervised and reaped, a command is awaited and reported.

  **A command is still bounded.** A build that wedged would otherwise hold the box's lease until the
  lease expired, so every command carries a timeout and is killed at it.
  """

  require Logger

  alias Orbitorc.Agent.Platform

  @type result :: %{status: integer() | :timeout, output: String.t()}

  @doc """
  Run `argv` in `dir` and wait for it.

  Output is captured with stderr merged, because the half of a failure that says why is usually on
  stderr and a caller reading one stream would see the other half.
  """
  @spec run([String.t()], Path.t(), keyword()) :: {:ok, result()} | {:error, String.t()}
  def run([executable | args], dir, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 300_000)
    env = Keyword.get(opts, :env, %{})

    case resolve(executable) do
      {:error, reason} ->
        {:error, reason}

      {:ok, path} ->
        task =
          Task.async(fn ->
            System.cmd(path, args,
              cd: dir,
              env: Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end),
              stderr_to_stdout: true
            )
          end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {output, status}} -> {:ok, %{status: status, output: output}}
          nil -> {:ok, %{status: :timeout, output: "no answer in #{div(timeout, 1000)}s; killed"}}
          {:exit, reason} -> {:error, "the command exited: #{inspect(reason)}"}
        end
    end
  end

  @doc """
  Bring a checkout to a named revision.

  ## A sync is a force checkout, which is why it needs the lease

  It fetches, checks the revision out and hard-resets. Anything uncommitted in the tree is gone. That
  is the intended behavior for a box in a fleet — every machine must run the same code or a
  disagreement between them reads as a netcode bug — and it is exactly why a caller mid-measurement
  must be able to hold the box against it.

  The revision is reported back rather than assumed, so a fleet can be checked for agreement instead of
  trusted to have it.

  ## A branch name means the remote's branch

  `sync main` checks out `origin/main`, detached. A box's local `main` is whatever it last checked out
  and never moves on its own, so a checkout of the local branch after a fetch would report success and
  leave the fleet where it was. A sha or a tag is itself.
  """
  @spec sync(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def sync(repo, revision, opts \\ []) do
    with {:ok, fetched} <- run_all([["git", "fetch", "--all", "--prune", "--tags"]], repo, opts),
         target = remote_or_itself(repo, revision, opts),
         steps = [["git", "checkout", "--force", target], ["git", "reset", "--hard", "HEAD"]],
         {:ok, log} <- run_all(steps, repo, opts) do
      {:ok, Map.put(Orbitorc.Agent.Health.revision(repo), "log", fetched <> log)}
    end
  end

  defp remote_or_itself(repo, revision, opts) do
    verify = ["git", "rev-parse", "--verify", "--quiet", "refs/remotes/origin/#{revision}"]

    case run(verify, repo, opts) do
      {:ok, %{status: 0}} -> "origin/#{revision}"
      _ -> revision
    end
  end

  @doc """
  Import the engine project, so the class cache the next launch resolves through describes this tree.

  ## A synced tree with the previous tree's cache does not parse

  The engine resolves every `class_name` through `.godot/global_script_class_cache.cfg`. After a sync
  that cache is whatever the previous checkout left: a class added or renamed since is missing from it,
  every use of it resolves to `Variant`, and a project that promotes that warning to an error dies at
  parse time -- reported three steps from the cause, as a server that never printed its marker. So a
  manifest may ask (`sync.import`) for an import after every sync, and this is it.

  A cold project is imported twice: the first pass is priming (an extension perturbs the build order
  of a cache built from nothing) and is discarded. The engine's exit status is not the verdict -- an
  import prints errors it does not fail on -- the cache file is.
  """
  @spec import_project(String.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def import_project(engine_bin, project_path, opts \\ []) do
    cache = Path.join([project_path, ".godot", "global_script_class_cache.cfg"])
    argv = [engine_bin, "--headless", "--path", project_path, "--import"]
    opts = Keyword.put_new(opts, :timeout_ms, 900_000)
    passes = if File.regular?(cache) and File.stat!(cache).size > 0, do: 1, else: 2

    result =
      Enum.reduce_while(1..passes, {:ok, ""}, fn _pass, _acc ->
        case run(argv, project_path, opts) do
          {:ok, %{output: output}} -> {:cont, {:ok, output}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, output} <- result do
      if File.regular?(cache) and File.stat!(cache).size > 0,
        do: {:ok, %{"ok" => true, "passes" => passes, "cache" => cache}},
        else: {:error, "the import left no class cache at #{cache}: #{tail(output)}"}
    end
  end

  @doc """
  Run a project's own build recipe.

  OrbitOrc does not know how a project builds. The manifest names the command, so this stays a matter
  of running what the project already runs — a box that needed its own idea of a build would drift from
  the project's.

  The artifact's size is asserted against the manifest's floor. A build that "succeeded" and produced a
  stub is the shape that reaches a measurement and reports a confident wrong answer.
  """
  @spec build(Path.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def build(repo, sync_spec, target, opts \\ []) do
    argv = Map.get(sync_spec, "build")

    cond do
      not is_list(argv) or argv == [] ->
        {:error, "this project's manifest declares no build command"}

      target not in Platform.exports() ->
        {:error,
         "this box cannot produce a #{target} build (it can do #{Enum.join(Platform.exports(), ", ")})"}

      true ->
        argv = Enum.map(argv, &String.replace(to_string(&1), "{target}", target))

        with {:ok, %{status: 0, output: output}} <-
               run(argv, repo, Keyword.put_new(opts, :timeout_ms, 900_000)) do
          {:ok, Map.put(assert_artifact(repo, sync_spec, target), "log", output)}
        else
          {:ok, %{status: status, output: output}} ->
            {:error, "the build exited #{status}: #{tail(output)}"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # A build that produced nothing, or produced a stub, has to fail here rather than at the measurement.
  # The search is recursive: an export may land in a per-commit or per-target subdirectory rather than
  # at the top of the declared directory, and a check that looked only there would report a real build
  # as a missing one.
  defp assert_artifact(repo, sync_spec, target) do
    dir = Path.join(repo, Map.get(sync_spec, "build_dir", "build"))
    floor = Map.get(sync_spec, "build_min_bytes", 0)

    case dir
         |> Path.join("**/*" <> target <> "*")
         |> Path.wildcard()
         |> Enum.filter(&File.regular?/1) do
      [] ->
        %{"ok" => false, "detail" => "the build reported success and left nothing in #{dir}"}

      files ->
        sized = Enum.map(files, fn f -> {Path.basename(f), File.stat!(f).size} end)
        undersized = Enum.filter(sized, fn {_, size} -> size < floor end)

        if undersized == [] do
          %{"ok" => true, "artifacts" => Map.new(sized)}
        else
          %{
            "ok" => false,
            "detail" =>
              "a build artifact is smaller than the #{floor} byte floor this project declares: " <>
                (undersized |> Enum.map(fn {n, s} -> "#{n} is #{s}" end) |> Enum.join(", ")),
            "artifacts" => Map.new(sized)
          }
        end
    end
  end

  @doc """
  Capture one window.

  **It captures the target window or it fails; it never falls back to the screen.** A screen grab
  returns whatever happened to be in front, which is a confident answer about the wrong thing — in the
  session that settled this it returned a chat window.
  """
  @spec capture(Path.t(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def capture(out_path, window_hint) do
    case Platform.kind() do
      :macos ->
        with {:ok, id} <- macos_window_id(window_hint),
             {:ok, %{status: 0}} <- run(["screencapture", "-o", "-x", "-l", id, out_path], ".") do
          {:ok, out_path}
        else
          {:ok, %{status: status, output: output}} ->
            {:error, "screencapture exited #{status}: #{tail(output)}"}

          {:error, reason} ->
            {:error, reason}
        end

      :linux ->
        with {:ok, %{status: 0, output: id}} <-
               run(["xdotool", "search", "--name", window_hint], "."),
             id = id |> String.split("\n") |> List.first() |> String.trim(),
             {:ok, %{status: 0}} <- run(["import", "-window", id, out_path], ".") do
          {:ok, out_path}
        else
          {:ok, %{status: status, output: output}} ->
            {:error, "the capture exited #{status}: #{tail(output)}"}

          {:error, reason} ->
            {:error, reason}
        end

      :windows ->
        windows_capture(out_path, window_hint)
    end
  end

  # PrintWindow asks the window to paint itself into a bitmap, which is a capture of THAT window even
  # when another sits in front of it. A screen-region copy of the window's rectangle would not be.
  defp windows_capture(out_path, hint) do
    script = """
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.Drawing
    Add-Type -Namespace Orbitorc -Name Win -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr hwnd, System.IntPtr hdc, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hwnd, out RECT rect);
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    '@
    $p = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like ('*' + $env:ORBITORC_HINT + '*') } | Select-Object -First 1
    if (-not $p) { exit 2 }
    $r = New-Object Orbitorc.Win+RECT
    [void][Orbitorc.Win]::GetWindowRect($p.MainWindowHandle, [ref]$r)
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { exit 3 }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [Orbitorc.Win]::PrintWindow($p.MainWindowHandle, $hdc, 2)
    $g.ReleaseHdc($hdc)
    if (-not $ok) { exit 4 }
    $bmp.Save($env:ORBITORC_OUT, [System.Drawing.Imaging.ImageFormat]::Png)
    """

    case run(["powershell", "-NoProfile", "-Command", script], ".",
           env: %{"ORBITORC_HINT" => hint, "ORBITORC_OUT" => out_path},
           timeout_ms: 30_000
         ) do
      {:ok, %{status: 0}} ->
        {:ok, out_path}

      {:ok, %{status: 2}} ->
        {:error, "no window matching #{inspect(hint)} on this box"}

      {:ok, %{status: 3}} ->
        {:error, "the window matching #{inspect(hint)} has no size (minimized?)"}

      {:ok, %{status: 4}} ->
        {:error, "the window refused to paint itself; no screen fallback is offered"}

      {:ok, %{status: status, output: output}} ->
        {:error, "capture exited #{status}: #{tail(output)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp macos_window_id(hint) do
    script =
      ~s|tell application "System Events" to get id of first window of (first process whose name contains "#{hint}")|

    case run(["osascript", "-e", script], ".") do
      {:ok, %{status: 0, output: out}} -> {:ok, String.trim(out)}
      _ -> {:error, "no window matching #{inspect(hint)} on this box"}
    end
  end

  defp run_all(steps, dir, opts) do
    Enum.reduce_while(steps, {:ok, ""}, fn argv, {:ok, acc} ->
      case run(argv, dir, opts) do
        {:ok, %{status: 0, output: output}} ->
          {:cont, {:ok, acc <> output}}

        {:ok, %{status: status, output: output}} ->
          {:halt, {:error, "#{Enum.join(argv, " ")} exited #{status}: #{tail(output)}"}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve(executable) do
    cond do
      File.exists?(executable) -> {:ok, Path.expand(executable)}
      path = System.find_executable(executable) -> {:ok, path}
      true -> {:error, "#{executable} is neither a file nor on PATH"}
    end
  end

  defp tail(output),
    do: output |> String.split("\n") |> Enum.take(-8) |> Enum.join("\n") |> String.trim()
end
