defmodule OrbitorcWeb.RunsLive do
  @moduledoc """
  Every run: the ones in flight first, then history; and the form that starts one.

  A live run's row updates from the run's own topic. Nothing here calls into a run process, which may be
  blocked on a box between phases — the row is the snapshot the run published.
  """

  use OrbitorcWeb, :live_view

  alias Orbitorc.{Fleet, Runs}
  alias OrbitorcWeb.Verbs

  @verbs ~w(runs run)
  @doc "The verbs this page runs; the parity test reads it."
  def verbs, do: @verbs

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orbitorc.PubSub, "runs")
    boxes = Fleet.list()

    {:ok,
     assign(socket,
       runs: load(),
       boxes: boxes,
       page_title: "Runs",
       form: %{
         "project" => boxes |> projects() |> List.first() || "",
         "authority_box" => "",
         "authority_mode" => "server",
         "load_mode" => "bench",
         "measure_s" => "25",
         "load_per_box" => "1",
         "link_mode" => "",
         "seed" => "1",
         "allow_colocated" => "false",
         "params" => ""
       },
       error: nil
     )}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, assign(socket, runs: load())}

  @impl true
  def handle_event("refresh", _params, socket),
    do: {:noreply, assign(socket, runs: load(), boxes: Fleet.list())}

  def handle_event("run_form", params, socket) do
    {:noreply, assign(socket, form: Map.merge(socket.assigns.form, form_fields(params)))}
  end

  def handle_event("run", params, socket) do
    form = Map.merge(socket.assigns.form, form_fields(params))

    payload =
      %{"project" => form["project"], "params" => parse_params(form["params"])}
      |> put_unless_blank("authority_box", form["authority_box"])
      |> put_unless_blank("authority_mode", form["authority_mode"])
      |> put_unless_blank("load_mode", form["load_mode"])
      |> put_unless_blank("measure_s", form["measure_s"])
      |> put_unless_blank("load_per_box", form["load_per_box"])
      |> put_unless_blank("link_mode", form["link_mode"])
      |> put_unless_blank("seed", form["seed"])
      |> Map.put("allow_colocated", form["allow_colocated"] == "true")

    case Verbs.run("run", payload, socket.assigns.caller) do
      {:ok, %{"id" => id}} -> {:noreply, push_navigate(socket, to: ~p"/run/#{id}")}
      {:error, {_status, reason}} -> {:noreply, assign(socket, form: form, error: reason)}
      {:error, reason} -> {:noreply, assign(socket, form: form, error: to_string(reason))}
    end
  end

  defp form_fields(params) do
    params
    |> Map.take(
      ~w(project authority_box authority_mode load_mode measure_s load_per_box link_mode seed params)
    )
    |> Map.put(
      "allow_colocated",
      if(params["allow_colocated"] in ["true", "on"], do: "true", else: "false")
    )
  end

  # One `key=value` per line; a numeric value becomes a number, as it does on the command line.
  @doc false
  def parse_params(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Map.new(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> {String.trim(key), Verbs.coerce(String.trim(value))}
        [key] -> {String.trim(key), true}
      end
    end)
  end

  def parse_params(_), do: %{}

  defp put_unless_blank(map, _key, value) when value in [nil, ""], do: map
  defp put_unless_blank(map, key, value), do: Map.put(map, key, value)

  defp load do
    live = Runs.live_runs()
    ids = MapSet.new(live, & &1.id)
    live ++ Enum.reject(Runs.list(50), &MapSet.member?(ids, &1.id))
  end

  defp projects(boxes),
    do: boxes |> Enum.flat_map(&Map.keys(&1.projects)) |> Enum.uniq() |> Enum.sort()

  @impl true
  def render(assigns) do
    assigns = assign(assigns, projects: projects(assigns.boxes))

    ~H"""
    <Layouts.app flash={@flash} caller={@caller} path={@path}>
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-semibold">Runs</h1>
        <span class="flex items-center gap-3 text-sm text-zinc-500">
          <a href={~p"/api/runs"} class="hover:underline">JSON</a>
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

      <section class="rounded border border-zinc-200 p-4">
        <h2 class="mb-2 text-lg font-medium">Start a run</h2>
        <p class="mb-3 text-sm text-zinc-600">
          An authority on one box, load on the others, measured until the clients finish and judged.
          Leave the authority box empty to let the run place it.
        </p>
        <form
          id="run-form"
          phx-change="run_form"
          phx-submit="run"
          class="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4"
        >
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Project</span>
            <select name="project" class="rounded border border-zinc-300 px-2 py-1">
              <option :for={p <- @projects} value={p} selected={p == @form["project"]}>{p}</option>
            </select>
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Authority box</span>
            <select name="authority_box" class="rounded border border-zinc-300 px-2 py-1">
              <option value="" selected={@form["authority_box"] == ""}>let the run place it</option>
              <option :for={b <- @boxes} value={b.name} selected={b.name == @form["authority_box"]}>
                {b.name}
              </option>
            </select>
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Authority mode</span>
            <input
              name="authority_mode"
              value={@form["authority_mode"]}
              class="rounded border border-zinc-300 px-2 py-1 font-mono"
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Load mode</span>
            <input
              name="load_mode"
              value={@form["load_mode"]}
              class="rounded border border-zinc-300 px-2 py-1 font-mono"
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Measure (s)</span>
            <input
              name="measure_s"
              value={@form["measure_s"]}
              class="rounded border border-zinc-300 px-2 py-1"
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Load per box</span>
            <input
              name="load_per_box"
              value={@form["load_per_box"]}
              class="rounded border border-zinc-300 px-2 py-1"
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Link mode (optional)</span>
            <input
              name="link_mode"
              value={@form["link_mode"]}
              class="rounded border border-zinc-300 px-2 py-1"
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Seed</span>
            <input name="seed" value={@form["seed"]} class="rounded border border-zinc-300 px-2 py-1" />
          </label>
          <label class="col-span-2 flex flex-col gap-1">
            <span class="text-zinc-500">Parameters, one <code>key=value</code> per line</span>
            <textarea
              name="params"
              rows="2"
              class="rounded border border-zinc-300 px-2 py-1 font-mono"
            >{@form["params"]}</textarea>
          </label>
          <label class="col-span-2 flex items-center gap-2 sm:col-span-3">
            <input type="hidden" name="allow_colocated" value="false" />
            <input
              type="checkbox"
              name="allow_colocated"
              value="true"
              checked={@form["allow_colocated"] == "true"}
            />
            <span>Allow load on the authority's box (measures the harness, not the netcode)</span>
          </label>
          <div class="flex items-end">
            <button
              class="rounded border border-zinc-800 bg-zinc-800 px-3 py-1 text-white disabled:opacity-40"
              disabled={is_nil(@caller) or @projects == []}
            >
              Run
            </button>
          </div>
        </form>
      </section>

      <p :if={@runs == []} class="text-sm text-zinc-500">No run yet.</p>

      <table :if={@runs != []} class="w-full text-sm">
        <thead class="text-left text-zinc-500">
          <tr>
            <th class="py-1">Run</th>
            <th>Project</th>
            <th>Phase</th>
            <th>Authority</th>
            <th>Load</th>
            <th>Elapsed</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={run <- @runs} class="border-t border-zinc-100">
            <td class="py-1 font-mono">
              <.link navigate={~p"/run/#{run.id}"} class="hover:underline">{run.id}</.link>
            </td>
            <td>{run.project}</td>
            <td class={phase_class(run.phase)}>{run.phase}</td>
            <td>
              {(run.authority && run.authority[:box]) || (run.authority && run.authority["box"]) ||
                "—"}
            </td>
            <td>{length(run.load || [])}</td>
            <td>{format_ms(run.elapsed_ms)}</td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end

  defp phase_class(:done), do: "text-emerald-700"
  defp phase_class(:failed), do: "text-red-700"
  defp phase_class(_), do: "text-amber-700"

  defp format_ms(ms) when is_integer(ms), do: "#{div(ms, 1000)}s"
  defp format_ms(_), do: "—"
end
