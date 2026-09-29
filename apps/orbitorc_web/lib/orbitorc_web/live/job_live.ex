defmodule OrbitorcWeb.JobLive do
  @moduledoc """
  One job: its log as it is written, and everything that can be asked of it afterward.

  The page subscribes to the box's log topic, so a line reaches it the moment the agent forwards it —
  the same stream a run's readiness check reads. The tail on entry comes from the box's file; the lines
  after that arrive live. A finished job is still readable: its log, its artifacts and its verdict
  outlive the process, because a bench client self-terminates and its results are read after that.
  """

  use OrbitorcWeb, :live_view

  alias OrbitorcWeb.Verbs

  @verbs ~w(status logs stop shot pull verdict)
  @doc "The verbs this page runs; the parity test reads it."
  def verbs, do: @verbs

  @max_lines 2_000

  @impl true
  def mount(%{"name" => name, "id" => id}, _session, socket) do
    id = to_int(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Orbitorc.PubSub, "box:#{name}:job:#{id}")
      Phoenix.PubSub.subscribe(Orbitorc.PubSub, "box:#{name}:jobs")
    end

    {:ok,
     socket
     |> assign(
       name: name,
       id: id,
       page_title: "#{name} · job #{id}",
       job: nil,
       finished: false,
       lines: [],
       tail: "200",
       grep: "",
       shot: nil,
       verdict: nil,
       project: "",
       error: nil,
       notice: nil,
       busy: nil
     )
     |> load_job()
     |> load_logs()}
  end

  @impl true
  def handle_info({:log_line, name, id, line}, %{assigns: %{name: name, id: id}} = socket) do
    if matches?(line, socket.assigns.grep) do
      lines = Enum.take([line | Enum.reverse(socket.assigns.lines)], @max_lines) |> Enum.reverse()
      {:noreply, assign(socket, lines: lines)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:job_event, name, id, "exited", detail},
        %{assigns: %{name: name, id: id}} = socket
      ) do
    {:noreply,
     socket
     |> assign(finished: true, notice: "exited with status #{inspect(Map.get(detail, "status"))}")
     |> load_job()}
  end

  def handle_info({:job_event, name, id, _event, _}, %{assigns: %{name: name, id: id}} = socket),
    do: {:noreply, load_job(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("logs", params, socket) do
    {:noreply,
     socket
     |> assign(tail: params["tail"] || "200", grep: params["grep"] || "")
     |> load_logs()}
  end

  def handle_event("stop", _params, socket) do
    {:noreply,
     run_async(socket, :stop, "stop", %{"box" => socket.assigns.name, "id" => socket.assigns.id})}
  end

  def handle_event("shot", _params, socket) do
    {:noreply,
     run_async(socket, :shot, "shot", %{"box" => socket.assigns.name, "id" => socket.assigns.id})}
  end

  def handle_event("verdict", %{"project" => project}, socket) do
    payload = %{"box" => socket.assigns.name, "id" => socket.assigns.id, "project" => project}
    {:noreply, socket |> assign(project: project) |> run_async(:verdict, "verdict", payload)}
  end

  @impl true
  def handle_async(:stop, {:ok, {:ok, _}}, socket),
    do: {:noreply, socket |> assign(busy: nil, notice: "stopped") |> load_job()}

  # A capture lands on the box as shot.png; pulling it is what puts it on the page.
  def handle_async(:shot, {:ok, {:ok, %{"bytes" => bytes}}}, socket) do
    payload = %{"box" => socket.assigns.name, "id" => socket.assigns.id, "file" => "shot.png"}

    {:noreply,
     socket
     |> assign(notice: "captured the window (#{bytes} bytes)")
     |> run_async(:pull_shot, "pull", payload)}
  end

  def handle_async(:pull_shot, {:ok, {:ok, %{"base64" => encoded}}}, socket),
    do: {:noreply, assign(socket, busy: nil, shot: "data:image/png;base64," <> encoded)}

  def handle_async(:verdict, {:ok, {:ok, verdict}}, socket),
    do: {:noreply, assign(socket, busy: nil, verdict: verdict)}

  def handle_async(_name, {:ok, {:ok, value}}, socket),
    do: {:noreply, assign(socket, busy: nil, notice: inspect(value))}

  def handle_async(_name, {:ok, {:error, {_status, reason}}}, socket),
    do: {:noreply, assign(socket, busy: nil, error: to_string(reason))}

  def handle_async(_name, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, busy: nil, error: to_string(reason))}

  def handle_async(_name, {:exit, reason}, socket),
    do: {:noreply, assign(socket, busy: nil, error: "the verb crashed: #{inspect(reason)}")}

  defp run_async(socket, name, verb, payload) do
    caller = socket.assigns.caller

    socket
    |> assign(busy: name, error: nil)
    |> start_async(name, fn -> Verbs.run(verb, payload, caller) end)
  end

  # `status` lists what is running. A job that is not in it has finished (or never existed; the log
  # says which).
  defp load_job(socket) do
    case Verbs.run("status", %{"box" => socket.assigns.name}, socket.assigns.caller) do
      {:ok, %{"jobs" => jobs}} ->
        case Enum.find(jobs, &(&1["id"] == socket.assigns.id)) do
          nil ->
            assign(socket, job: socket.assigns.job, finished: true)

          job ->
            assign(socket,
              job: job,
              finished: false,
              project: job["project"] || socket.assigns.project
            )
        end

      {:error, {_status, reason}} ->
        assign(socket, error: to_string(reason))

      {:error, reason} ->
        assign(socket, error: to_string(reason))
    end
  end

  defp load_logs(socket) do
    payload = %{
      "box" => socket.assigns.name,
      "id" => socket.assigns.id,
      "tail" => socket.assigns.tail,
      "grep" => socket.assigns.grep
    }

    case Verbs.run("logs", payload, socket.assigns.caller) do
      {:ok, lines} when is_list(lines) -> assign(socket, lines: lines, error: nil)
      {:error, {_status, reason}} -> assign(socket, error: to_string(reason))
      {:error, reason} -> assign(socket, error: to_string(reason))
    end
  end

  defp matches?(_line, ""), do: true

  defp matches?(line, grep) do
    case Regex.compile(grep) do
      {:ok, rx} -> Regex.match?(rx, line)
      _ -> true
    end
  end

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} caller={@caller} path={@path}>
      <header class="flex items-baseline justify-between">
        <div>
          <.link navigate={~p"/box/#{@name}"} class="text-sm text-zinc-500 hover:underline">← {@name}</.link>
          <h1 class="text-2xl font-semibold">job {@id}</h1>
        </div>
        <span class="text-sm text-zinc-500">
          <a href={~p"/api/box/#{@name}/jobs/#{@id}/logs?tail=#{@tail}"} class="hover:underline">JSON</a>
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

      <div class="grid grid-cols-2 gap-4 text-sm sm:grid-cols-4">
        <div>
          <p class="text-zinc-500">Project / mode</p>
          <p>{(@job && "#{@job["project"]}/#{@job["mode"]}") || "—"}</p>
        </div>
        <div>
          <p class="text-zinc-500">Caller</p>
          <p>{(@job && @job["caller"]) || "—"}</p>
        </div>
        <div>
          <p class="text-zinc-500">Ready</p>
          <p>{if @job, do: ready_line(@job), else: "—"}</p>
        </div>
        <div>
          <p class="text-zinc-500">State</p>
          <p class={if @finished, do: "text-zinc-700", else: "text-emerald-700"}>
            {if @finished, do: "finished", else: "running"}
          </p>
        </div>
      </div>

      <div class="flex flex-wrap items-end gap-3 text-sm">
        <button
          phx-click="stop"
          class="rounded border border-zinc-300 px-3 py-1 hover:bg-zinc-50 disabled:opacity-40"
          disabled={is_nil(@caller) or @finished or @busy == :stop}
        >
          Stop
        </button>
        <button
          phx-click="shot"
          class="rounded border border-zinc-300 px-3 py-1 hover:bg-zinc-50 disabled:opacity-40"
          disabled={is_nil(@caller) or @finished or @busy in [:shot, :pull_shot]}
        >
          {if @busy in [:shot, :pull_shot], do: "Capturing…", else: "Shot"}
        </button>
        <form id="verdict-form" phx-submit="verdict" class="flex items-end gap-2">
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Project</span>
            <input
              name="project"
              value={@project}
              class="w-32 rounded border border-zinc-300 px-2 py-1 font-mono"
            />
          </label>
          <button
            class="rounded border border-zinc-300 px-3 py-1 hover:bg-zinc-50 disabled:opacity-40"
            disabled={@busy == :verdict}
          >
            Verdict
          </button>
        </form>
        <form action={~p"/box/#{@name}/job/#{@id}/pull"} method="get" class="flex items-end gap-2">
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Artifact</span>
            <input
              name="file"
              value="metrics.csv"
              class="w-40 rounded border border-zinc-300 px-2 py-1 font-mono"
            />
          </label>
          <button class="rounded border border-zinc-300 px-3 py-1 hover:bg-zinc-50">Download</button>
        </form>
      </div>

      <p :if={@verdict} class={"text-sm " <> verdict_class(@verdict["verdict"])}>
        {@verdict["verdict"]} — {@verdict["detail"]}
      </p>

      <img
        :if={@shot}
        src={@shot}
        alt="the job's window"
        class="max-w-full rounded border border-zinc-200"
      />

      <section>
        <form id="logs-form" phx-submit="logs" class="mb-2 flex flex-wrap items-end gap-3 text-sm">
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Tail</span>
            <input name="tail" value={@tail} class="w-20 rounded border border-zinc-300 px-2 py-1" />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Grep</span>
            <input
              name="grep"
              value={@grep}
              class="w-56 rounded border border-zinc-300 px-2 py-1 font-mono"
            />
          </label>
          <button class="rounded border border-zinc-300 px-3 py-1 hover:bg-zinc-50">Reload</button>
          <span :if={not @finished} class="pb-1 text-zinc-500">new lines arrive as the box writes them</span>
        </form>
        <pre
          id="job-log"
          class="max-h-[32rem] overflow-auto rounded bg-zinc-900 p-3 font-mono text-xs text-zinc-100"
        >{Enum.join(@lines, "\n")}</pre>
      </section>
    </Layouts.app>
    """
  end

  defp verdict_class(v) when v in ["measured", :measured], do: "text-emerald-700"
  defp verdict_class(v) when v in ["vacuous", :vacuous], do: "text-red-700"
  defp verdict_class(_), do: "text-zinc-600"

  defp ready_line(%{"ready" => true, "ready_ms" => ms}) when is_integer(ms), do: "#{ms} ms"
  defp ready_line(%{"ready" => true}), do: "yes"
  defp ready_line(%{"marker" => nil}), do: "no marker declared"
  defp ready_line(_), do: "waiting"
end
