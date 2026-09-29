defmodule Orbitorc.Agent.Platform do
  @moduledoc """
  What this box is, asked of the box rather than assumed.

  ## Why a graphical session is a first-class health signal

  A process launched outside the graphical login session gets a non-interactive window station on
  Windows, no display on Linux and no Aqua session on macOS. A rendering job launched that way draws
  nothing **and reports success**. That is the failure this module exists to catch, and it is why an
  agent is installed into the login session rather than started by a service manager or over a remote
  shell.

  A box with no session is still useful — a sync, a build and a headless authority are all valid there.
  It refuses the rendering modes, and says why.

  ## Why game traffic uses the LAN address

  The control plane may cross a VPN. The session under measurement must not: routing it through
  WireGuard would put encryption and a userspace hop inside the thing being measured. `lan_address/0`
  is what a bringup reports for other machines to join, whatever path the control plane took.
  """

  require Logger

  @type kind :: :windows | :macos | :linux

  @doc "Which family of box this is."
  @spec kind() :: kind()
  def kind do
    case :os.type() do
      {:win32, _} -> :windows
      {:unix, :darwin} -> :macos
      {:unix, _} -> :linux
    end
  end

  @doc """
  The processor architecture, in the words a release is named by: `x64` or `arm64`.

  Windows reports it in the environment; the BEAM's `system_architecture` there is only `win32`.
  """
  @spec arch() :: String.t()
  def arch do
    raw =
      case kind() do
        :windows ->
          System.get_env("PROCESSOR_ARCHITEW6432") || System.get_env("PROCESSOR_ARCHITECTURE") ||
            ""

        _ ->
          :erlang.system_info(:system_architecture) |> to_string()
      end

    cond do
      raw =~ ~r/aarch64|arm64/i -> "arm64"
      raw =~ ~r/x86_64|amd64/i -> "x64"
      true -> String.downcase(raw)
    end
  end

  @doc "Where this box keeps its agent configuration, jobs and audit log."
  @spec config_dir() :: Path.t()
  def config_dir do
    case kind() do
      :windows ->
        Path.join(
          System.get_env("LOCALAPPDATA") || Path.join(System.user_home!(), "AppData/Local"),
          "orbitorc"
        )

      :macos ->
        Path.join(System.user_home!(), "Library/Application Support/orbitorc")

      :linux ->
        Path.join(
          System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config"),
          "orbitorc"
        )
    end
  end

  @doc """
  Whether a rendering job could present a window here, and a line saying why not.

  False does not stop the agent. It stops the rendering modes.
  """
  @spec session_ok() :: {boolean(), String.t()}
  def session_ok do
    case kind() do
      :windows -> windows_session()
      :macos -> macos_session()
      :linux -> linux_session()
    end
  end

  # Session 0 is the service session: no window station an application can present into. An agent
  # started by a "run whether or not the user is logged on" task lands there, which is exactly the
  # misconfiguration this catches.
  defp windows_session do
    case run("powershell", ["-NoProfile", "-Command", "(Get-Process -Id $PID).SessionId"]) do
      {:ok, out} ->
        case Integer.parse(String.trim(out)) do
          {0, _} -> {false, "running in session 0 (the service session) — no interactive desktop"}
          {id, _} -> {true, "interactive session #{id}"}
          :error -> {false, "session probe returned #{inspect(String.trim(out))}"}
        end

      {:error, reason} ->
        {false, "session probe failed: #{reason}"}
    end
  end

  # launchctl reports the domain a process was launched into. Aqua is the graphical login session;
  # System means it was installed as a daemon, which can never present a window.
  defp macos_session do
    case run("launchctl", ["managername"]) do
      {:ok, "Aqua" <> _} ->
        {true, "Aqua session"}

      {:ok, out} ->
        {false,
         "launchd domain is #{inspect(String.trim(out))}, not Aqua (installed as a daemon?)"}

      {:error, reason} ->
        {false, "launchctl probe failed: #{reason}"}
    end
  end

  defp linux_session do
    cond do
      display = System.get_env("WAYLAND_DISPLAY") -> {true, "wayland display #{display}"}
      display = System.get_env("DISPLAY") -> {true, "x11 display #{display}"}
      true -> {false, "no DISPLAY or WAYLAND_DISPLAY — headless modes only"}
    end
  end

  @doc """
  Kill a launched process.

  Closing a port does not kill its child: the BEAM closes the pipes and waits. So the OS pid is killed
  explicitly.

  **What this reaches.** On Windows, `taskkill /T` takes the whole tree. On macOS and Linux a child
  spawned through a port is in the agent's own process group, so there is no group to signal; the pid
  itself is killed, and anything it started is not. That is why the manifest launches the raw engine
  binary and never a wrapper script — a wrapper that ran the engine inside a process substitution would
  be the only thing this reached, and the engine would keep its port.
  """
  @spec kill_tree(pos_integer()) :: :ok
  def kill_tree(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case kind() do
      :windows -> run("taskkill", ["/T", "/F", "/PID", Integer.to_string(os_pid)])
      _ -> run("/bin/sh", ["-c", "kill -9 #{os_pid} 2>/dev/null; exit 0"])
    end

    :ok
  end

  @doc "The engine's own version line, or an error. Recorded per box so a fleet can be held to one."
  @spec engine_version(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def engine_version(engine_bin) do
    case run(engine_bin, ["--version"]) do
      {:ok, out} ->
        case out
             |> String.split(["\r\n", "\n"])
             |> Enum.map(&String.trim/1)
             |> Enum.reject(&(&1 == "")) do
          [line | _] -> {:ok, line}
          [] -> {:error, "the engine printed no version"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Export targets this platform can actually produce.

  macOS is the hard one: its preset ad-hoc codesigns, and only a Mac can — the same constraint that
  makes a release pipeline keep a native runner per platform.
  """
  @spec exports() :: [String.t()]
  def exports do
    case kind() do
      :windows -> ["windows"]
      :macos -> ["macos"]
      :linux -> ["linux", "server"]
    end
  end

  @doc """
  This box's LAN address — what other machines join, whatever path the control plane took.

  Skips loopback, link-local and the tunnel interfaces a VPN adds, because a session routed through a
  tunnel measures the tunnel.
  """
  @spec lan_address() :: String.t() | nil
  def lan_address do
    case :inet.getifaddrs() do
      {:ok, interfaces} ->
        interfaces
        |> Enum.reject(fn {name, _opts} -> tunnel_interface?(to_string(name)) end)
        |> Enum.flat_map(fn {_name, opts} -> Keyword.get_values(opts, :addr) end)
        |> Enum.find_value(&routable_v4/1)

      _ ->
        nil
    end
  end

  # Tunnels a session must not ride, and the virtual bridges a container or VM host adds. A bridge
  # answers to nothing across the LAN, and a box that advertised one would be joined by nobody.
  defp tunnel_interface?(name) do
    String.starts_with?(name, [
      "lo",
      "tailscale",
      "wg",
      "utun",
      "tun",
      "tap",
      "ppp",
      "zt",
      "docker",
      "br-",
      "bridge",
      "veth",
      "vmnet",
      "vboxnet",
      "virbr",
      "anpi",
      "awdl",
      "llw"
    ])
  end

  defp routable_v4({a, b, _, _} = addr) when a in 1..223 do
    cond do
      a == 127 -> nil
      a == 169 and b == 254 -> nil
      true -> addr |> :inet.ntoa() |> to_string()
    end
  end

  defp routable_v4(_), do: nil

  @doc "Whether a tool is on PATH."
  @spec tool?(String.t()) :: boolean()
  def tool?(name), do: System.find_executable(name) != nil

  # A short, bounded probe. Never used to launch a job -- jobs go through a port so the BEAM owns them.
  defp run(cmd, args) do
    case System.find_executable(cmd) || (File.exists?(cmd) && cmd) do
      false ->
        {:error, "#{cmd} is not on PATH"}

      nil ->
        {:error, "#{cmd} is not on PATH"}

      path ->
        try do
          case System.cmd(path, args, stderr_to_stdout: true) do
            {out, 0} -> {:ok, out}
            {out, code} -> {:error, "#{cmd} exited #{code}: #{String.trim(out)}"}
          end
        rescue
          error -> {:error, Exception.message(error)}
        end
    end
  end
end
