defmodule OrbitorcWeb.RunsLive do
  @moduledoc """
  Every run: the ones in flight first, then history.

  A live run's row updates from the run's own topic. Nothing here calls into a run process, which may be
  blocked on a box between phases — the row is the snapshot the run published.
  """

  use OrbitorcWeb, :live_view

  alias Orbitorc.Runs

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orbitorc.PubSub, "runs")
    {:ok, assign(socket, runs: load(), page_title: "Runs")}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, assign(socket, runs: load())}

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, assign(socket, runs: load())}

  defp load do
    live = Runs.live_runs()
    ids = MapSet.new(live, & &1.id)
    live ++ Enum.reject(Runs.list(50), &MapSet.member?(ids, &1.id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-6 space-y-6">
      <header class="flex items-baseline justify-between">
        <div>
          <.link navigate={~p"/"} class="text-sm text-zinc-500 hover:underline">← Fleet</.link>
          <h1 class="text-2xl font-semibold">Runs</h1>
        </div>
        <button
          phx-click="refresh"
          class="rounded border border-zinc-300 px-3 py-1 text-sm hover:bg-zinc-50"
        >
          Refresh
        </button>
      </header>

      <p :if={@runs == []} class="text-sm text-zinc-500">
        No run yet. <code>mix orbitorc run &lt;project&gt;</code> starts one.
      </p>

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
    </div>
    """
  end

  defp phase_class(:done), do: "text-emerald-700"
  defp phase_class(:failed), do: "text-red-700"
  defp phase_class(_), do: "text-amber-700"

  defp format_ms(ms) when is_integer(ms), do: "#{div(ms, 1000)}s"
  defp format_ms(_), do: "—"
end
