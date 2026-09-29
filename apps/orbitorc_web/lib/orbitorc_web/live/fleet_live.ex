defmodule OrbitorcWeb.FleetLive do
  @moduledoc """
  The fleet, live.

  It subscribes to the fleet's own topic rather than polling, so a box appearing or vanishing reaches
  the page as the same message the run state machine acts on. There is one source of truth about who is
  connected and everything reads it.

  What the page is for is judging whether a run placed here would mean anything, so it leads with the
  things that make a result untrustworthy: a box with no graphical session, a checkout that disagrees
  with the rest of the fleet, a stale import cache, a dirty tree.
  """

  use OrbitorcWeb, :live_view

  alias Orbitorc.Fleet

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Orbitorc.PubSub, Fleet.topic())
    {:ok, assign(socket, boxes: Fleet.list(), page_title: "Fleet")}
  end

  @impl true
  def handle_info({:fleet, _event}, socket), do: {:noreply, assign(socket, boxes: Fleet.list())}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, revisions: revisions(assigns.boxes))

    ~H"""
    <div class="mx-auto max-w-5xl p-6 space-y-6">
      <header class="flex items-baseline justify-between">
        <h1 class="text-2xl font-semibold">Fleet</h1>
        <span class="text-sm text-zinc-500">{length(@boxes)} connected</span>
      </header>

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

      <ul class="space-y-3">
        <li :for={box <- @boxes} class="rounded border border-zinc-200 p-4">
          <div class="flex items-baseline justify-between">
            <.link navigate={~p"/box/#{box.name}"} class="text-lg font-medium hover:underline">
              {box.name}
            </.link>
            <span class="text-sm text-zinc-500">{box.platform}</span>
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
            </li>
          </ul>
        </li>
      </ul>
    </div>
    """
  end

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
