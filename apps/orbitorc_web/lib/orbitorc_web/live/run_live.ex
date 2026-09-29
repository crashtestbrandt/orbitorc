defmodule OrbitorcWeb.RunLive do
  @moduledoc """
  One run, as it happens.

  The page subscribes to the run's topic and re-renders on every snapshot the run publishes. What it
  shows is the timeline — each phase, when it began, and what the run learned in it — because the
  useful question about a failed run is never "did it fail" but "how far did it get, and what did it
  see last".
  """

  use OrbitorcWeb, :live_view

  alias Orbitorc.Run

  @verbs ~w(run-status)
  @doc "The verbs this page runs; the parity test reads it."
  def verbs, do: @verbs

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orbitorc.PubSub, Run.topic(id))

    socket = assign(socket, id: id, page_title: "Run #{id}")

    case OrbitorcWeb.Verbs.run("run-status", %{"id" => id}, socket.assigns.caller) do
      {:ok, snap} -> {:ok, assign(socket, run: snap, error: nil)}
      {:error, {_status, reason}} -> {:ok, assign(socket, run: nil, error: reason)}
      {:error, reason} -> {:ok, assign(socket, run: nil, error: to_string(reason))}
    end
  end

  @impl true
  def handle_info({:run, _id, snap}, socket),
    do: {:noreply, assign(socket, run: snap, error: nil)}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} caller={@caller} path={@path}>
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-semibold font-mono">{@id}</h1>
        <a href={~p"/api/run/#{@id}"} class="text-sm text-zinc-500 hover:underline">JSON</a>
      </header>

      <p :if={@error} class="rounded border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
        {@error}
      </p>

      <section :if={@run} class="space-y-6">
        <div class="grid grid-cols-2 gap-4 text-sm sm:grid-cols-4">
          <div>
            <p class="text-zinc-500">Project</p>
            <p>{@run.project}</p>
          </div>
          <div>
            <p class="text-zinc-500">Phase</p>
            <p class={phase_class(@run.phase)}>{@run.phase}</p>
          </div>
          <div>
            <p class="text-zinc-500">Caller</p>
            <p>{@run.caller}</p>
          </div>
          <div>
            <p class="text-zinc-500">Elapsed</p>
            <p>{format_ms(@run.elapsed_ms)}</p>
          </div>
        </div>

        <p :if={@run.failure} class="rounded border border-red-300 bg-red-50 p-3 text-sm text-red-900">
          {@run.failure}
        </p>

        <div>
          <h2 class="mb-2 text-lg font-medium">Timeline</h2>
          <ol class="space-y-1 text-sm">
            <li :for={entry <- @run.timeline || []} class="flex gap-3">
              <span class="w-16 shrink-0 text-right font-mono text-zinc-500">{format_at(at(entry))}</span>
              <span class="w-24 shrink-0 text-zinc-500">{field(entry, "phase")}</span>
              <span>{field(entry, "line")}</span>
            </li>
          </ol>
        </div>

        <div :if={(@run.verdicts || []) != []}>
          <h2 class="mb-2 text-lg font-medium">Verdicts</h2>
          <table class="w-full text-sm">
            <thead class="text-left text-zinc-500">
              <tr>
                <th class="py-1">Box</th>
                <th>Job</th>
                <th>Verdict</th>
                <th>Detail</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={v <- @run.verdicts} class="border-t border-zinc-100">
                <td class="py-1">{field(v, "box")}</td>
                <td class="font-mono">{field(v, "job")}</td>
                <td class={verdict_class(field(v, "verdict"))}>{field(v, "verdict")}</td>
                <td class="text-zinc-600">{field(v, "detail")}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  # Snapshots arrive with atom keys from a live run and string keys from history.
  defp field(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp at(entry), do: field(entry, "at")

  defp phase_class(:done), do: "text-emerald-700"
  defp phase_class(:failed), do: "text-red-700"
  defp phase_class(_), do: "text-amber-700"

  defp verdict_class(v) when v in ["measured", :measured], do: "text-emerald-700"
  defp verdict_class(v) when v in ["vacuous", :vacuous], do: "text-red-700"
  defp verdict_class(_), do: "text-zinc-600"

  defp format_ms(ms) when is_integer(ms), do: "#{div(ms, 1000)}s"
  defp format_ms(_), do: "—"

  defp format_at(ms) when is_integer(ms), do: "#{div(ms, 1000)}.#{rem(div(ms, 100), 10)}s"
  defp format_at(_), do: "—"
end
