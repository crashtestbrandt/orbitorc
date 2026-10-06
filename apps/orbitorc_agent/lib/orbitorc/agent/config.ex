defmodule Orbitorc.Agent.Config do
  @moduledoc """
  What this box is allowed to do, and for which projects.

  The configuration is a file **on the box**, never something a caller can change over the wire. That
  placement is the point: a remote caller can drive what the box already offers and nothing more.

  ## Shape

      {
        "control_plane": "wss://orbitorc.example:4000/agent/websocket",
        "name": "win",
        "token": "…",
        "projects": [
          { "name": "orbitnet", "repo": "C:/boxes/orbitnet", "engine_bin": "C:/engines/godot.exe" }
        ],
        "game_port": 47900,
        "relay_port": 47910,
        "job_retention": 200,
        "lan": "192.168.1.20"
      }

  | Key | |
  | --- | --- |
  | `control_plane` | Where the agent dials out to. The agent connects; nothing connects to it. |
  | `name` | How this box appears in the fleet. |
  | `token` | Proves this box to the control plane. One per box, so one box can be revoked alone. |
  | `projects` | Each with its own checkout and its own engine binary. **Never a checkout a CI runner shares**: a runner deletes and re-fetches its tools mid-job, which would remove the engine from under a live measurement. |
  | `game_port` / `relay_port` | The band a job binds. Kept away from the ports a project's own CI harnesses use, so a job here can never collide with a build on the same box. |
  | `lan` | Optional. The IPv4 address other machines join this box at. Without it the agent picks one (`Orbitorc.Agent.Platform.lan_address/0`); set it on a box with more than one network, such as Wi-Fi beside Ethernet or a VPN. |
  """

  @default_game_port 47900
  @default_relay_port 47910
  @default_job_retention 200

  @enforce_keys [:control_plane, :name, :token]
  defstruct control_plane: nil,
            name: nil,
            token: nil,
            projects: %{},
            manifests: %{},
            game_port: @default_game_port,
            relay_port: @default_relay_port,
            job_retention: @default_job_retention,
            lan: nil,
            jobs_dir: nil,
            source: nil

  @type t :: %__MODULE__{}

  @doc "The file this box reads its configuration from."
  @spec path() :: Path.t()
  def path, do: Path.join(Orbitorc.Agent.Platform.config_dir(), "config.json")

  @doc """
  Load and validate the configuration, then read every project's manifest.

  A project whose manifest is missing or malformed is **reported, not fatal**: the box still serves the
  projects that are fine, and `doctor` names the one that is not. A box that refused to start over one
  bad checkout would take the whole fleet down for a typo.
  """
  @spec load(Path.t() | nil) :: {:ok, t(), [String.t()]} | {:error, String.t()}
  def load(config_path \\ nil) do
    config_path = config_path || path()

    with {:ok, body} <- read(config_path),
         {:ok, raw} <- decode(config_path, body),
         {:ok, base} <- validate(raw, config_path) do
      {config, problems} = load_manifests(base)
      {:ok, config, problems}
    end
  end

  defp read(config_path) do
    case File.read(config_path) do
      {:ok, body} ->
        {:ok, body}

      {:error, :enoent} ->
        {:error, "no configuration at #{config_path}"}

      {:error, reason} ->
        {:error, "#{config_path} is not readable (#{:file.format_error(reason)})"}
    end
  end

  defp decode(config_path, body) do
    case Jason.decode(body) do
      {:ok, raw} when is_map(raw) -> {:ok, raw}
      {:ok, _} -> {:error, "#{config_path} must hold a JSON object"}
      {:error, err} -> {:error, "#{config_path} is not readable JSON: #{Exception.message(err)}"}
    end
  end

  defp validate(raw, config_path) do
    raw = Map.reject(raw, fn {k, _} -> String.starts_with?(to_string(k), "_") end)

    with {:ok, control_plane} <- nonempty(raw, "control_plane"),
         {:ok, name} <- nonempty(raw, "name"),
         {:ok, token} <- nonempty(raw, "token"),
         {:ok, lan} <- lan(raw),
         {:ok, projects} <- projects(raw) do
      {:ok,
       %__MODULE__{
         control_plane: control_plane,
         name: name,
         token: token,
         projects: projects,
         game_port: int(raw, "game_port", @default_game_port),
         relay_port: int(raw, "relay_port", @default_relay_port),
         job_retention: int(raw, "job_retention", @default_job_retention),
         lan: lan,
         jobs_dir:
           Map.get(raw, "jobs_dir") || Path.join(Orbitorc.Agent.Platform.config_dir(), "jobs"),
         source: config_path
       }}
    end
  end

  defp nonempty(raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "the configuration declares no #{key}"}
    end
  end

  # A wrong address here sends every client to a box that is not listening, so anything that is not a
  # dotted IPv4 address refuses to load rather than being ignored.
  defp lan(raw) do
    case Map.get(raw, "lan") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case :inet.parse_ipv4strict_address(String.to_charlist(value)) do
          {:ok, _} -> {:ok, value}
          {:error, _} -> {:error, "lan must be a dotted IPv4 address, not #{inspect(value)}"}
        end

      value ->
        {:error, "lan must be a dotted IPv4 address, not #{inspect(value)}"}
    end
  end

  defp int(raw, key, default) do
    case Map.get(raw, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp projects(raw) do
    case Map.get(raw, "projects") do
      list when is_list(list) and list != [] ->
        Enum.reduce_while(list, {:ok, %{}}, fn entry, {:ok, acc} ->
          case project(entry) do
            {:ok, name, spec} -> {:cont, {:ok, Map.put(acc, name, spec)}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      _ ->
        {:error, "the configuration declares no projects, so this box can serve nothing"}
    end
  end

  defp project(%{"name" => name, "repo" => repo} = entry)
       when is_binary(name) and is_binary(repo) do
    {:ok, name,
     %{
       name: name,
       repo: Path.expand(repo),
       engine_bin: Map.get(entry, "engine_bin") || "godot",
       exported_dir: Map.get(entry, "exported_dir")
     }}
  end

  defp project(entry), do: {:error, "a project entry needs a name and a repo: #{inspect(entry)}"}

  defp load_manifests(%__MODULE__{projects: projects} = config) do
    {manifests, problems} =
      Enum.reduce(projects, {%{}, []}, fn {name, spec}, {ok, bad} ->
        case Orbitorc.Manifest.load(spec.repo) do
          {:ok, manifest} -> {Map.put(ok, name, manifest), bad}
          {:error, reason} -> {ok, ["#{name}: #{reason}" | bad]}
        end
      end)

    {%{config | manifests: manifests}, Enum.reverse(problems)}
  end

  @doc "The project spec and its manifest, or an error naming what the box does serve."
  @spec fetch_project(t(), String.t()) ::
          {:ok, map(), Orbitorc.Manifest.t()} | {:error, String.t()}
  def fetch_project(%__MODULE__{} = config, name) do
    case {Map.fetch(config.projects, name), Map.fetch(config.manifests, name)} do
      {{:ok, spec}, {:ok, manifest}} ->
        {:ok, spec, manifest}

      {{:ok, _}, :error} ->
        {:error,
         "#{name} is configured here but its checkout carries no usable #{Orbitorc.Manifest.manifest_name()}"}

      _ ->
        {:error, serves_no(config, name)}
    end
  end

  @doc """
  The project spec alone, for a verb that needs the checkout and not what it declares.

  A sync is the one that must work before there is a manifest: it is how a fresh checkout gets one.
  Requiring the manifest there left a new box unable to fetch the file that would have satisfied
  the requirement.
  """
  @spec fetch_spec(t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def fetch_spec(%__MODULE__{} = config, name) do
    case Map.fetch(config.projects, name) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, serves_no(config, name)}
    end
  end

  @doc """
  Re-read one project's manifest from its checkout.

  After a sync the tree is not the one the agent started with: a manifest may have appeared, changed
  or gone. The result is the configuration with that project's manifest as the checkout has it now,
  and the problem to report when it has none.
  """
  @spec reload_manifest(t(), String.t()) :: {t(), String.t() | nil}
  def reload_manifest(%__MODULE__{} = config, name) do
    with {:ok, spec} <- fetch_spec(config, name),
         {:ok, manifest} <- Orbitorc.Manifest.load(spec.repo) do
      {%{config | manifests: Map.put(config.manifests, name, manifest)}, nil}
    else
      {:error, reason} ->
        {%{config | manifests: Map.delete(config.manifests, name)}, "#{name}: #{reason}"}
    end
  end

  defp serves_no(config, name) do
    served = config.projects |> Map.keys() |> Enum.sort() |> Enum.join(", ")
    "this box serves no project #{inspect(name)} (it serves #{served})"
  end
end
