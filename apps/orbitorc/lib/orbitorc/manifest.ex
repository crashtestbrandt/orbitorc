defmodule Orbitorc.Manifest do
  @moduledoc """
  What a project may launch, declared as data in its own tree.

  OrbitOrc drives more than one repository from one fleet, and the only thing that differs between
  them is the **command line**. Tokens, leases, job directories, readiness, teardown and artifact
  collection are the same whatever is being launched. So the argv lives in an `orbitorc.json` each
  project ships at its root, and an agent reads it out of the checkout it was pointed at.

  ## A manifest is data, never code

  An agent already runs an engine binary out of a synced checkout, which is a trust boundary. It will
  not also evaluate code from one. A declarative table can be validated, diffed and pinned by a test
  with no engine and no project anywhere near it, and `build_argv/4` stays the pure function it has to
  be.

  ## Shape

      {
        "schema": 1,
        "project": "orbitnet",
        "engine_project": "demos/arena",
        "ports": { "game": 47900, "relay": 47910 },
        "modes": {
          "server": {
            "ready": "-STATE PLAYING",
            "gui": false,
            "env": { "ORBITNET_DEBUG": "1" },
            "engine": ["--headless"],
            "argv": ["--dedicated={port}", "--quit-after={quit_after}"],
            "defaults": { "port": 47900 },
            "required": []
          }
        }
      }

  | Key | |
  | --- | --- |
  | `engine_project` | Directory holding the engine project file, relative to the checkout. `.` when the root is the project. |
  | `ready` | The line that proves the mode came up. Absent means the mode has no universal ready line and is reported as launched. |
  | `gui` | The mode renders, so it needs a graphical session. Forcing headless waives it. |
  | `env` | Added to the job's environment. |
  | `engine` | Arguments before the `--`, where the engine reads them. |
  | `script` | Run a script rather than the main scene. |
  | `scene` | A scene path, positional, before the `--`. |
  | `argv` | Arguments after the `--`, where the game reads them. |
  | `defaults` | Values used for parameters the caller left out. |
  | `required` | Parameters with no default that the caller must supply. |

  ## Substitution

  A token is either a string or `%{"arg" => ..., "if" => param, "unless" => param}`.

    * `{name}` and `{dotted.name}` interpolate a parameter. **A token whose placeholder has no value is
      dropped whole**, which is what makes an optional flag optional without a branch per flag.
    * A token with no placeholder is always emitted.
    * `if` emits the token only when that parameter is truthy; `unless` suppresses it when that
      parameter has a value. The pair covers the one case interpolation alone cannot: a fallback flag
      that applies only when a richer one was not given.
    * A number formats without a trailing `.0`, so `--radius=500` reads as it was written.
  """

  @manifest_name "orbitorc.json"
  @supported_schemas [1]

  @placeholder ~r/\{([A-Za-z_][A-Za-z0-9_.]*)\}/

  @enforce_keys [:project, :modes]
  defstruct project: nil,
            engine_project: ".",
            ports: %{},
            modes: %{},
            sync: %{},
            checks: %{},
            measurement: %{},
            events: %{},
            source: nil

  @type t :: %__MODULE__{}

  @doc "The file a project ships at its root."
  def manifest_name, do: @manifest_name

  @doc """
  Read and validate a manifest from a checkout.

  A project with no manifest is refused by name: OrbitOrc launches nothing it was not told about.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(repo) do
    path = Path.join(repo, @manifest_name)

    with {:ok, body} <- read(path),
         {:ok, raw} <- decode(path, body) do
      parse(raw, path)
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error,
         "#{path} is not readable (#{:file.format_error(reason)}), so nothing can be launched from that checkout"}
    end
  end

  defp decode(path, body) do
    case Jason.decode(body) do
      {:ok, raw} when is_map(raw) -> {:ok, raw}
      {:ok, _} -> {:error, "#{path} must hold a JSON object"}
      {:error, err} -> {:error, "#{path} is not readable JSON: #{Exception.message(err)}"}
    end
  end

  @doc "Validate an already-decoded manifest. Pure, so a test needs no file."
  @spec parse(map(), Path.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def parse(raw, source \\ nil) when is_map(raw) do
    raw = Map.reject(raw, fn {k, _} -> String.starts_with?(to_string(k), "_") end)

    with :ok <- check_schema(raw),
         {:ok, project} <- required_string(raw, "project"),
         {:ok, modes} <- check_modes(raw, project) do
      {:ok,
       %__MODULE__{
         project: project,
         engine_project: Map.get(raw, "engine_project", "."),
         ports: Map.new(Map.get(raw, "ports", %{}), fn {k, v} -> {to_string(k), v} end),
         modes: modes,
         sync: Map.get(raw, "sync", %{}),
         checks: Map.get(raw, "checks", %{}),
         measurement: Map.get(raw, "measurement", %{}),
         events: Map.get(raw, "events", %{}),
         source: source
       }}
    end
  end

  defp check_schema(%{"schema" => s}) when s in @supported_schemas, do: :ok

  defp check_schema(%{"schema" => s}),
    do:
      {:error,
       "manifest schema #{inspect(s)} is not one this version understands (#{Enum.join(@supported_schemas, ", ")})"}

  defp check_schema(_), do: {:error, "manifest declares no schema version"}

  defp required_string(raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "manifest declares no #{key}"}
    end
  end

  defp check_modes(raw, project) do
    case Map.get(raw, "modes") do
      modes when is_map(modes) and map_size(modes) > 0 ->
        Enum.reduce_while(modes, {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
          case check_mode(project, to_string(name), spec) do
            :ok -> {:cont, {:ok, Map.put(acc, to_string(name), spec)}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      _ ->
        {:error, "manifest for #{project} declares no modes"}
    end
  end

  defp check_mode(project, name, spec) when is_map(spec) do
    Enum.find_value(["engine", "argv"], :ok, fn key ->
      case Map.get(spec, key) do
        nil -> nil
        value when is_list(value) -> nil
        _ -> {:error, "#{project} mode #{name}: #{key} must be a list"}
      end
    end)
  end

  defp check_mode(project, name, _), do: {:error, "#{project} mode #{name} is not an object"}

  # --- queries -------------------------------------------------------------------------------------

  @doc "Every mode this project declares, sorted."
  def mode_names(%__MODULE__{modes: modes}), do: modes |> Map.keys() |> Enum.sort()

  @doc "Whether the project declares this mode."
  def mode?(%__MODULE__{modes: modes}, mode), do: Map.has_key?(modes, mode)

  @doc "The line that proves `mode` came up, or `nil` when it declares none."
  def ready_marker(%__MODULE__{modes: modes}, mode) do
    case get_in(modes, [mode, "ready"]) do
      marker when is_binary(marker) and marker != "" -> marker
      _ -> nil
    end
  end

  @doc "Whether `mode` renders and therefore needs a graphical session."
  def needs_gui?(%__MODULE__{modes: modes}, mode), do: !!get_in(modes, [mode, "gui"])

  @doc """
  What a caller must and may supply to launch `mode`.

  This is what a form or a usage line is built from: the parameters with defaults, the ones that must
  be given, whether the mode renders, whether it takes a scene, and the marker that proves it came up.
  """
  @spec mode_params(t(), String.t()) :: map() | nil
  def mode_params(%__MODULE__{modes: modes} = man, mode) do
    case Map.fetch(modes, mode) do
      {:ok, spec} ->
        %{
          "defaults" => Map.get(spec, "defaults", %{}),
          "required" => spec |> Map.get("required", []) |> Enum.map(&to_string/1),
          "gui" => !!Map.get(spec, "gui"),
          "scene" => Map.has_key?(spec, "scene"),
          "ready" => ready_marker(man, mode)
        }

      :error ->
        nil
    end
  end

  @doc "Environment this mode adds to a job."
  def env(%__MODULE__{modes: modes}, mode) do
    modes
    |> get_in([mode, "env"])
    |> Kernel.||(%{})
    |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  @doc "The directory holding the engine project file, for a given checkout."
  def project_path(%__MODULE__{engine_project: sub}, repo) when sub in ["", "."], do: repo
  def project_path(%__MODULE__{engine_project: sub}, repo), do: Path.join(repo, sub)

  # --- argv ----------------------------------------------------------------------------------------

  @doc """
  Build the exact command line for one job.

  Pure — no filesystem, no environment, no processes — so a test pins it with no engine anywhere near
  it. That matters more than it sounds: the argv is the single thing most likely to be wrong in a
  remote harness, and the failure it produces is a confident answer about the wrong world.

  ## Options

    * `:engine_bin` — the engine binary. Required unless `:exported_bin` is given.
    * `:repo` — the checkout the job runs from.
    * `:log_path` — where the job writes its log. **Every job writes one**: a GUI-subsystem binary on
      Windows never attaches stdout, so redirection alone loses the log on exactly the platform a
      remote fleet exists to reach. The engine's own log flag works everywhere, so it is used
      everywhere rather than branched on.
    * `:exported_bin` — run a built artifact instead of the engine plus a project path. It boots its
      own embedded pack, so it takes no project path; everything after the `--` is identical either
      way, because the game reads its own flags.
    * `:headless` — force a rendering mode to run without a window, which is what a bot fleet wants.
    * `:params` — values for the mode's placeholders.
    * `:extra` — passed through verbatim, after everything the manifest builds.
  """
  @spec build_argv(t(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def build_argv(%__MODULE__{} = man, mode, opts \\ []) do
    with {:ok, spec} <- fetch_mode(man, mode),
         values = resolve(spec, Keyword.get(opts, :params, %{})),
         :ok <- check_required(mode, spec, values),
         {:ok, prefix} <- prefix(man, mode, spec, opts),
         {:ok, scene} <- scene(mode, spec, values) do
      engine =
        prefix
        |> Kernel.++(render(Map.get(spec, "engine"), values))
        |> Kernel.++(["--log-file", to_string(Keyword.fetch!(opts, :log_path))])
        |> maybe_headless(Keyword.get(opts, :headless, false))
        |> Kernel.++(script(spec))
        |> Kernel.++(scene)

      {:ok,
       engine ++ ["--"] ++ render(Map.get(spec, "argv"), values) ++ Keyword.get(opts, :extra, [])}
    end
  end

  defp fetch_mode(%__MODULE__{modes: modes, project: project} = man, mode) do
    case Map.fetch(modes, mode) do
      {:ok, spec} ->
        {:ok, spec}

      :error ->
        {:error,
         "#{project} declares no mode #{inspect(mode)} (it has #{Enum.join(mode_names(man), ", ")})"}
    end
  end

  defp resolve(spec, params) do
    spec
    |> Map.get("defaults", %{})
    |> Map.merge(Map.new(params, fn {k, v} -> {to_string(k), v} end))
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp check_required(mode, spec, values) do
    case Enum.reject(Map.get(spec, "required", []), &(lookup(values, to_string(&1)) != nil)) do
      [] -> :ok
      missing -> {:error, "mode #{mode} needs #{missing |> Enum.sort() |> Enum.join(", ")}"}
    end
  end

  defp prefix(man, mode, spec, opts) do
    case Keyword.get(opts, :exported_bin) do
      nil ->
        {:ok,
         [
           to_string(Keyword.fetch!(opts, :engine_bin)),
           "--path",
           project_path(man, Keyword.fetch!(opts, :repo))
         ]}

      bin ->
        if Map.has_key?(spec, "scene") do
          {:error,
           "mode #{mode} runs a scene from source; an exported build boots its own main scene"}
        else
          {:ok, [to_string(bin)]}
        end
    end
  end

  defp scene(mode, spec, values) do
    case Map.get(spec, "scene") do
      nil ->
        {:ok, []}

      token ->
        case render([token], values) do
          [] -> {:error, "mode #{mode} needs a scene"}
          rendered -> {:ok, rendered}
        end
    end
  end

  defp script(spec) do
    case Map.get(spec, "script") do
      nil -> []
      script -> ["-s", to_string(script)]
    end
  end

  defp maybe_headless(engine, true) do
    if "--headless" in engine, do: engine, else: engine ++ ["--headless"]
  end

  defp maybe_headless(engine, _), do: engine

  defp render(nil, _values), do: []

  defp render(tokens, values) when is_list(tokens) do
    Enum.flat_map(tokens, fn token ->
      case token_arg(token, values) do
        nil -> []
        arg -> List.wrap(interpolate(arg, values))
      end
    end)
  end

  defp token_arg(token, _values) when is_binary(token), do: token

  defp token_arg(%{} = token, values) do
    cond do
      not is_binary(Map.get(token, "arg")) -> nil
      gated_out?(Map.get(token, "if"), values) -> nil
      blocked?(Map.get(token, "unless"), values) -> nil
      true -> Map.fetch!(token, "arg")
    end
  end

  defp token_arg(_, _), do: nil

  defp gated_out?(nil, _values), do: false
  defp gated_out?(name, values), do: lookup(values, to_string(name)) in [nil, false, "", 0]

  defp blocked?(nil, _values), do: false
  defp blocked?(name, values), do: lookup(values, to_string(name)) != nil

  @doc """
  Substitute every placeholder in `token`, or answer `nil` when one has no value.

  Dropping the token whole is what makes an optional flag optional. A value of `nil`, `false` or the
  empty string counts as absent; **`0` does not**, because a duration or a seed of zero is a real
  instruction and silently dropping it would run a different job than the one asked for.
  """
  @spec interpolate(String.t(), map()) :: String.t() | nil
  def interpolate(token, values) do
    case Regex.scan(@placeholder, token, capture: :all_but_first) do
      [] ->
        token

      names ->
        names
        |> Enum.map(&hd/1)
        |> Enum.reduce_while(token, fn name, acc ->
          case lookup(values, name) do
            value when value in [nil, false, ""] -> {:halt, nil}
            value -> {:cont, String.replace(acc, "{#{name}}", format(value))}
          end
        end)
    end
  end

  @doc "Resolve `a.b.c` through nested maps. Absent and present-but-nil both answer `nil`."
  @spec lookup(map(), String.t()) :: term()
  def lookup(values, name) do
    name
    |> String.split(".")
    |> Enum.reduce_while(values, fn part, node ->
      case node do
        %{} = map ->
          if Map.has_key?(map, part), do: {:cont, Map.get(map, part)}, else: {:halt, nil}

        _ ->
          {:halt, nil}
      end
    end)
  end

  defp format(value) when is_float(value) do
    if value == Float.round(value), do: Integer.to_string(trunc(value)), else: to_string(value)
  end

  defp format(true), do: "true"
  defp format(false), do: "false"
  defp format(value), do: to_string(value)
end
