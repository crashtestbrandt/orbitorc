defmodule OrbitorcWeb.BoxLive do
  @moduledoc """
  One box: what it reports, what it is running, and the checks that decide whether to believe a result
  taken here.

  The health table leads with the checks that catch a **confident wrong answer** rather than an outright
  failure, because those are the ones a person has to be told about. A box that cannot launch says so
  when asked; a box with a stale import cache launches, comes up, and writes a file full of zeros.
  """

  use OrbitorcWeb, :live_view

  alias Orbitorc.{Box, Fleet}

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orbitorc.PubSub, Fleet.topic())

    {:ok,
     socket
     |> assign(name: name, page_title: name, jobs: [], lease: nil, error: nil)
     |> load_box()
     |> load_status()}
  end

  @impl true
  def handle_info({:fleet, _event}, socket), do: {:noreply, load_box(socket)}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket),
    do: {:noreply, socket |> load_box() |> load_status()}

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
    case Box.status(socket.assigns.name, "dashboard") do
      {:ok, %{"jobs" => jobs, "lease" => lease}} -> assign(socket, jobs: jobs, lease: lease)
      {:error, reason} -> assign(socket, error: reason)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-6 space-y-6">
      <header class="flex items-baseline justify-between">
        <div>
          <.link navigate={~p"/"} class="text-sm text-zinc-500 hover:underline">← Fleet</.link>
          <h1 class="text-2xl font-semibold">{@name}</h1>
        </div>
        <button
          phx-click="refresh"
          class="rounded border border-zinc-300 px-3 py-1 text-sm hover:bg-zinc-50"
        >
          Refresh
        </button>
      </header>

      <p :if={@error} class="rounded border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
        {@error}
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
            <p>{lease_line(@lease)}</p>
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
                label="Manifest"
                ok={get_in(report, ["manifest", "ok"])}
                detail={manifest_detail(report)}
              />
            </dl>
          </div>
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
              </tr>
            </thead>
            <tbody>
              <tr :for={job <- @jobs} class="border-t border-zinc-100">
                <td class="py-1 font-mono">{job["id"]}</td>
                <td>{job["project"]}</td>
                <td>{job["mode"]}</td>
                <td>{job["caller"]}</td>
                <td>{ready_line(job)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
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
