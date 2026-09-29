defmodule OrbitorcWeb.AgentChannel do
  @moduledoc """
  One connected box, from the control plane's side.

  ## The channel process is the box's presence

  `Orbitorc.Fleet` monitors this process, so a box leaves the fleet when its socket goes — no
  heartbeat table to fall behind, no timeout to tune. A box that lost power is gone from the next
  placement decision rather than four minutes later.

  ## A box may only claim the name it authenticated as

  The join payload carries a name, and it is checked against the token the socket authenticated with. A
  box that could announce itself as another would let a caller's job land on a machine it did not
  choose.

  ## Requests carry a ref, and a reply resolves it

  The control plane asks and the box answers asynchronously, because a launch is slow and an agent must
  never be blocked on one request while another arrives. `Orbitorc.Fleet.Request` holds the waiting
  caller; a box that disconnects mid-request fails it rather than leaving the caller hanging.
  """

  use OrbitorcWeb, :channel

  require Logger

  alias Orbitorc.Fleet

  @impl true
  def join("agent", payload, socket) do
    authenticated = socket.assigns.box
    claimed = Map.get(payload, "name")

    cond do
      claimed != authenticated ->
        Logger.warning("agent #{authenticated} tried to join as #{inspect(claimed)}")
        {:error, %{reason: "this token belongs to #{authenticated}"}}

      true ->
        report = Map.get(payload, "report", %{})

        case Fleet.join(authenticated, report) do
          :ok ->
            {:ok,
             %{
               "name" => authenticated,
               "server_time" => DateTime.utc_now() |> DateTime.to_iso8601()
             }, assign(socket, name: authenticated)}

          {:error, {:duplicate, _pid}} ->
            {:error, %{reason: "#{authenticated} is already connected from another process"}}
        end
    end
  end

  @impl true
  def handle_in("reply", %{"ref" => ref, "result" => result}, socket) do
    Orbitorc.Request.resolve(ref, decode(result))
    {:noreply, socket}
  end

  @impl true
  def handle_in("report", %{"report" => report}, socket) do
    Fleet.update(socket.assigns.name, report)
    {:noreply, socket}
  end

  # A box streams its jobs' log lines as they appear, so readiness, failure detection and the dashboard
  # all read one stream rather than three pieces of code polling three copies of a file.
  @impl true
  def handle_in("log", %{"job" => job, "line" => line}, socket) do
    Phoenix.PubSub.broadcast(
      Orbitorc.PubSub,
      "box:#{socket.assigns.name}:job:#{job}",
      {:log_line, socket.assigns.name, job, line}
    )

    {:noreply, socket}
  end

  # A job on the box came up or went down. A run waiting on either is subscribed to this topic; so is a
  # box's page. Neither polls, and neither waits out a timeout to learn what already happened.
  @impl true
  def handle_in("job_event", %{"job" => job, "event" => event} = payload, socket) do
    Phoenix.PubSub.broadcast(
      Orbitorc.PubSub,
      "box:#{socket.assigns.name}:jobs",
      {:job_event, socket.assigns.name, job, event, Map.get(payload, "detail", %{})}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_in(event, _payload, socket) do
    Logger.debug("agent #{socket.assigns.name} sent an unhandled #{event}")
    {:noreply, socket}
  end

  # `Orbitorc.Box` sends this from whatever process is asking. The channel is the only process that
  # holds the socket, so every request funnels through here.
  @impl true
  def handle_info({:ask, verb, payload}, socket) do
    push(socket, verb, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp decode(%{"ok" => true, "value" => value}), do: {:ok, value}
  defp decode(%{"ok" => false, "error" => reason}), do: {:error, reason}
  defp decode(other), do: {:error, "the box answered something unreadable: #{inspect(other)}"}
end
