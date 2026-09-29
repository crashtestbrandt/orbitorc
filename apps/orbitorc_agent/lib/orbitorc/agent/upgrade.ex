defmodule Orbitorc.Agent.Upgrade do
  @moduledoc """
  Replace this agent with a release, and get out of the way.

  ## The service manager restarts it; the agent only exits

  Every install unit already restarts the agent — a LaunchAgent with `KeepAlive`, a systemd unit with
  `Restart=always`, a scheduled task that restarts on failure. So an upgrade is: fetch the archive,
  check it against its sha256, unpack it beside the running release, swap the two, exit. Nothing here
  starts anything.

  ## On Windows the swap happens after the exit

  A running BEAM has its executables and libraries mapped, and Windows refuses to rename a directory
  holding an open file. So on Windows the agent writes a small script, starts it outside its own
  process tree (through WMI, so it survives the agent's exit), and exits; the script waits for the
  agent's pid, swaps the directories, and starts the scheduled task. On macOS and Linux the swap is
  done here, before the exit.

  ## The previous release stays

  The running release becomes `<root>.old`, one generation, for a rollback by hand.
  """

  require Logger

  alias Orbitorc.Agent.Platform

  @type option ::
          {:root, Path.t() | nil}
          | {:platform, Platform.kind()}
          | {:fetch, (String.t() -> {:ok, binary()} | {:error, String.t()})}
          | {:launch, (Path.t() -> :ok | {:error, String.t()})}
          | {:os_pid, String.t()}

  @doc """
  Stage a release from `url`, verified against `sha256` (or against `url <> ".sha256"` when none is
  given), and swap it in — now on Unix, after the exit on Windows.
  """
  @spec stage(String.t(), String.t() | nil, [option()]) :: {:ok, map()} | {:error, String.t()}
  def stage(url, sha256, opts \\ []) do
    fetch = Keyword.get(opts, :fetch, &download/1)
    platform = Keyword.get(opts, :platform, Platform.kind())

    with {:ok, root} <- running_from_release(Keyword.get(opts, :root, release_root())),
         {:ok, archive} <- fetch.(url),
         {:ok, expected} <- expected_sha(sha256, url, fetch),
         :ok <- verify(archive, expected),
         {:ok, staged} <- unpack(archive, url, root),
         {:ok, version} <- version_of(staged),
         :ok <- swap(platform, root, staged, opts) do
      Logger.info(
        "orbitorc: release #{version} staged; exiting so the service manager restarts it"
      )

      {:ok,
       %{
         "version" => version,
         "root" => root,
         "swap" => if(platform == :windows, do: "after exit", else: "done"),
         "restart" => "the service manager brings the new release up"
       }}
    end
  end

  @doc "The directory this release runs from, as the release scripts set it."
  def release_root, do: System.get_env("RELEASE_ROOT")

  defp running_from_release(nil),
    do: {:error, "this agent is not running from a release, so it cannot replace itself"}

  defp running_from_release(root) do
    if File.dir?(Path.join(root, "bin")) and File.dir?(Path.join(root, "releases")),
      do: {:ok, Path.expand(root)},
      else: {:error, "#{root} is not a release directory"}
  end

  # --- fetching -------------------------------------------------------------------------------------

  defp download(url) do
    request = {String.to_charlist(url), [{~c"user-agent", ~c"orbitorc-agent"}]}

    http_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ],
      timeout: 300_000,
      connect_timeout: 30_000,
      autoredirect: true
    ]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _headers, _body}} -> {:error, "#{url} answered #{status}"}
      {:error, reason} -> {:error, "could not fetch #{url}: #{inspect(reason)}"}
    end
  end

  # The checksum comes from the caller, or from the `.sha256` CI attached beside the archive.
  defp expected_sha(sha, _url, _fetch) when is_binary(sha) and byte_size(sha) == 64,
    do: {:ok, String.downcase(sha)}

  defp expected_sha(sha, _url, _fetch) when is_binary(sha) and sha != "",
    do: {:error, "a sha256 is 64 hex characters, not #{inspect(sha)}"}

  defp expected_sha(_none, url, fetch) do
    case fetch.(url <> ".sha256") do
      {:ok, body} ->
        case body |> String.trim() |> String.split(~r/\s+/) do
          [sha | _] when byte_size(sha) == 64 -> {:ok, String.downcase(sha)}
          _ -> {:error, "#{url}.sha256 does not carry a checksum"}
        end

      {:error, reason} ->
        {:error, "no checksum was given and none could be fetched: #{reason}"}
    end
  end

  defp verify(archive, expected) do
    actual = :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower)

    if actual == expected,
      do: :ok,
      else: {:error, "the archive's sha256 is #{actual}, not the expected #{expected}"}
  end

  # --- unpacking ------------------------------------------------------------------------------------

  # Into `<parent>/orbitorc_agent.staging`, then the release directory inside it: CI's archives wrap
  # the release in `orbitorc_agent/`, a hand-made one may not.
  defp unpack(archive, url, root) do
    staging = Path.join(Path.dirname(root), Path.basename(root) <> ".staging")
    File.rm_rf(staging)
    File.mkdir_p!(staging)

    result =
      if String.ends_with?(url, ".zip") do
        case :zip.unzip(archive, cwd: String.to_charlist(staging)) do
          {:ok, _files} -> :ok
          {:error, reason} -> {:error, "could not unzip the archive: #{inspect(reason)}"}
        end
      else
        case :erl_tar.extract({:binary, archive}, [
               :compressed,
               {:cwd, String.to_charlist(staging)}
             ]) do
          :ok -> :ok
          {:error, reason} -> {:error, "could not untar the archive: #{inspect(reason)}"}
        end
      end

    with :ok <- result do
      candidates = [Path.join(staging, Path.basename(root)), staging]

      case Enum.find(candidates, &release_dir?/1) do
        nil -> {:error, "the archive holds no release (no bin/ and releases/ inside)"}
        dir -> {:ok, dir}
      end
    end
  end

  defp release_dir?(dir),
    do: File.dir?(Path.join(dir, "bin")) and File.dir?(Path.join(dir, "releases"))

  defp version_of(dir) do
    case File.read(Path.join([dir, "releases", "start_erl.data"])) do
      {:ok, data} ->
        case data |> String.trim() |> String.split(~r/\s+/) do
          [_erts, version | _] -> {:ok, version}
          _ -> {:error, "the release does not say its version"}
        end

      {:error, _} ->
        {:error, "the release does not say its version"}
    end
  end

  # --- swapping -------------------------------------------------------------------------------------

  defp swap(:windows, root, staged, opts) do
    parent = Path.dirname(root)
    script = Path.join(parent, "orbitorc_agent.upgrade.ps1")
    log = Path.join(parent, "upgrade.log")
    os_pid = Keyword.get(opts, :os_pid, System.pid())
    launch = Keyword.get(opts, :launch, &launch_detached/1)

    File.write!(script, windows_script(root, staged, os_pid, log))
    launch.(script)
  end

  defp swap(_unix, root, staged, _opts) do
    old = root <> ".old"
    File.rm_rf(old)

    with :ok <- rename(root, old),
         :ok <- rename(staged, root) do
      File.rm_rf(Path.join(Path.dirname(root), Path.basename(root) <> ".staging"))
      :ok
    end
  end

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not move #{from} to #{to}: #{inspect(reason)}"}
    end
  end

  # Waits for this agent to exit, swaps, and starts the scheduled task the install script registers.
  # The task's own restart-on-failure would bring the agent up within a minute anyway; the start here
  # only makes it sooner, and is harmless when the task is already running.
  @doc false
  def windows_script(root, staged, os_pid, log) do
    root = win_path(root)
    staged = win_path(staged)
    old = root <> ".old"
    staging = win_path(Path.join(Path.dirname(root), Path.basename(root) <> ".staging"))

    """
    $ErrorActionPreference = 'Stop'
    $log = '#{win_path(log)}'
    function Note($m) { "$(Get-Date -Format s) $m" | Add-Content $log }
    Note "waiting for the agent (pid #{os_pid}) to exit"
    Wait-Process -Id #{os_pid} -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    # Anything still running out of the release directory holds it against the rename: the first
    # release started an epmd that outlived it, the move failed, and the staged release landed inside
    # the old one. Stop them, then move only when the move has actually happened.
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like '#{root}\\*' } | ForEach-Object {
      Note "stopping $($_.Name) (pid $($_.ProcessId)) still running out of the release"
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    try {
      if (Test-Path '#{old}') { Remove-Item -Recurse -Force '#{old}' }
      $moved = $false
      for ($i = 0; $i -lt 10 -and -not $moved; $i++) {
        try { Move-Item -Path '#{root}' -Destination '#{old}' -ErrorAction Stop; $moved = $true } catch { Start-Sleep -Seconds 2 }
      }
      if (-not $moved) { throw "could not move #{root} aside; something still holds it" }
      Move-Item -Path '#{staged}' -Destination '#{root}' -ErrorAction Stop
      if (Test-Path '#{staging}') { Remove-Item -Recurse -Force '#{staging}' -ErrorAction SilentlyContinue }
      Note "swapped in the staged release"
    } catch {
      Note "SWAP FAILED: $($_.Exception.Message); the previous release stays in place"
    }
    Start-ScheduledTask -TaskName 'OrbitOrc Agent' -ErrorAction SilentlyContinue
    """
  end

  @doc false
  def win_path(path), do: String.replace(path, "/", "\\")

  # Through WMI, so the script is not a child of this process and outlives it.
  defp launch_detached(script) do
    command =
      "Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=" <>
        "'powershell -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"#{script}\"'} | Out-Null"

    case System.cmd("powershell", ["-NoProfile", "-NonInteractive", "-Command", command],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> :ok
      {out, code} -> {:error, "could not start the swap script (#{code}): #{String.trim(out)}"}
    end
  rescue
    error -> {:error, "could not start the swap script: #{Exception.message(error)}"}
  end
end
