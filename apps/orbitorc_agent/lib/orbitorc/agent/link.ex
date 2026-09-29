defmodule Orbitorc.Agent.Link do
  @moduledoc """
  The agent's connection to the control plane.

  ## The agent dials out

  Nothing connects to a box. The box connects to the control plane and stays connected, which removes
  three things a push-model fleet needs on every machine: an inbound firewall rule, a credential the
  controller holds, and a stable address to reach it at. A laptop on a hotel network joins the same way
  a rack machine does.

  It also makes membership honest. The socket **is** the presence: a box that crashes or loses its
  network leaves the fleet immediately, with no heartbeat table to fall behind and no timeout to tune.

  ## Reconnecting is the normal case, not an error path

  A box is expected to come and go — rebooted, carried out of wifi range, suspended. The link
  reconnects with backoff and re-reports on every join, so a box that changed underneath the control
  plane (a new revision, a display plugged in, a manifest edited) corrects the record by arriving.

  ## Every request is checked twice

  The control plane decides who may ask; the box decides what it will do. A launch arrives, and the box
  still checks its own lease, its own capabilities and its own manifest before starting anything. A
  control plane that has been talked into asking for something is not a reason for a box to do it.
  """

  use Slipstream, restart: :permanent
  require Logger

  alias Orbitorc.Agent.{Audit, Command, Config, Health, Jobs, Leases}
  alias Orbitorc.{Manifest, Measurement, Scene}

  @channel "agent"
  @reconnect [100, 500, 1_000, 2_000, 5_000, 10_000, 30_000]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Slipstream.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Slipstream
  def init(opts) do
    config = Keyword.fetch!(opts, :config)

    socket =
      connect!(
        uri: config.control_plane,
        # `x-` prefixed on purpose: a socket's connect_info collects only those, so an `authorization`
        # header on the upgrade would never be read and the refusal would look like a wrong token.
        headers: [{"x-orbitorc-token", config.token}],
        reconnect_after_msec: @reconnect,
        # A control plane behind a real certificate is verified against the system's trust store. The
        # BEAM ships no default store, so an omitted one is a connection that silently trusts nothing
        # and fails with a message about the socket rather than the certificate.
        mint_opts: [transport_opts: transport_opts(config.control_plane)],
        # Under test the control plane is the test process itself; nothing dials anywhere.
        test_mode?: Keyword.get(opts, :test_mode?, false)
      )

    # Every job on this box announces readiness, exit and its log lines on one topic. Forwarding them
    # is what lets a run on the control plane wait on a marker instead of a timeout.
    Phoenix.PubSub.subscribe(Orbitorc.PubSub, Jobs.topic())

    {:ok, assign(socket, config: config, problems: Keyword.get(opts, :problems, []))}
  end

  defp transport_opts("wss://" <> _),
    do: [cacerts: :public_key.cacerts_get(), verify: :verify_peer]

  defp transport_opts(_), do: []

  @impl Slipstream
  def handle_connect(socket) do
    config = socket.assigns.config
    report = Health.report(config, socket.assigns.problems)
    Logger.info("orbitorc: connected to #{config.control_plane}; joining as #{config.name}")
    {:ok, join(socket, @channel, %{"name" => config.name, "report" => report})}
  end

  @impl Slipstream
  def handle_join(@channel, reply, socket) do
    Logger.info("orbitorc: joined the fleet#{detail(reply)}")
    {:ok, socket}
  end

  # A control plane that is down is the normal case, not an error path: a box is expected to outlive
  # one, and to be started before one. So a failed connection backs off and tries again rather than
  # ending the agent — an agent that died waiting would need a person on every box to restart it.
  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("orbitorc: disconnected (#{inspect(reason)}); reconnecting")

    case reconnect(socket) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:stop, reason, socket}
    end
  end

  @impl Slipstream
  def handle_topic_close(@channel, reason, socket) do
    Logger.warning("orbitorc: the fleet channel closed (#{inspect(reason)}); rejoining")

    case rejoin(socket, @channel) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:stop, reason, socket}
    end
  end

  # --- what the control plane may ask for -----------------------------------------------------------

  @impl Slipstream
  def handle_message(@channel, "doctor", payload, socket) do
    reply(
      socket,
      payload,
      guarded(fn -> {:ok, Health.report(socket.assigns.config, socket.assigns.problems)} end)
    )
  end

  @impl Slipstream
  def handle_message(@channel, "lease", payload, socket) do
    caller = caller(payload)

    result =
      case Map.get(payload, "action") do
        "claim" -> Leases.claim(caller, ttl_ms: payload["ttl_ms"])
        "renew" -> Leases.renew(caller, ttl_ms: payload["ttl_ms"])
        "release" -> Leases.release(caller)
        "holder" -> {:ok, Leases.holder()}
        other -> {:error, "unknown lease action #{inspect(other)}"}
      end

    Audit.record(caller, "lease", %{"action" => payload["action"]}, result)
    reply(socket, payload, normalize(result))
  end

  @impl Slipstream
  def handle_message(@channel, "launch", payload, socket) do
    caller = caller(payload)
    result = guarded(fn -> do_launch(socket.assigns.config, caller, payload) end)
    Audit.record(caller, "launch", Map.take(payload, ["project", "mode", "params"]), result)
    reply(socket, payload, normalize(result))
  end

  @impl Slipstream
  def handle_message(@channel, "status", payload, socket) do
    reply(
      socket,
      payload,
      guarded(fn ->
        {:ok, %{"jobs" => Jobs.list(), "lease" => normalize_holder(Leases.holder())}}
      end)
    )
  end

  @impl Slipstream
  def handle_message(@channel, "sync", payload, socket) do
    caller = caller(payload)
    result = guarded(fn -> do_sync(socket.assigns.config, caller, payload) end)
    Audit.record(caller, "sync", Map.take(payload, ["project", "revision"]), result)

    # The tree is not the one the agent started with. What it declares is re-read now, so a manifest
    # the sync brought is served at once -- the re-report that follows describes this tree, not the
    # old one -- and a project whose manifest went away stops being launchable. Then, if the manifest
    # asks, the engine imports the tree, so the class cache the next launch resolves through is this
    # tree's and not the previous checkout's.
    {socket, result} =
      case result do
        {:ok, report} ->
          socket = reload_manifest(socket, payload["project"])
          {socket, import_after_sync(socket.assigns.config, payload["project"], report)}

        _ ->
          {socket, result}
      end

    reply(socket, payload, normalize(result))
  end

  @impl Slipstream
  def handle_message(@channel, "build", payload, socket) do
    caller = caller(payload)
    result = guarded(fn -> do_build(socket.assigns.config, caller, payload) end)
    Audit.record(caller, "build", Map.take(payload, ["project", "target"]), result)
    reply(socket, payload, normalize(result))
  end

  # The reply leaves first; a second later the agent exits, and its service manager brings the staged
  # release up. Nothing waits on the exit, so nothing is blocked by it.
  @impl Slipstream
  def handle_message(@channel, "upgrade", payload, socket) do
    caller = caller(payload)
    result = guarded(fn -> do_upgrade(caller, payload) end)
    Audit.record(caller, "upgrade", Map.take(payload, ["url", "version"]), result)
    if match?({:ok, _}, result), do: Process.send_after(self(), :exit_for_upgrade, 1_000)
    reply(socket, payload, normalize(result))
  end

  @impl Slipstream
  def handle_message(@channel, "shot", payload, socket) do
    caller = caller(payload)
    result = guarded(fn -> do_shot(caller, payload) end)
    Audit.record(caller, "shot", Map.take(payload, ["id"]), result)
    reply(socket, payload, normalize(result))
  end

  @impl Slipstream
  def handle_message(@channel, "pull", payload, socket) do
    reply(socket, payload, normalize(guarded(fn -> do_pull(payload) end)))
  end

  @impl Slipstream
  def handle_message(@channel, "logs", payload, socket) do
    pattern =
      case Map.get(payload, "grep") do
        nil ->
          nil

        source ->
          case Regex.compile(source) do
            {:ok, rx} -> rx
            {:error, _} -> nil
          end
      end

    result = guarded(fn -> Jobs.logs(payload["id"], Map.get(payload, "tail", 100), pattern) end)
    reply(socket, payload, normalize(result))
  end

  @impl Slipstream
  def handle_message(@channel, "stop", payload, socket) do
    caller = caller(payload)

    result =
      with :ok <- Leases.authorize(caller, :mutate) do
        case payload do
          %{"all" => true} ->
            {:ok, %{"stopped" => Jobs.stop_all(caller, force: !!payload["force"])}}

          %{"id" => id} ->
            Jobs.stop(id)

          _ ->
            {:error, "stop needs an id, or all"}
        end
      end

    Audit.record(caller, "stop", Map.take(payload, ["id", "all", "force"]), result)
    reply(socket, payload, normalize(result))
  end

  @impl Slipstream
  def handle_message(@channel, "verdict", payload, socket) do
    result = guarded(fn -> verdict(socket.assigns.config, payload) end)
    reply(socket, payload, normalize(result))
  end

  @impl Slipstream
  def handle_message(@channel, event, payload, socket) do
    reply(socket, payload, {:error, "this agent does not serve #{inspect(event)}"})
  end

  # A box that changed underneath the control plane corrects the record itself. A sync is the obvious
  # case: it moves the revision every later job runs, so leaving the old report standing would let a
  # caller read a description of a tree that no longer exists.
  @impl Slipstream
  def handle_info(:rereport, socket) do
    case guarded(fn -> {:ok, Health.report(socket.assigns.config, socket.assigns.problems)} end) do
      {:ok, report} ->
        {:noreply, forward(socket, "report", %{"report" => report})}

      {:error, reason} ->
        Logger.warning("orbitorc: could not re-report: #{reason}")
        {:noreply, socket}
    end
  end

  @impl Slipstream
  def handle_info(:exit_for_upgrade, socket) do
    Logger.info("orbitorc: exiting for an upgrade; the service manager brings the new release up")

    # Non-zero, so a manager that restarts only on failure restarts this. The test suite turns it off.
    if Application.get_env(:orbitorc_agent, :exit_on_upgrade, true), do: System.stop(3)
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_info({:job_event, id, event, detail}, socket) do
    {:noreply, forward(socket, "job_event", %{"job" => id, "event" => event, "detail" => detail})}
  end

  @impl Slipstream
  def handle_info({:job_log, id, line}, socket) do
    {:noreply, forward(socket, "log", %{"job" => id, "line" => line})}
  end

  @impl Slipstream
  def handle_info(_message, socket), do: {:noreply, socket}

  # A push before the channel is joined would raise. A line that arrives while the link is down is
  # simply not forwarded -- the log file on the box still has it, and the control plane can ask.
  defp forward(socket, event, payload) do
    if joined?(socket, @channel) do
      case push(socket, @channel, event, payload) do
        {:ok, _ref} -> socket
        {:error, _} -> socket
      end
    else
      socket
    end
  end

  # --- sync, build, capture, pull -------------------------------------------------------------------

  defp reload_manifest(socket, name) do
    {config, problem} = Config.reload_manifest(socket.assigns.config, name)
    problems = Enum.reject(socket.assigns.problems, &String.starts_with?(&1, "#{name}: "))

    assign(socket,
      config: config,
      problems: if(problem, do: problems ++ [problem], else: problems)
    )
  end

  defp import_after_sync(config, project, report) do
    case Config.fetch_project(config, project) do
      {:ok, spec, %{sync: %{"import" => true}} = manifest} ->
        path = Orbitorc.Manifest.project_path(manifest, spec.repo)

        case Command.import_project(spec.engine_bin, path) do
          {:ok, import} ->
            {:ok, Map.put(report, "import", import)}

          {:error, reason} ->
            {:error, "synced to #{report["sha"]}, but the import failed: #{reason}"}
        end

      _ ->
        {:ok,
         Map.put(report, "import", %{"ok" => true, "skipped" => "the manifest asks for none"})}
    end
  end

  defp do_sync(nil, _caller, _payload), do: {:error, "this box has no configuration"}

  defp do_sync(config, caller, payload) do
    with :ok <- Leases.authorize(caller, :mutate),
         {:ok, spec} <- Config.fetch_spec(config, payload["project"]),
         {:ok, revision} <- required(payload, "revision") do
      case Command.sync(spec.repo, revision) do
        {:ok, report} ->
          # A sync changes what every later job runs, so the box re-reports rather than leaving the
          # control plane holding a description of a tree that no longer exists.
          send(self(), :rereport)
          {:ok, report}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_build(nil, _caller, _payload), do: {:error, "this box has no configuration"}

  defp do_build(config, caller, payload) do
    with :ok <- Leases.authorize(caller, :mutate),
         {:ok, spec, manifest} <- Config.fetch_project(config, payload["project"]),
         {:ok, target} <- required(payload, "target") do
      Command.build(spec.repo, manifest.sync, target)
    end
  end

  # A box with a job running refuses: an exit mid-job would reap it, and a measurement reaped by its
  # own harness is the confident wrong answer this whole system exists to prevent.
  defp do_upgrade(caller, payload) do
    with :ok <- Leases.authorize(caller, :mutate),
         :ok <- nothing_running(),
         {:ok, url} <- required(payload, "url") do
      Orbitorc.Agent.Upgrade.stage(url, Map.get(payload, "sha256"))
    end
  end

  defp nothing_running do
    case Jobs.list() do
      [] -> :ok
      jobs -> {:error, "#{length(jobs)} job(s) running here; an upgrade waits for a quiet box"}
    end
  end

  defp do_shot(caller, payload) do
    with :ok <- Leases.authorize(caller, :mutate),
         {:ok, job} <- Jobs.info(payload["id"]) do
      path = Path.join(job.dir, "shot.png")

      case Command.capture(path, Map.get(payload, "window", "Godot")) do
        {:ok, path} -> {:ok, %{"path" => path, "bytes" => File.stat!(path).size}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # An artifact leaves the box base64-encoded over the same socket, so no second channel and no second
  # credential is needed to collect a result.
  defp do_pull(payload) do
    with {:ok, job} <- Jobs.info(payload["id"]) do
      name = Map.get(payload, "file", "metrics.csv")
      path = Path.join(job.dir, name)

      case File.read(path) do
        {:ok, body} when byte_size(body) <= 8_000_000 ->
          {:ok, %{"file" => name, "bytes" => byte_size(body), "base64" => Base.encode64(body)}}

        {:ok, body} ->
          {:error,
           "#{name} is #{byte_size(body)} bytes, past the 8 MB an artifact may cross the socket as"}

        {:error, reason} ->
          {:error, "#{name}: #{:file.format_error(reason)}"}
      end
    end
  end

  defp required(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "this verb needs a #{key}"}
    end
  end

  # `"auto"` means "somewhere in this job's own directory". A caller asking for metrics or a recording
  # must not have to name a path on a machine it cannot see, and a job whose artifacts landed outside
  # its directory could not be collected or pruned with it.
  @artifact_params ~w(metrics record replay)

  defp resolve_artifacts(params, dir) do
    Enum.reduce(@artifact_params, params, fn key, acc ->
      case Map.get(acc, key) do
        value when value in ["auto", true, "1"] ->
          Map.put(acc, key, Path.join(dir, default_artifact(key)))

        _ ->
          acc
      end
    end)
  end

  defp default_artifact("metrics"), do: "metrics.csv"
  defp default_artifact("record"), do: "session.tape"
  defp default_artifact("replay"), do: "session.tape"

  # --- launching ------------------------------------------------------------------------------------

  defp do_launch(nil, _caller, _payload), do: {:error, "this box has no configuration"}

  defp do_launch(config, caller, payload) do
    project = Map.get(payload, "project")
    mode = Map.get(payload, "mode")
    dry = Map.get(payload, "dry") == true

    # A dry run resolves the manifest, the parameters, the session check and the exact argv, and starts
    # nothing. It needs no lease because it changes nothing, and it is the cheapest check there is:
    # the argv is the single thing most likely to be wrong in a remote harness.
    with :ok <- if(dry, do: :ok, else: Leases.authorize(caller, :mutate)),
         {:ok, spec, manifest} <- Config.fetch_project(config, project),
         {:ok, params} <- launch_params(config, manifest, mode, payload),
         {session_ok, session_detail} = Orbitorc.Agent.Platform.session_ok(),
         :ok <- allowed?(manifest, project, mode, session_ok, session_detail, payload),
         {:ok, argv_opts} <- argv_opts(spec, manifest, mode, params, payload) do
      # The job's own directory is where its log and its artifacts land, and it does not exist until the
      # job process makes it. So the argv is built there, with the paths filled in from the directory
      # the job owns -- `metrics: "auto"` becomes a real file inside it, which is what lets a caller ask
      # for a result without ever naming a path on the box.
      builder = fn dir, log_path ->
        opts =
          argv_opts
          |> Keyword.put(:log_path, log_path)
          |> Keyword.update!(:params, &resolve_artifacts(&1, dir))

        Manifest.build_argv(manifest, mode, opts)
      end

      if dry do
        placeholder = Path.join(Jobs.root(), "<next-id>")

        with {:ok, argv} <- builder.(placeholder, Path.join(placeholder, "job.log")) do
          {:ok,
           %{
             "dry" => true,
             "argv" => argv,
             "env" => Manifest.env(manifest, mode),
             "marker" => Manifest.ready_marker(manifest, mode),
             "cwd" => placeholder
           }}
        end
      else
        Jobs.launch(
          argv_builder: builder,
          env: Manifest.env(manifest, mode),
          marker: Manifest.ready_marker(manifest, mode),
          project: project,
          mode: mode,
          caller: caller,
          deadline_ms: deadline(payload)
        )
        |> case do
          {:ok, id, info} -> {:ok, %{"id" => id, "job" => info}}
          {:error, reason} -> {:error, inspect(reason)}
        end
      end
    end
  end

  # A caller names a mode; the box supplies the ports it was configured with. That is what keeps a job
  # here off the ports a project's own harnesses bind on the same machine -- and why a default is not
  # sent by the caller: a default that arrives as a key is already present, so the box's own
  # configuration could never apply.
  defp launch_params(config, manifest, mode, payload) do
    params = Map.get(payload, "params", %{})

    defaults =
      %{}
      |> put_new_port(params, manifest, mode, "port", config.game_port)
      |> put_new_port(params, manifest, mode, "listen", config.relay_port)

    {:ok, Map.merge(defaults, params)}
  end

  defp put_new_port(acc, params, manifest, mode, key, value) do
    declared = get_in(manifest.modes, [mode, "defaults", key])

    if Map.has_key?(params, key) or declared == nil do
      acc
    else
      Map.put(acc, key, value)
    end
  end

  defp allowed?(manifest, project, mode, session_ok, session_detail, payload) do
    headless = !!Map.get(payload, "headless")

    cond do
      not Manifest.mode?(manifest, mode) ->
        {:error, "#{project} declares no mode #{inspect(mode)}"}

      Manifest.needs_gui?(manifest, mode) and not headless and not session_ok ->
        {:error, "#{mode} renders and this box has no graphical session (#{session_detail})"}

      true ->
        :ok
    end
  end

  defp argv_opts(spec, manifest, mode, params, payload) do
    with {:ok, params} <- normalize_scene_param(manifest, mode, params) do
      base = [
        engine_bin: spec.engine_bin,
        repo: spec.repo,
        headless: !!Map.get(payload, "headless"),
        params: params,
        extra: Map.get(payload, "extra", [])
      ]

      case Map.get(payload, "exported") do
        nil -> {:ok, base}
        target -> exported(spec, target, base)
      end
    end
  end

  # The scene path is validated on the BOX, whatever the control plane thought of it. It names a file
  # inside a checkout this machine holds, so this machine is what has to be satisfied it is not a path
  # out of the tree.
  defp normalize_scene_param(manifest, mode, params) do
    if get_in(manifest.modes, [mode, "scene"]) && Map.has_key?(params, "scene") do
      case Scene.normalize(params["scene"]) do
        {:ok, scene} -> {:ok, Map.put(params, "scene", scene)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, params}
    end
  end

  defp exported(spec, target, base) do
    dir = spec.exported_dir || Path.join(spec.repo, "build")

    case dir
         |> Path.join("*" <> to_string(target) <> "*")
         |> Path.wildcard()
         |> Enum.find(&File.regular?/1) do
      nil -> {:error, "no #{target} build in #{dir} — run a build first"}
      bin -> {:ok, Keyword.put(base, :exported_bin, bin)}
    end
  end

  # Added to a job's declared duration to get the wall-clock backstop. Generous on purpose: reaping a
  # healthy run early destroys the measurement the run existed to take, while reaping a wedged one late
  # costs only time on the box.
  defp deadline(payload) do
    case Map.get(payload, "duration_s") do
      seconds when is_integer(seconds) and seconds > 0 -> (seconds + 180) * 1_000
      _ -> nil
    end
  end

  defp verdict(config, payload) do
    with {:ok, _spec, manifest} <- Config.fetch_project(config, payload["project"]),
         {:ok, job} <- Jobs.info(payload["id"]) do
      artifact = get_in(manifest.measurement, ["artifact"]) || "metrics.csv"
      path = Path.join(job.dir, artifact)

      case File.read(path) do
        {:ok, csv} ->
          {:ok,
           Map.from_struct(Measurement.verdict_for_mode(job.mode, csv, manifest.measurement))}

        {:error, _} ->
          {:ok,
           %{
             verdict: :unknown,
             detail: "the job wrote no #{artifact}",
             rows: 0,
             live: [],
             zeroed: [],
             unclassified: []
           }}
      end
    end
  end

  # --- plumbing -------------------------------------------------------------------------------------

  defp caller(payload), do: Map.get(payload, "caller", "unknown")

  defp detail(reply) when is_map(reply) and map_size(reply) > 0, do: ": #{inspect(reply)}"
  defp detail(_), do: ""

  # `push!/4` answers the push's ref, not the socket. A callback that returned that ref in the socket's
  # place crashed the link after every reply, the box left the fleet, and the reconnect hid it: each
  # command on its own appeared to work, and the first thing to ask twice in a row did not.
  defp reply(socket, payload, result) do
    case Map.get(payload, "ref") do
      nil ->
        {:ok, socket}

      ref ->
        push!(socket, @channel, "reply", %{"ref" => ref, "result" => encode(result)})
        {:ok, socket}
    end
  end

  # Run a verb's handler and turn any crash in it into a refusal.
  #
  # **A BUG IN ONE VERB MUST NOT DROP THIS BOX OUT OF THE FLEET.** Without this, an unhandled error in
  # a handler kills the link, the box leaves the fleet, every request waiting on it fails, and any run
  # placed here fails with "the box left" -- which describes the symptom and hides the cause. Answering
  # the error instead leaves the box connected, the caller told what went wrong, and the audit log
  # holding it.
  defp guarded(fun) do
    try do
      fun.()
    rescue
      error -> {:error, "the box refused this: #{Exception.message(error)}"}
    catch
      kind, value -> {:error, "the box refused this: #{inspect(kind)} #{inspect(value)}"}
    end
  end

  defp normalize(:ok), do: {:ok, %{}}
  defp normalize({:ok, _} = ok), do: ok

  defp normalize({:error, {:contended, holder, remaining}}),
    do: {:error, "leased by #{holder} for another #{div(remaining, 1000)}s"}

  defp normalize({:error, :needs_lease}),
    do: {:error, "this verb needs the lease; claim it first"}

  defp normalize({:error, :not_holder}), do: {:error, "you do not hold this box's lease"}
  defp normalize({:error, :no_such_job}), do: {:error, "no such job"}
  defp normalize({:error, :gone}), do: {:error, "that job has already finished"}
  defp normalize({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp normalize({:error, reason}), do: {:error, inspect(reason)}

  defp normalize_holder(:free), do: %{"held" => false}

  defp normalize_holder({:ok, name, remaining}),
    do: %{"held" => true, "holder" => name, "remaining_ms" => remaining}

  defp encode({:ok, value}), do: %{"ok" => true, "value" => value}
  defp encode({:error, reason}), do: %{"ok" => false, "error" => reason}
end
