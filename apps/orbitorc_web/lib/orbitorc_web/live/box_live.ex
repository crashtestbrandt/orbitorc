defmodule OrbitorcWeb.BoxLive do
  @moduledoc """
  One box: what it reports, what it is running, and every verb that acts on it.

  The health table leads with the checks that catch a **confident wrong answer** rather than an outright
  failure, because those are the ones a person has to be told about. A box that cannot launch says so
  when asked; a box with a stale import cache launches, comes up, and writes a file full of zeros.

  The launch form is built from the box's own report: the modes it can serve, and for each mode the
  parameters its manifest declares. A dry run shows the exact argv the box would run, which is the
  single thing most likely to be wrong in a remote harness, before anything is committed to it.
  """

  use OrbitorcWeb, :live_view

  alias Orbitorc.Fleet
  alias OrbitorcWeb.Verbs

  @verbs ~w(doctor status lease launch dry-run stop build shot verdict)
  @doc "The verbs this page runs; the parity test reads it."
  def verbs, do: @verbs

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Orbitorc.PubSub, Fleet.topic())
      Phoenix.PubSub.subscribe(Orbitorc.PubSub, "box:#{name}:jobs")
    end

    {:ok,
     socket
     |> assign(
       name: name,
       page_title: name,
       jobs: [],
       lease: nil,
       error: nil,
       notice: nil,
       busy: nil,
       launch: %{
         "project" => "",
         "mode" => "",
         "params" => %{},
         "more" => "",
         "extra" => "",
         "headless" => "false"
       },
       dry: nil,
       build: %{"project" => "", "target" => ""},
       build_result: nil
     )
     |> load_box()
     |> load_status()
     |> default_forms()}
  end

  @impl true
  def handle_info({:fleet, _event}, socket),
    do: {:noreply, socket |> load_box() |> default_forms()}

  def handle_info({:job_event, name, _id, _event, _detail}, %{assigns: %{name: name}} = socket),
    do: {:noreply, load_status(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket),
    do: {:noreply, socket |> load_box() |> load_status() |> default_forms()}

  def handle_event("doctor", _params, socket),
    do: {:noreply, run_async(socket, :doctor, "doctor", %{"box" => socket.assigns.name})}

  def handle_event("lease", %{"action" => action}, socket) do
    {:noreply,
     run_async(socket, :lease, "lease", %{"box" => socket.assigns.name, "action" => action})}
  end

  def handle_event("launch_form", params, socket) do
    {:noreply, assign(socket, launch: launch_fields(socket, params))}
  end

  def handle_event("launch", params, socket) do
    form = launch_fields(socket, params)
    intent = if params["intent"] == "dry-run", do: :dry, else: :launch

    case launch_payload(socket.assigns.name, form) do
      {:ok, payload} ->
        verb = if intent == :dry, do: "dry-run", else: "launch"
        {:noreply, socket |> assign(launch: form, dry: nil) |> run_async(intent, verb, payload)}

      {:error, reason} ->
        {:noreply, assign(socket, launch: form, error: reason)}
    end
  end

  def handle_event("build_form", params, socket) do
    {:noreply, assign(socket, build: Map.take(params, ["project", "target"]))}
  end

  def handle_event("build", params, socket) do
    form = Map.take(params, ["project", "target"])

    payload = %{
      "box" => socket.assigns.name,
      "project" => form["project"],
      "target" => form["target"]
    }

    {:noreply,
     socket |> assign(build: form, build_result: nil) |> run_async(:build, "build", payload)}
  end

  def handle_event("stop", %{"id" => id}, socket) do
    {:noreply,
     run_async(socket, {:stop, id}, "stop", %{"box" => socket.assigns.name, "id" => id})}
  end

  def handle_event("shot", %{"id" => id}, socket) do
    {:noreply,
     run_async(socket, {:shot, id}, "shot", %{"box" => socket.assigns.name, "id" => id})}
  end

  def handle_event("verdict", %{"id" => id, "project" => project}, socket) do
    payload = %{"box" => socket.assigns.name, "id" => id, "project" => project}
    {:noreply, run_async(socket, {:verdict, id}, "verdict", payload)}
  end

  @impl true
  def handle_async(:doctor, {:ok, {:ok, _report}}, socket),
    do:
      {:noreply,
       socket |> assign(busy: nil, notice: "report taken fresh") |> load_box() |> default_forms()}

  def handle_async(:lease, {:ok, {:ok, value}}, socket) do
    notice =
      case value do
        ttl when is_integer(ttl) -> "#{socket.assigns.name} is yours for #{div(ttl, 1000)}s"
        _ -> "released #{socket.assigns.name}"
      end

    {:noreply, socket |> assign(busy: nil, notice: notice) |> load_status()}
  end

  def handle_async(:dry, {:ok, {:ok, value}}, socket),
    do: {:noreply, assign(socket, busy: nil, dry: value)}

  def handle_async(:launch, {:ok, {:ok, %{"id" => id} = value}}, socket) do
    marker = get_in(value, ["job", "marker"])

    notice =
      "job #{id} started" <>
        if(marker,
          do: ", ready when the log shows #{inspect(marker)}",
          else: ", no marker declared"
        )

    {:noreply, socket |> assign(busy: nil, notice: notice) |> load_status()}
  end

  def handle_async(:build, {:ok, {:ok, value}}, socket),
    do: {:noreply, assign(socket, busy: nil, build_result: value)}

  def handle_async({:stop, id}, {:ok, {:ok, _}}, socket),
    do: {:noreply, socket |> assign(busy: nil, notice: "stopped job #{id}") |> load_status()}

  def handle_async({:shot, id}, {:ok, {:ok, %{"bytes" => bytes}}}, socket) do
    {:noreply,
     assign(socket,
       busy: nil,
       notice: "job #{id}: captured its window (#{bytes} bytes); the job page shows it"
     )}
  end

  def handle_async(
        {:verdict, id},
        {:ok, {:ok, %{"verdict" => verdict, "detail" => detail}}},
        socket
      ),
      do: {:noreply, assign(socket, busy: nil, notice: "job #{id}: #{verdict} — #{detail}")}

  def handle_async(_name, {:ok, {:ok, value}}, socket),
    do: {:noreply, assign(socket, busy: nil, notice: inspect(value))}

  def handle_async(_name, {:ok, {:error, {_status, reason}}}, socket),
    do: {:noreply, assign(socket, busy: nil, error: to_string(reason))}

  def handle_async(_name, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, busy: nil, error: to_string(reason))}

  def handle_async(_name, {:exit, reason}, socket),
    do: {:noreply, assign(socket, busy: nil, error: "the verb crashed: #{inspect(reason)}")}

  # --- loading --------------------------------------------------------------------------------------

  defp run_async(socket, name, verb, payload) do
    caller = socket.assigns.caller

    socket
    |> assign(busy: name, error: nil, notice: nil)
    |> start_async(name, fn -> Verbs.run(verb, payload, caller) end)
  end

  defp load_box(socket) do
    case Fleet.fetch(socket.assigns.name) do
      {:ok, box} ->
        assign(socket, box: box, error: nil)

      {:error, :not_connected} ->
        assign(socket, box: nil, error: "#{socket.assigns.name} is not connected")
    end
  end

  defp load_status(%{assigns: %{box: nil}} = socket), do: socket

  defp load_status(socket) do
    case Verbs.run("status", %{"box" => socket.assigns.name}, socket.assigns.caller) do
      {:ok, %{"jobs" => jobs, "lease" => lease}} -> assign(socket, jobs: jobs, lease: lease)
      {:error, {_status, reason}} -> assign(socket, error: to_string(reason))
      {:error, reason} -> assign(socket, error: to_string(reason))
    end
  end

  # The forms start on something launchable, so the first click does not have to be "choose a project".
  defp default_forms(%{assigns: %{box: nil}} = socket), do: socket

  defp default_forms(socket) do
    launch = socket.assigns.launch
    projects = projects(socket.assigns.box)

    launch =
      if launch["project"] in projects,
        do: launch,
        else: launch_fields(socket, %{"project" => List.first(projects) || "", "mode" => ""})

    build = socket.assigns.build
    exports = exports(socket.assigns.box)

    build = %{
      "project" =>
        if(build["project"] in projects, do: build["project"], else: List.first(projects) || ""),
      "target" =>
        if(build["target"] in exports, do: build["target"], else: List.first(exports) || "")
    }

    assign(socket, launch: launch, build: build)
  end

  # A change of project resets the mode to the project's first; a change of mode resets the parameters
  # to that mode's defaults. Everything else is kept as typed.
  defp launch_fields(socket, params) do
    box = socket.assigns.box
    previous = socket.assigns.launch
    project = params["project"] || previous["project"]
    modes = modes(box, project)

    mode =
      cond do
        project != previous["project"] -> List.first(modes) || ""
        params["mode"] in modes -> params["mode"]
        previous["mode"] in modes -> previous["mode"]
        true -> List.first(modes) || ""
      end

    params_map =
      if mode != previous["mode"] or project != previous["project"],
        do: %{},
        else: Map.get(params, "params", previous["params"] || %{})

    %{
      "project" => project,
      "mode" => mode,
      "params" => params_map,
      "more" => Map.get(params, "more", previous["more"] || ""),
      "extra" => Map.get(params, "extra", previous["extra"] || ""),
      "headless" =>
        if(params["headless"] in ["true", "on"],
          do: "true",
          else: Map.get(params, "headless", previous["headless"])
        )
    }
  end

  defp launch_payload(box_name, form) do
    with {:ok, extra} <- split_extra(form["extra"] || "") do
      declared =
        (form["params"] || %{})
        |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
        |> Map.new(fn {k, v} -> {k, Verbs.coerce(v)} end)

      {:ok,
       %{
         "box" => box_name,
         "project" => form["project"],
         "mode" => form["mode"],
         "params" => Map.merge(declared, OrbitorcWeb.RunsLive.parse_params(form["more"] || "")),
         "extra" => extra,
         "headless" => form["headless"] == "true"
       }}
    end
  end

  # Everything after the manifest's argv, split the way a shell would.
  defp split_extra(text) do
    {:ok, OptionParser.split(text)}
  rescue
    e in RuntimeError -> {:error, "extra arguments: #{Exception.message(e)}"}
  end

  # --- what the report says the box can do ---------------------------------------------------------

  defp projects(box), do: box.projects |> Map.keys() |> Enum.sort()

  defp modes(_box, project) when project in [nil, ""], do: []

  defp modes(box, project) do
    prefix = "launch.#{project}."

    box.capabilities
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
    |> Enum.sort()
  end

  defp exports(box) do
    box.capabilities
    |> Enum.filter(fn {k, v} -> String.starts_with?(k, "export.") and v == true end)
    |> Enum.map(fn {k, _} -> String.replace_prefix(k, "export.", "") end)
    |> Enum.sort()
  end

  defp mode_spec(box, project, mode),
    do: get_in(box.projects, [project, "manifest", "params", mode]) || %{}

  # The parameters a mode takes, as rows for the form: declared defaults first, then the required ones
  # without a default, then a scene if the mode takes one.
  defp param_rows(spec) do
    defaults = Map.get(spec, "defaults", %{})
    required = Map.get(spec, "required", [])

    declared =
      defaults
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> %{key: k, default: to_string(v), required: k in required} end)

    missing =
      required
      |> Enum.reject(&Map.has_key?(defaults, &1))
      |> Enum.map(&%{key: &1, default: "", required: true})

    scene =
      if Map.get(spec, "scene"), do: [%{key: "scene", default: "", required: true}], else: []

    Enum.uniq_by(declared ++ missing ++ scene, & &1.key)
  end

  defp serves?(box, project, mode, headless) do
    key = "launch.#{project}.#{mode}"
    box.capabilities[key] == true or (headless and Map.has_key?(box.capabilities, key))
  end

  # --- rendering ------------------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      case assigns.box do
        nil ->
          assign(assigns, projects: [], modes: [], rows: [], exports: [], spec: %{})

        box ->
          spec = mode_spec(box, assigns.launch["project"], assigns.launch["mode"])

          assign(assigns,
            projects: projects(box),
            modes: modes(box, assigns.launch["project"]),
            rows: param_rows(spec),
            spec: spec,
            exports: exports(box)
          )
      end

    ~H"""
    <Layouts.app flash={@flash} caller={@caller} path={@path}>
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-semibold">{@name}</h1>
        <span class="flex items-center gap-3 text-sm text-zinc-500">
          <a href={~p"/api/box/#{@name}/status"} class="hover:underline">JSON</a>
          <button
            phx-click="doctor"
            class="rounded border border-zinc-300 px-3 py-1 hover:bg-zinc-50 disabled:opacity-40"
            disabled={is_nil(@box) or @busy == :doctor}
          >
            {if @busy == :doctor, do: "Asking…", else: "Doctor"}
          </button>
          <button
            phx-click="refresh"
            class="rounded border border-zinc-300 px-3 py-1 hover:bg-zinc-50"
          >
            Refresh
          </button>
        </span>
      </header>

      <Layouts.identity_notice caller={@caller} />

      <p :if={@error} class="rounded border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
        {@error}
      </p>
      <p
        :if={@notice}
        class="rounded border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-900"
      >
        {@notice}
      </p>

      <section :if={@box} class="space-y-6">
        <div class="grid grid-cols-2 gap-4 text-sm sm:grid-cols-4">
          <div>
            <p class="text-zinc-500">Platform</p>
            <p>{@box.platform}</p>
          </div>
          <div>
            <p class="text-zinc-500">Session</p>
            <p class={if elem(@box.session, 0), do: "text-emerald-700", else: "text-amber-700"}>
              {elem(@box.session, 1)}
            </p>
          </div>
          <div>
            <p class="text-zinc-500">LAN</p>
            <p class="font-mono">{@box.lan || "—"}</p>
          </div>
          <div>
            <p class="text-zinc-500">Lease</p>
            <p class="flex flex-wrap items-center gap-2">
              <span>{lease_line(@lease)}</span>
              <button
                :for={action <- lease_actions(@lease, @caller)}
                phx-click="lease"
                phx-value-action={action}
                class="rounded border border-zinc-300 px-2 py-0.5 text-xs hover:bg-zinc-50 disabled:opacity-40"
                disabled={is_nil(@caller) or @busy == :lease}
              >
                {action}
              </button>
            </p>
          </div>
        </div>

        <div>
          <h2 class="mb-2 text-lg font-medium">Projects</h2>
          <div
            :for={{name, report} <- Enum.sort(@box.projects)}
            class="mb-4 rounded border border-zinc-200 p-4"
          >
            <div class="flex flex-wrap items-baseline gap-x-3">
              <span class="font-mono font-medium">{name}</span>
              <span class="text-sm text-zinc-500">{get_in(report, ["revision", "branch"])}</span>
              <span class="font-mono text-sm text-zinc-500">{short_sha(report)}</span>
            </div>

            <dl class="mt-3 space-y-1 text-sm">
              <.check
                label="Checkout"
                ok={get_in(report, ["revision", "ok"])}
                detail={revision_detail(report)}
              />
              <.check
                label="Engine"
                ok={get_in(report, ["engine", "ok"])}
                detail={engine_detail(report)}
              />
              <.check
                label="Import cache"
                ok={get_in(report, ["import", "ok"])}
                detail={get_in(report, ["import", "detail"])}
              />
              <.check
                label="Requirements"
                ok={get_in(report, ["requires", "ok"])}
                detail={get_in(report, ["requires", "detail"])}
              />
              <.check
                label="Pinned backend"
                ok={get_in(report, ["pinned", "ok"])}
                detail={get_in(report, ["pinned", "detail"])}
              />
              <.check
                label="Manifest"
                ok={get_in(report, ["manifest", "ok"])}
                detail={manifest_detail(report)}
              />
            </dl>
          </div>
        </div>

        <div :if={@projects != []} class="rounded border border-zinc-200 p-4">
          <h2 class="mb-2 text-lg font-medium">Launch</h2>
          <form
            id="launch-form"
            phx-change="launch_form"
            phx-submit="launch"
            class="space-y-3 text-sm"
          >
            <div class="flex flex-wrap items-end gap-3">
              <label class="flex flex-col gap-1">
                <span class="text-zinc-500">Project</span>
                <select name="project" class="rounded border border-zinc-300 px-2 py-1">
                  <option :for={p <- @projects} value={p} selected={p == @launch["project"]}>
                    {p}
                  </option>
                </select>
              </label>
              <label class="flex flex-col gap-1">
                <span class="text-zinc-500">Mode</span>
                <select name="mode" class="rounded border border-zinc-300 px-2 py-1">
                  <option :for={m <- @modes} value={m} selected={m == @launch["mode"]}>
                    {m}{if serves?(@box, @launch["project"], m, false),
                      do: "",
                      else: " (headless only here)"}
                  </option>
                </select>
              </label>
              <label class="flex items-center gap-2 pb-1">
                <input type="hidden" name="headless" value="false" />
                <input
                  type="checkbox"
                  name="headless"
                  value="true"
                  checked={@launch["headless"] == "true"}
                />
                <span>headless</span>
              </label>
              <span :if={@spec["ready"]} class="pb-1 text-zinc-500">
                ready when the log shows <code>{@spec["ready"]}</code>
              </span>
              <span :if={@launch["mode"] != "" and is_nil(@spec["ready"])} class="pb-1 text-zinc-500">
                no ready marker declared
              </span>
            </div>

            <div :if={@rows != []} class="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <label :for={row <- @rows} class="flex flex-col gap-1">
                <span class="text-zinc-500">
                  {row.key}<span :if={row.required} class="text-amber-700"> *</span>
                </span>
                <input
                  name={"params[#{row.key}]"}
                  value={Map.get(@launch["params"], row.key, "")}
                  placeholder={row.default}
                  class="rounded border border-zinc-300 px-2 py-1 font-mono"
                />
              </label>
            </div>

            <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <label class="flex flex-col gap-1">
                <span class="text-zinc-500">More parameters, one <code>key=value</code> per line</span>
                <textarea
                  name="more"
                  rows="2"
                  class="rounded border border-zinc-300 px-2 py-1 font-mono"
                >{@launch["more"]}</textarea>
              </label>
              <label class="flex flex-col gap-1">
                <span class="text-zinc-500">Extra arguments, after the manifest's own (<code>--</code>
                on the command line)</span>
                <input
                  name="extra"
                  value={@launch["extra"]}
                  class="rounded border border-zinc-300 px-2 py-1 font-mono"
                />
              </label>
            </div>

            <div class="flex gap-2">
              <button
                name="intent"
                value="dry-run"
                class="rounded border border-zinc-300 px-3 py-1 hover:bg-zinc-50 disabled:opacity-40"
                disabled={@launch["mode"] == "" or @busy in [:dry, :launch]}
              >
                {if @busy == :dry, do: "Resolving…", else: "Dry run"}
              </button>
              <button
                name="intent"
                value="launch"
                class="rounded border border-zinc-800 bg-zinc-800 px-3 py-1 text-white disabled:opacity-40"
                disabled={is_nil(@caller) or @launch["mode"] == "" or @busy in [:dry, :launch]}
              >
                {if @busy == :launch, do: "Launching…", else: "Launch"}
              </button>
            </div>
          </form>

          <div :if={@dry} class="mt-4 rounded bg-zinc-50 p-3 text-sm">
            <p class="text-zinc-500">would run, in <code>{@dry["cwd"]}</code>:</p>
            <pre class="mt-1 overflow-x-auto font-mono text-xs">{Enum.map_join(@dry["argv"] || [], " ", &shell_quote/1)}</pre>
            <p class="mt-1 text-zinc-600">
              {if @dry["marker"],
                do: "ready when the log shows #{inspect(@dry["marker"])}",
                else: "no marker declared"}
            </p>
            <p :if={map_size(@dry["env"] || %{}) > 0} class="mt-1 font-mono text-xs text-zinc-600">
              env: {Enum.map_join(@dry["env"], " ", fn {k, v} -> "#{k}=#{v}" end)}
            </p>
          </div>
        </div>

        <div :if={@projects != [] and @exports != []} class="rounded border border-zinc-200 p-4">
          <h2 class="mb-2 text-lg font-medium">Build</h2>
          <form
            id="build-form"
            phx-change="build_form"
            phx-submit="build"
            class="flex flex-wrap items-end gap-3 text-sm"
          >
            <label class="flex flex-col gap-1">
              <span class="text-zinc-500">Project</span>
              <select name="project" class="rounded border border-zinc-300 px-2 py-1">
                <option :for={p <- @projects} value={p} selected={p == @build["project"]}>{p}</option>
              </select>
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-zinc-500">Target</span>
              <select name="target" class="rounded border border-zinc-300 px-2 py-1">
                <option :for={t <- @exports} value={t} selected={t == @build["target"]}>{t}</option>
              </select>
            </label>
            <button
              class="rounded border border-zinc-800 bg-zinc-800 px-3 py-1 text-white disabled:opacity-40"
              disabled={is_nil(@caller) or @busy == :build}
            >
              {if @busy == :build, do: "Building…", else: "Build"}
            </button>
          </form>
          <p :if={@build_result} class="mt-3 text-sm">
            {build_line(@build_result)}
          </p>
        </div>

        <div>
          <h2 class="mb-2 text-lg font-medium">Jobs</h2>
          <p :if={@jobs == []} class="text-sm text-zinc-500">Nothing running.</p>
          <table :if={@jobs != []} class="w-full text-sm">
            <thead class="text-left text-zinc-500">
              <tr>
                <th class="py-1">Id</th>
                <th>Project</th>
                <th>Mode</th>
                <th>Caller</th>
                <th>Ready</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={job <- @jobs} class="border-t border-zinc-100">
                <td class="py-1 font-mono">
                  <.link navigate={~p"/box/#{@name}/job/#{job["id"]}"} class="hover:underline">
                    {job["id"]}
                  </.link>
                </td>
                <td>{job["project"]}</td>
                <td>{job["mode"]}</td>
                <td>{job["caller"]}</td>
                <td>{ready_line(job)}</td>
                <td class="flex flex-wrap justify-end gap-1 py-1">
                  <button
                    phx-click="stop"
                    phx-value-id={job["id"]}
                    class="rounded border border-zinc-300 px-2 py-0.5 text-xs hover:bg-zinc-50 disabled:opacity-40"
                    disabled={is_nil(@caller) or @busy == {:stop, to_string(job["id"])}}
                  >
                    stop
                  </button>
                  <button
                    phx-click="shot"
                    phx-value-id={job["id"]}
                    class="rounded border border-zinc-300 px-2 py-0.5 text-xs hover:bg-zinc-50 disabled:opacity-40"
                    disabled={is_nil(@caller) or @busy == {:shot, to_string(job["id"])}}
                  >
                    shot
                  </button>
                  <button
                    phx-click="verdict"
                    phx-value-id={job["id"]}
                    phx-value-project={job["project"]}
                    class="rounded border border-zinc-300 px-2 py-0.5 text-xs hover:bg-zinc-50 disabled:opacity-40"
                    disabled={@busy == {:verdict, to_string(job["id"])}}
                  >
                    verdict
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :ok, :any, required: true
  attr :detail, :string, default: nil

  defp check(assigns) do
    ~H"""
    <div class="flex gap-2">
      <dt class="w-32 shrink-0 text-zinc-500">{@label}</dt>
      <dd class={if @ok == true, do: "text-emerald-700", else: "text-amber-800"}>
        {if @ok == true, do: "ok", else: "check"}
        <span :if={@detail} class="text-zinc-600">— {@detail}</span>
      </dd>
    </div>
    """
  end

  defp lease_actions(%{"held" => true, "holder" => holder}, caller) when holder == caller,
    do: ["renew", "release"]

  defp lease_actions(%{"held" => true}, _caller), do: []
  defp lease_actions(_lease, _caller), do: ["claim"]

  defp build_line(%{"ok" => false, "detail" => detail}), do: "BUILD REFUSED: #{detail}"

  defp build_line(%{"artifacts" => artifacts}) when is_map(artifacts),
    do: "artifacts: " <> Enum.map_join(artifacts, ", ", fn {n, s} -> "#{n} (#{s} bytes)" end)

  defp build_line(other), do: inspect(other)

  defp shell_quote(arg),
    do: if(arg =~ ~r/[\s"'$]/, do: "'" <> String.replace(arg, "'", "'\\''") <> "'", else: arg)

  defp short_sha(report) do
    case get_in(report, ["revision", "sha"]) do
      sha when is_binary(sha) -> String.slice(sha, 0, 8)
      _ -> "—"
    end
  end

  defp revision_detail(report) do
    cond do
      get_in(report, ["revision", "ok"]) != true ->
        get_in(report, ["revision", "detail"])

      get_in(report, ["revision", "dirty"]) == true ->
        "#{get_in(report, ["revision", "dirty_count"])} uncommitted paths"

      true ->
        nil
    end
  end

  defp engine_detail(report),
    do: get_in(report, ["engine", "version"]) || get_in(report, ["engine", "detail"])

  defp manifest_detail(report) do
    case get_in(report, ["manifest", "modes"]) do
      modes when is_list(modes) -> Enum.join(modes, ", ")
      _ -> get_in(report, ["manifest", "detail"])
    end
  end

  defp lease_line(nil), do: "—"
  defp lease_line(%{"held" => false}), do: "free"

  defp lease_line(%{"held" => true, "holder" => holder, "remaining_ms" => ms}),
    do: "#{holder}, #{div(ms, 1000)}s left"

  defp lease_line(_), do: "—"

  defp ready_line(%{"ready" => true, "ready_ms" => ms}) when is_integer(ms), do: "#{ms} ms"
  defp ready_line(%{"ready" => true}), do: "yes"
  defp ready_line(%{"marker" => nil}), do: "no marker declared"
  defp ready_line(_), do: "waiting"
end
