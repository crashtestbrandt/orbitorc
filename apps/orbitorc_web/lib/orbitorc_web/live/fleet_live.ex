defmodule OrbitorcWeb.FleetLive do
  @moduledoc """
  The fleet, live, and the verbs that act on all of it.

  It subscribes to the fleet's own topic rather than polling, so a box appearing or vanishing reaches
  the page as the same message the run state machine acts on. There is one source of truth about who is
  connected and everything reads it.

  What the page is for is judging whether a run placed here would mean anything, so it leads with the
  things that make a result untrustworthy: a box with no graphical session, a checkout that disagrees
  with the rest of the fleet, a stale import cache, a dirty tree. `sync` is here because it is the
  fleet-wide verb: every box to one revision, and whether they agree afterward.
  """

  use OrbitorcWeb, :live_view

  alias Orbitorc.Fleet
  alias OrbitorcWeb.Verbs

  @verbs ~w(fleet doctor sync)
  @doc "The verbs this page runs; the parity test reads it."
  def verbs, do: @verbs

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orbitorc.PubSub, Fleet.topic())
    boxes = Fleet.list()

    {:ok,
     assign(socket,
       boxes: boxes,
       page_title: "Fleet",
       sync: %{"project" => first_project(boxes), "revision" => "main", "box" => ""},
       sync_result: nil,
       busy: nil,
       error: nil
     )}
  end

  @impl true
  def handle_info({:fleet, _event}, socket), do: {:noreply, assign(socket, boxes: Fleet.list())}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("sync_form", params, socket) do
    {:noreply, assign(socket, sync: Map.take(params, ["project", "revision", "box"]))}
  end

  def handle_event("sync", params, socket) do
    payload =
      %{"project" => params["project"], "revision" => params["revision"]}
      |> then(&if params["box"] in [nil, ""], do: &1, else: Map.put(&1, "boxes", [params["box"]]))

    {:noreply,
     socket
     |> assign(
       sync: Map.take(params, ["project", "revision", "box"]),
       sync_result: nil,
       error: nil
     )
     |> run_async(:sync, "sync", payload)}
  end

  # A fresh report, taken from the box rather than the fleet's cache; the fleet learns it too.
  def handle_event("doctor", %{"box" => name}, socket) do
    {:noreply,
     socket |> assign(error: nil) |> run_async({:doctor, name}, "doctor", %{"box" => name})}
  end

  @impl true
  def handle_async(:sync, {:ok, {:ok, result}}, socket) do
    {:noreply, assign(socket, sync_result: result, busy: nil)}
  end

  def handle_async({:doctor, _name}, {:ok, {:ok, _report}}, socket) do
    {:noreply, assign(socket, busy: nil, boxes: Fleet.list())}
  end

  def handle_async(_name, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, busy: nil, error: format_error(reason))}
  end

  def handle_async(_name, {:exit, reason}, socket) do
    {:noreply, assign(socket, busy: nil, error: "the verb crashed: #{inspect(reason)}")}
  end

  defp run_async(socket, name, verb, payload) do
    caller = socket.assigns.caller

    socket
    |> assign(busy: name)
    |> start_async(name, fn -> Verbs.run(verb, payload, caller) end)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, revisions: revisions(assigns.boxes), projects: projects(assigns.boxes))

    ~H"""
    <Layouts.app flash={@flash} caller={@caller} path={@path}>
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-semibold">Fleet</h1>
        <span class="text-sm text-zinc-500">
          {length(@boxes)} connected · <a href={~p"/api/fleet"} class="hover:underline">JSON</a>
        </span>
      </header>

      <Layouts.identity_notice caller={@caller} />

      <p :if={@error} class="rounded border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
        {@error}
      </p>

      <div
        :if={@boxes == []}
        class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500"
      >
        <p class="font-medium">No box is connected.</p>
        <p class="mt-1 text-sm">
          An agent dials out to this control plane. Start one on a machine and it appears here.
        </p>
      </div>

      <div
        :if={length(@revisions) > 1}
        class="rounded border border-amber-300 bg-amber-50 p-4 text-sm"
      >
        <p class="font-semibold text-amber-900">The fleet is not on one revision.</p>
        <p class="mt-1 text-amber-800">
          Two machines running different code produce a disagreement that reads as a netcode bug.
          Present: {Enum.join(@revisions, ", ")}
        </p>
      </div>

      <section :if={@boxes != []} class="rounded border border-zinc-200 p-4">
        <h2 class="mb-2 text-lg font-medium">Sync</h2>
        <p class="mb-3 text-sm text-zinc-600">
          Every box, or one, to a revision. A branch name is the remote's branch. This is a force
          checkout, so it needs a name and takes the lease.
        </p>
        <form
          id="sync-form"
          phx-change="sync_form"
          phx-submit="sync"
          class="flex flex-wrap items-end gap-3 text-sm"
        >
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Project</span>
            <select name="project" class="rounded border border-zinc-300 px-2 py-1">
              <option :for={p <- @projects} value={p} selected={p == @sync["project"]}>{p}</option>
            </select>
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Revision</span>
            <input
              name="revision"
              value={@sync["revision"]}
              class="w-40 rounded border border-zinc-300 px-2 py-1 font-mono"
            />
          </label>
          <label class="flex flex-col gap-1">
            <span class="text-zinc-500">Box</span>
            <select name="box" class="rounded border border-zinc-300 px-2 py-1">
              <option value="" selected={@sync["box"] == ""}>every box</option>
              <option :for={b <- @boxes} value={b.name} selected={b.name == @sync["box"]}>
                {b.name}
              </option>
            </select>
          </label>
          <button
            class="rounded border border-zinc-800 bg-zinc-800 px-3 py-1 text-white disabled:opacity-40"
            disabled={is_nil(@caller) or @busy == :sync}
          >
            {if @busy == :sync, do: "Syncing…", else: "Sync"}
          </button>
        </form>

        <div :if={@sync_result} class="mt-4 text-sm">
          <table class="w-full">
            <tbody>
              <tr :for={{box, r} <- Enum.sort(@sync_result.synced)} class="border-t border-zinc-100">
                <td class="py-1 font-medium">{box}</td>
                <td class="font-mono">{String.slice(r["sha"] || "?", 0, 8)}</td>
                <td class="text-zinc-500">{r["branch"]}</td>
              </tr>
              <tr
                :for={{box, reason} <- Enum.sort(@sync_result.failed)}
                class="border-t border-zinc-100"
              >
                <td class="py-1 font-medium">{box}</td>
                <td colspan="2" class="text-red-700">refused: {reason}</td>
              </tr>
            </tbody>
          </table>
          <p class={"mt-2 " <> if(@sync_result.agreed, do: "text-emerald-700", else: "text-amber-800")}>
            {agreement_line(@sync_result)}
          </p>
        </div>
      </section>

      <ul class="space-y-3">
        <li :for={box <- @boxes} class="rounded border border-zinc-200 p-4">
          <div class="flex items-baseline justify-between">
            <.link navigate={~p"/box/#{box.name}"} class="text-lg font-medium hover:underline">
              {box.name}
            </.link>
            <span class="flex items-center gap-3 text-sm text-zinc-500">
              {box.platform}
              <button
                phx-click="doctor"
                phx-value-box={box.name}
                class="rounded border border-zinc-300 px-2 py-0.5 hover:bg-zinc-50 disabled:opacity-40"
                disabled={@busy == {:doctor, box.name}}
              >
                {if @busy == {:doctor, box.name}, do: "Asking…", else: "Doctor"}
              </button>
            </span>
          </div>

          <dl class="mt-3 grid grid-cols-2 gap-x-6 gap-y-1 text-sm sm:grid-cols-3">
            <div>
              <dt class="text-zinc-500">Session</dt>
              <dd class={if elem(box.session, 0), do: "text-emerald-700", else: "text-amber-700"}>
                {if elem(box.session, 0), do: "renders", else: "headless only"}
              </dd>
            </div>
            <div>
              <dt class="text-zinc-500">LAN</dt>
              <dd>{box.lan || "—"}</dd>
            </div>
            <div>
              <dt class="text-zinc-500">Projects</dt>
              <dd>{box.projects |> Map.keys() |> Enum.sort() |> Enum.join(", ")}</dd>
            </div>
          </dl>

          <p :if={box.problems != []} class="mt-3 text-sm text-amber-800">
            {Enum.join(box.problems, "; ")}
          </p>

          <ul class="mt-3 space-y-1 text-sm">
            <li :for={{name, report} <- Enum.sort(box.projects)} class="flex flex-wrap gap-x-3">
              <span class="font-mono">{name}</span>
              <span class="text-zinc-500">{short_sha(report)}</span>
              <span :if={dirty?(report)} class="text-amber-700">dirty</span>
              <span :if={stale?(report)} class="text-amber-700">stale import cache</span>
              <span :if={get_in(report, ["manifest", "ok"]) == false} class="text-amber-700">
                no manifest
              </span>
            </li>
          </ul>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  defp agreement_line(%{agreed: true, revisions: [sha]}), do: "every box agrees on #{sha}"

  defp agreement_line(%{failed: failed}) when map_size(failed) > 0,
    do: "#{map_size(failed)} box(es) refused"

  defp agreement_line(%{revisions: shas}),
    do: "THE FLEET DISAGREES: #{Enum.join(shas, ", ")}"

  defp format_error({_status, reason}), do: to_string(reason)
  defp format_error(reason), do: to_string(reason)

  defp projects(boxes),
    do: boxes |> Enum.flat_map(&Map.keys(&1.projects)) |> Enum.uniq() |> Enum.sort()

  defp first_project(boxes), do: boxes |> projects() |> List.first() || ""

  defp revisions(boxes) do
    boxes
    |> Enum.flat_map(fn box ->
      Enum.map(box.projects, fn {_name, report} -> short_sha(report) end)
    end)
    |> Enum.reject(&(&1 == "—"))
    |> Enum.uniq()
  end

  defp short_sha(report) do
    case get_in(report, ["revision", "sha"]) do
      sha when is_binary(sha) -> String.slice(sha, 0, 8)
      _ -> "—"
    end
  end

  defp dirty?(report), do: get_in(report, ["revision", "dirty"]) == true
  defp stale?(report), do: get_in(report, ["import", "ok"]) == false
end
