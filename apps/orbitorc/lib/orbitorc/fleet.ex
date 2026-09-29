defmodule Orbitorc.Fleet do
  @moduledoc """
  Which boxes are connected right now, and what each says it can do.

  ## Presence is the connection, not a heartbeat table

  A box is in the fleet exactly as long as its socket is up. The process that owns that socket is
  monitored, so a box that crashes, loses power or loses its network leaves the fleet without anybody
  polling for it and without a timeout to tune.

  That matters for correctness, not tidiness: a caller choosing where to put a server must not be
  offered a box that stopped answering four minutes ago and has not yet failed a health check.

  ## A box reports its own capabilities

  Nothing here infers what a box can do from its platform or its name. The box answers, and the answer
  is what a verb is checked against — so a refusal reads as "this target cannot do that" rather than an
  obscure error from three layers down.
  """

  use GenServer
  require Logger

  @topic "fleet"

  @type box :: %{
          name: String.t(),
          pid: pid(),
          platform: String.t(),
          session: {boolean(), String.t()},
          lan: String.t() | nil,
          projects: %{String.t() => map()},
          capabilities: map(),
          engine: String.t() | nil,
          report: map(),
          joined_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The PubSub topic fleet changes are announced on."
  def topic, do: @topic

  @doc """
  Record a box as joined. The caller's process is monitored, so leaving needs no message.
  """
  @spec join(String.t(), map()) :: :ok | {:error, {:duplicate, pid()}}
  def join(name, report), do: GenServer.call(__MODULE__, {:join, name, report, self()})

  @doc "Replace a box's report — a re-`doctor` without reconnecting."
  @spec update(String.t(), map()) :: :ok
  def update(name, report), do: GenServer.call(__MODULE__, {:update, name, report})

  @doc "Every connected box, by name."
  @spec list() :: [box()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "One box, or that it is not connected."
  @spec fetch(String.t()) :: {:ok, box()} | {:error, :not_connected}
  def fetch(name), do: GenServer.call(__MODULE__, {:fetch, name})

  @doc """
  Boxes that can serve `project`/`mode`, in the order they joined.

  This is what a run uses to place work, and it is why capability reporting is not decoration: placing
  a rendering job on a box with no graphical session produces a job that draws nothing and reports
  success.
  """
  @spec capable(String.t(), String.t()) :: [box()]
  def capable(project, mode) do
    name = Orbitorc.Capability.launch(project, mode)
    Enum.filter(list(), &Orbitorc.Capability.permits?(&1.capabilities, name))
  end

  @impl true
  def init(_opts), do: {:ok, %{boxes: %{}, monitors: %{}}}

  @impl true
  def handle_call({:join, name, report, pid}, _from, state) do
    case Map.fetch(state.boxes, name) do
      {:ok, %{pid: existing}} when existing != pid ->
        # Two boxes claiming one name is a misconfiguration, and silently letting the second win would
        # send a caller's job to a machine it did not choose.
        {:reply, {:error, {:duplicate, existing}}, state}

      _ ->
        ref = Process.monitor(pid)
        box = build(name, report, pid)

        state = %{
          state
          | boxes: Map.put(state.boxes, name, box),
            monitors: Map.put(state.monitors, ref, name)
        }

        Logger.info("fleet: #{name} joined (#{box.platform})")
        announce({:joined, box})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:update, name, report}, _from, state) do
    case Map.fetch(state.boxes, name) do
      {:ok, box} ->
        box = build(name, report, box.pid, box.joined_at)
        announce({:updated, box})
        {:reply, :ok, %{state | boxes: Map.put(state.boxes, name, box)}}

      :error ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.boxes |> Map.values() |> Enum.sort_by(& &1.name), state}
  end

  @impl true
  def handle_call({:fetch, name}, _from, state) do
    case Map.fetch(state.boxes, name) do
      {:ok, box} -> {:reply, {:ok, box}, state}
      :error -> {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {name, monitors} ->
        Logger.info("fleet: #{name} left (#{inspect(reason)})")
        # A caller waiting on this box must not wait on a machine that has gone.
        Orbitorc.Request.fail_box(name, reason)
        announce({:left, name})
        {:noreply, %{state | boxes: Map.delete(state.boxes, name), monitors: monitors}}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp build(name, report, pid, joined_at \\ nil) do
    %{
      name: name,
      pid: pid,
      platform: Map.get(report, "platform", "unknown"),
      session: {Map.get(report, "session_ok", false), Map.get(report, "session_detail", "")},
      lan: Map.get(report, "lan"),
      projects: Map.get(report, "projects", %{}),
      capabilities: Map.get(report, "capabilities", %{}),
      engine: Map.get(report, "engine"),
      problems: Map.get(report, "problems", []),
      # The raw report is kept whole. A box declares its own port band, and a run that guessed instead
      # would place load on a port the box does not bind.
      report: report,
      joined_at: joined_at || DateTime.utc_now()
    }
  end

  defp announce(event), do: Phoenix.PubSub.broadcast(Orbitorc.PubSub, @topic, {:fleet, event})
end
