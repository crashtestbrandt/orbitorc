defmodule Orbitorc.Run do
  @moduledoc """
  A whole session across several machines, as one supervised process.

  A run claims the boxes it will use, brings up an authority, waits for it to prove it is up,
  optionally puts a conditioned link in front of it, fans load out across the remaining boxes, waits
  for every client to come up, lets the window run until the clients finish, collects every verdict
  and judges what came back. Then it releases the boxes and stops.

  ## Why this is a process and not a script

  The shell version of this is a sequence of background launches, `wait` loops and a signal trap. It has
  three problems that are not stylistic:

  | | |
  | --- | --- |
  | **Teardown is best-effort** | A trap runs only for the signals it caught. A script killed another way leaves every process it launched holding its ports. Here the run is linked to what it launched, so its death is their death. |
  | **Failure is discovered late** | A script waits for a marker with a timeout, so a box that died at parse time is indistinguishable from a slow one until the timeout expires. Here a job exiting before it is ready is a message, and the run fails on it immediately, naming the job. |
  | **Partial state is invisible** | A script that dies mid-run leaves no record of how far it got. Here every phase transition is published, so a run that failed at fan-out is distinguishable from one that never got an authority up. |

  ## Nothing here is a sleep

  Bringup waits for the mode's ready marker, forwarded from the box as an event. The measurement window
  waits for the load clients to exit on their own, which is what a bench client does when its window
  closes. Both carry a deadline, and a deadline firing is a failure with a name — not the normal way a
  phase ends.

  ## The placement rule

  **The authority gets a box to itself, and the load goes elsewhere.** This is the entire reason the
  project exists: a server measured while its own clients saturate the same machine produces a number
  that describes the harness. A run refuses to place load on the authority's box unless explicitly told
  to, and says so rather than quietly producing a figure nobody should trust.

  ## Leases are the run's, for the run's life

  A run claims every box it will touch before it touches any of them, and releases them when it ends.
  A caller who wants to watch may; a caller who wants to sync a box mid-measurement cannot, which is
  the failure the lease exists to prevent.

  ## Phases

      :placing -> :authority -> :link -> :load -> :measuring -> :collecting -> :done | :failed
  """

  use GenServer, restart: :temporary

  require Logger

  alias Orbitorc.{Box, Fleet, Runs}

  @type phase ::
          :placing | :authority | :link | :load | :measuring | :collecting | :done | :failed

  @type spec :: %{
          required(:project) => String.t(),
          required(:caller) => String.t(),
          optional(:id) => String.t(),
          optional(:authority_box) => String.t(),
          optional(:load_boxes) => [String.t()],
          optional(:authority_mode) => String.t(),
          optional(:load_mode) => String.t(),
          optional(:link_mode) => String.t() | nil,
          optional(:load_per_box) => pos_integer(),
          optional(:measure_s) => pos_integer(),
          optional(:seed) => integer(),
          optional(:params) => map(),
          optional(:allow_colocated) => boolean()
        }

  @default_measure_s 25
  @default_load_per_box 1

  # How long a mode is given to print its marker. Generous: a cold engine imports before it launches.
  @bringup_timeout_ms 90_000

  # Past the window, how long the clients are given to flush and quit on their own.
  @finish_grace_s 60

  @spec start_link(spec()) :: GenServer.on_start()
  def start_link(spec), do: GenServer.start_link(__MODULE__, spec)

  @doc "A fresh run id, so a caller can name a run before its process exists."
  def new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  @doc "The PubSub topic a run announces its phases on."
  def topic(id), do: "run:#{id}"

  @doc "A snapshot a caller or a dashboard can render. Blocks only while the process is between phases."
  def info(pid), do: GenServer.call(pid, :info)

  @doc "Abandon a run. Everything it launched goes with it, and its boxes are released."
  def abort(pid), do: GenServer.stop(pid, :normal)

  @doc false
  def bringup_timeout_ms, do: @bringup_timeout_ms

  @impl true
  def init(spec) do
    # Trapping exits is what makes teardown a guarantee rather than a hope: terminate/2 runs on a
    # supervisor shutdown, so a stopping control plane stops the fleet's jobs too.
    Process.flag(:trap_exit, true)
    Phoenix.PubSub.subscribe(Orbitorc.PubSub, Fleet.topic())

    spec = defaults(spec)

    state = %{
      id: Map.get(spec, :id) || new_id(),
      spec: spec,
      phase: :placing,
      authority: nil,
      link: nil,
      load: [],
      leases: [],
      waiting: nil,
      timer: nil,
      started_at: System.system_time(:millisecond),
      finished_at: nil,
      failure: nil,
      verdicts: [],
      timeline: []
    }

    register(state)
    state = note(state, :placing, "placing")
    {:ok, state, {:continue, :place}}
  end

  defp defaults(spec) do
    Map.merge(
      %{
        authority_mode: "server",
        load_mode: "bench",
        link_mode: nil,
        load_per_box: @default_load_per_box,
        measure_s: @default_measure_s,
        seed: 1,
        params: %{},
        allow_colocated: false,
        # Overridable so a test can exercise a deadline without waiting one out.
        bringup_timeout_ms: @bringup_timeout_ms,
        finish_grace_s: @finish_grace_s
      },
      spec
    )
  end

  # --- phases ---------------------------------------------------------------------------------------

  @impl true
  def handle_continue(:place, state) do
    with {:ok, authority, load_boxes} <- place(state),
         state = %{
           state
           | spec: Map.merge(state.spec, %{authority_box: authority, load_boxes: load_boxes})
         },
         {:ok, state} <- claim_leases(state, Enum.uniq([authority | load_boxes])) do
      # Once per box. A colocated run has the authority and the load on one box, and subscribing to
      # its topic from each phase delivered every event twice -- a duplicate `ready` then ended the
      # measurement window at once.
      [authority | load_boxes] |> Enum.uniq() |> Enum.each(&subscribe_jobs/1)

      state =
        note(
          state,
          :placing,
          "placed: authority on #{authority}, load on #{Enum.join(load_boxes, ", ")}"
        )

      {:noreply, state, {:continue, :authority}}
    else
      {:error, reason} -> stop_failed(state, reason)
    end
  end

  @impl true
  def handle_continue(:authority, state) do
    state = phase(state, :authority)
    spec = state.spec

    case Box.launch(spec.authority_box, spec.caller, spec.project, spec.authority_mode,
           params: Map.delete(spec.params, "port"),
           duration_s: spec.measure_s + spec.finish_grace_s + 120,
           headless: true
         ) do
      {:ok, %{"id" => id} = reply} ->
        entry = %{box: spec.authority_box, id: id, ready: ready?(reply), exited: false}
        state = %{state | authority: entry}

        state =
          note(state, :authority, "authority launched on #{spec.authority_box} as job #{id}")

        await(state, :authority, [entry], :link)

      {:error, reason} ->
        stop_failed(state, "the authority would not start on #{spec.authority_box}: #{reason}")
    end
  end

  @impl true
  def handle_continue(:link, %{spec: %{link_mode: nil}} = state) do
    {:noreply, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:link, state) do
    state = phase(state, :link)
    spec = state.spec

    # The link runs on the authority's box and points at the authority's LAN address. Conditioning has
    # to sit between the two machines, not inside the control plane's path.
    with {:ok, authority_box} <- Fleet.fetch(spec.authority_box),
         {:ok, target} <- lan_target(authority_box),
         {:ok, %{"id" => id} = reply} <-
           Box.launch(spec.authority_box, spec.caller, spec.project, spec.link_mode,
             params: Map.merge(spec.params, %{"target" => target, "seed" => spec.seed}),
             duration_s: spec.measure_s + spec.finish_grace_s + 90,
             headless: true
           ) do
      entry = %{box: spec.authority_box, id: id, ready: ready?(reply), exited: false}
      state = %{state | link: entry}

      state =
        note(
          state,
          :link,
          "link launched on #{spec.authority_box} as job #{id}, conditioning #{target}"
        )

      await(state, :link, [entry], :load)
    else
      {:error, :not_connected} ->
        stop_failed(state, "#{spec.authority_box} is no longer connected")

      {:error, reason} ->
        stop_failed(state, "the link would not start: #{reason}")
    end
  end

  @impl true
  def handle_continue(:load, state) do
    state = phase(state, :load)
    spec = state.spec

    case join_address(state) do
      {:error, reason} ->
        stop_failed(state, reason)

      {:ok, join} ->
        launched =
          for box <- spec.load_boxes, index <- 1..spec.load_per_box//1 do
            launch_load(state, box, index, join)
          end

        case Enum.split_with(launched, &match?({:ok, _}, &1)) do
          {ok, []} ->
            entries = Enum.map(ok, &elem(&1, 1))
            state = %{state | load: entries}

            state =
              note(state, :load, "#{length(entries)} load client(s) launched, joining #{join}")

            await(state, :load, entries, :measure)

          {_ok, failed} ->
            # A fleet that came up short is not a smaller run: the verdict counts the load it EXPECTED,
            # so an unreachable box cannot shrink the fleet and still pass.
            reasons = failed |> Enum.map(fn {:error, r} -> r end) |> Enum.join("; ")

            stop_failed(
              state,
              "#{length(failed)} of #{length(launched)} load clients would not start: #{reasons}"
            )
        end
    end
  end

  # The window is over when every client has finished on its own. A client that has not finished by the
  # deadline is wedged, and the run says which rather than waiting on it.
  @impl true
  def handle_continue(:measure, state) do
    state = phase(state, :measuring)
    pending = state.load |> Enum.reject(& &1.exited) |> Enum.map(&{&1.box, &1.id}) |> MapSet.new()

    if MapSet.size(pending) == 0 do
      {:noreply, state, {:continue, :collect}}
    else
      deadline_ms = (state.spec.measure_s + state.spec.finish_grace_s) * 1_000
      state = start_wait(state, :measure, pending, :collect, deadline_ms)
      {:noreply, note(state, :measuring, "measuring for #{state.spec.measure_s}s")}
    end
  end

  @impl true
  def handle_continue(:collect, state) do
    state = phase(state, :collecting)
    spec = state.spec

    verdicts =
      Enum.map(state.load, fn entry ->
        case Box.verdict(entry.box, spec.caller, spec.project, entry.id) do
          {:ok, verdict} ->
            Map.merge(%{"box" => entry.box, "job" => entry.id}, stringify(verdict))

          {:error, reason} ->
            %{"box" => entry.box, "job" => entry.id, "verdict" => "unknown", "detail" => reason}
        end
      end)

    state = %{state | verdicts: verdicts}
    vacuous = Enum.filter(verdicts, &(to_string(&1["verdict"]) == "vacuous"))

    if vacuous == [] do
      measured = Enum.count(verdicts, &(to_string(&1["verdict"]) == "measured"))
      stop_done(note(state, :collecting, "#{measured} of #{length(verdicts)} client(s) measured"))
    else
      boxes = vacuous |> Enum.map(& &1["box"]) |> Enum.uniq() |> Enum.join(", ")
      stop_failed(state, "#{length(vacuous)} client(s) measured nothing (#{boxes})")
    end
  end

  # --- waiting on the fleet -------------------------------------------------------------------------

  # Wait for every entry to print its marker, then continue. An entry that already had when its launch
  # was acknowledged is not waited on. A mode that declares no marker is reported as launched and is
  # not waited on either -- a wait with nothing that could end it would be a sleep with a deadline.
  defp await(state, kind, entries, next) do
    pending =
      entries
      |> Enum.reject(&(&1.ready or marker_less?(state, &1)))
      |> Enum.map(&{&1.box, &1.id})
      |> MapSet.new()

    if MapSet.size(pending) == 0 do
      {:noreply, state, {:continue, next}}
    else
      {:noreply, start_wait(state, kind, pending, next, state.spec.bringup_timeout_ms)}
    end
  end

  defp start_wait(state, kind, pending, next, deadline_ms) do
    timer = Process.send_after(self(), {:deadline, kind}, deadline_ms)
    %{state | waiting: %{kind: kind, pending: pending, next: next}, timer: timer}
  end

  defp marker_less?(_state, _entry), do: false

  # A box carries other callers' jobs too, and every one of them announces itself on the same topic.
  # Only this run's jobs are its business; another run's authority exiting on a shared box is not this
  # run's failure.
  @impl true
  def handle_info({:job_event, box, id, event, detail}, state) do
    if mine?(state, box, id),
      do: job_event(state, box, id, event, detail),
      else: {:noreply, state}
  end

  @impl true
  def handle_info({:deadline, kind}, %{waiting: %{kind: kind, pending: pending}} = state) do
    names = pending |> Enum.map(fn {box, id} -> "#{box} job #{id}" end) |> Enum.join(", ")

    case kind do
      :measure ->
        stop_failed(state, "past the window and its grace, still running: #{names}")

      _ ->
        stop_failed(
          state,
          "no ready marker within #{div(state.spec.bringup_timeout_ms, 1000)}s from #{names}"
        )
    end
  end

  @impl true
  def handle_info({:deadline, _stale}, state), do: {:noreply, state}

  # A box leaving the fleet mid-run fails it NOW, naming the box. A script would wait out a timeout and
  # then report a marker that never arrived, which describes the symptom rather than the cause.
  @impl true
  def handle_info({:fleet, {:left, name}}, state) do
    if name in involved(state) and state.phase not in [:done, :failed] do
      stop_failed(state, "#{name} left the fleet during #{state.phase}")
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:fleet, _}, state), do: {:noreply, state}

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:stop, :normal, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:info, _from, state), do: {:reply, snapshot(state), state}

  # A ready marker ends a bringup wait and nothing else. It must not end the measurement window --
  # only a client exiting does that -- and it must not be noted twice.
  defp job_event(state, box, id, "ready", detail) do
    if job_ready?(state, box, id) do
      {:noreply, state}
    else
      state = mark(state, box, id, :ready, true)
      state = note(state, state.phase, "#{box} job #{id} ready#{ready_detail(detail)}")
      {:noreply, state} |> settle(:bringup, {box, id})
    end
  end

  defp job_event(state, box, id, "exited", detail) do
    state = mark(state, box, id, :exited, true)
    was_ready = Map.get(detail, "ready", false) or job_ready?(state, box, id)

    cond do
      state.waiting == nil ->
        {:noreply, state}

      # During bringup, exiting before the marker is the failure this whole design exists to name early.
      state.waiting.kind in [:authority, :link, :load] and not was_ready ->
        stop_failed(
          state,
          "#{box} job #{id} exited (#{inspect(detail["status"])}) before it was ready"
        )

      # During measurement, a client exiting is the normal end of its window.
      state.waiting.kind == :measure ->
        {:noreply, note(state, :measuring, "#{box} job #{id} finished")}
        |> settle(:measure, {box, id})

      # The authority or the link dying mid-run ends the run: every client is now measuring nothing.
      authority_or_link?(state, box, id) ->
        stop_failed(state, "#{box} job #{id} exited during #{state.phase}")

      true ->
        {:noreply, state}
    end
  end

  defp job_event(state, _box, _id, _other, _detail), do: {:noreply, state}

  defp mine?(state, box, id) do
    [state.authority, state.link | state.load]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&(&1.box == box and &1.id == id))
  end

  # Remove one job from the wait it can end; when nothing is pending, move on. A ready marker ends a
  # bringup wait; an exit ends the measurement wait; neither ends the other.
  defp settle({:noreply, %{waiting: nil} = state}, _class, _key), do: {:noreply, state}

  defp settle({:noreply, %{waiting: waiting} = state}, class, key) do
    if class_of(waiting.kind) == class do
      settle_pending(state, waiting, key)
    else
      {:noreply, state}
    end
  end

  defp class_of(:measure), do: :measure
  defp class_of(_bringup), do: :bringup

  defp settle_pending(state, waiting, key) do
    pending = MapSet.delete(waiting.pending, key)

    if MapSet.size(pending) == 0 do
      if state.timer, do: Process.cancel_timer(state.timer)
      {:noreply, %{state | waiting: nil, timer: nil}, {:continue, waiting.next}}
    else
      {:noreply, %{state | waiting: %{waiting | pending: pending}}}
    end
  end

  # --- ending ---------------------------------------------------------------------------------------

  defp stop_done(state) do
    state = %{state | phase: :done, finished_at: System.system_time(:millisecond)}
    state = note(state, :done, "done")
    Logger.info("run #{state.id} done")
    {:stop, :normal, state}
  end

  defp stop_failed(state, reason) do
    state = %{
      state
      | phase: :failed,
        failure: reason,
        finished_at: System.system_time(:millisecond)
    }

    state = note(state, :failed, reason)
    Logger.warning("run #{state.id} failed: #{reason}")
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Whatever ended this run, nothing it launched outlives it, and every box it held is released.
    if state.timer, do: Process.cancel_timer(state.timer)
    Enum.each(state.load, &stop_quietly(state, &1))
    if state.link, do: stop_quietly(state, state.link)
    if state.authority, do: stop_quietly(state, state.authority)
    Enum.each(state.leases, &release_quietly(state, &1))

    state =
      if state.phase in [:done, :failed],
        do: state,
        else: %{
          state
          | phase: :failed,
            failure: "aborted during #{state.phase}",
            finished_at: System.system_time(:millisecond)
        }

    publish(state)
    :ok
  end

  # --- placement ------------------------------------------------------------------------------------

  defp place(state) do
    spec = state.spec
    available = Fleet.capable(spec.project, spec.authority_mode)

    with {:ok, authority} <- pick_authority(spec, available),
         {:ok, load} <- pick_load(spec, authority) do
      {:ok, authority, load}
    end
  end

  defp pick_authority(%{authority_box: name}, _available) when is_binary(name), do: {:ok, name}

  defp pick_authority(spec, []),
    do: {:error, "no connected box can serve #{spec.project}/#{spec.authority_mode}"}

  defp pick_authority(_spec, [box | _]), do: {:ok, box.name}

  defp pick_load(spec, authority) do
    candidates =
      case Map.get(spec, :load_boxes) do
        names when is_list(names) and names != [] -> names
        _ -> spec.project |> Fleet.capable(spec.load_mode) |> Enum.map(& &1.name)
      end

    elsewhere = Enum.reject(candidates, &(&1 == authority))

    cond do
      elsewhere != [] ->
        {:ok, elsewhere}

      spec.allow_colocated and candidates != [] ->
        {:ok, candidates}

      candidates != [] ->
        # The refusal that is the whole point. Say it plainly rather than produce a number that
        # describes contention on one machine.
        {:error,
         "the only box that can serve #{spec.load_mode} is #{authority}, which is running the authority — " <>
           "load on the same machine measures the harness, not the netcode. Connect a second box, or pass allow_colocated."}

      true ->
        {:error, "no connected box can serve #{spec.project}/#{spec.load_mode}"}
    end
  end

  # Every box, before any launch. A run that claimed boxes as it went could hold the authority's box
  # and then find the load's taken, and stopping halfway leaves a server running for nobody.
  defp claim_leases(state, boxes) do
    ttl = (state.spec.measure_s + state.spec.finish_grace_s + 600) * 1_000

    Enum.reduce_while(boxes, {:ok, state}, fn box, {:ok, acc} ->
      case Box.lease(box, state.spec.caller, :claim, ttl_ms: ttl) do
        {:ok, _} -> {:cont, {:ok, %{acc | leases: [box | acc.leases]}}}
        {:error, reason} -> {:halt, {:error, "could not take #{box}: #{reason}"}}
      end
    end)
  end

  # --- helpers --------------------------------------------------------------------------------------

  defp launch_load(state, box, index, join) do
    spec = state.spec

    params =
      Map.merge(spec.params, %{
        "join" => join,
        "seed" => spec.seed + index,
        "duration" => spec.measure_s,
        "metrics" => "auto"
      })

    case Box.launch(box, spec.caller, spec.project, spec.load_mode,
           params: params,
           headless: true,
           duration_s: spec.measure_s + spec.finish_grace_s
         ) do
      {:ok, %{"id" => id} = reply} ->
        {:ok, %{box: box, id: id, ready: ready?(reply), exited: false}}

      {:error, reason} ->
        {:error, "#{box}: #{reason}"}
    end
  end

  defp ready?(%{"job" => %{"ready" => true}}), do: true
  defp ready?(%{"job" => %{ready: true}}), do: true
  defp ready?(_), do: false

  defp ready_detail(%{"ready_ms" => ms}) when is_integer(ms), do: " in #{ms} ms"
  defp ready_detail(_), do: ""

  defp mark(state, box, id, key, value) do
    update = fn
      %{box: ^box, id: ^id} = entry -> Map.put(entry, key, value)
      entry -> entry
    end

    %{
      state
      | authority: state.authority && update.(state.authority),
        link: state.link && update.(state.link),
        load: Enum.map(state.load, update)
    }
  end

  defp job_ready?(state, box, id) do
    [state.authority, state.link | state.load]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&(&1.box == box and &1.id == id and &1.ready))
  end

  defp authority_or_link?(state, box, id) do
    Enum.any?([state.authority, state.link], &(&1 != nil and &1.box == box and &1.id == id))
  end

  # Load joins the LINK when there is one, and the authority directly otherwise -- and always at a LAN
  # address, never whatever path the control plane took to reach the box.
  defp join_address(state) do
    spec = state.spec

    with {:ok, box} <- Fleet.fetch(spec.authority_box),
         {:ok, host} <- lan_host(box) do
      port = if state.link, do: relay_port(box), else: game_port(box)
      {:ok, "#{host}:#{port}"}
    else
      {:error, :not_connected} -> {:error, "#{spec.authority_box} is no longer connected"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lan_target(box) do
    with {:ok, host} <- lan_host(box), do: {:ok, "#{host}:#{game_port(box)}"}
  end

  defp lan_host(%{lan: lan}) when is_binary(lan) and lan != "", do: {:ok, lan}

  defp lan_host(box),
    do:
      {:error,
       "#{box.name} reports no LAN address, and a session routed through the control plane's path measures that path"}

  # A box declares the port band it binds. Guessing here would place load on a port it does not listen
  # on, and the failure would read as a netcode problem rather than a configuration one.
  defp game_port(box), do: Map.get(box.report || %{}, "game_port") || 47_900
  defp relay_port(box), do: Map.get(box.report || %{}, "relay_port") || 47_910

  defp subscribe_jobs(box), do: Phoenix.PubSub.subscribe(Orbitorc.PubSub, "box:#{box}:jobs")

  defp involved(state) do
    [state.authority, state.link | state.load]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.box)
    |> Kernel.++(state.leases)
    |> Enum.uniq()
  end

  defp stop_quietly(state, %{box: box, id: id, exited: exited}) do
    unless exited, do: Box.stop(box, state.spec.caller, id: id)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp release_quietly(state, box) do
    Box.lease(box, state.spec.caller, :release)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp phase(state, phase) do
    state = %{state | phase: phase}
    note(state, phase, Atom.to_string(phase))
  end

  # Every transition is recorded with a time and published three ways: the registry value a dashboard
  # reads without calling this process, the run's PubSub topic, and the run history when there is one.
  defp note(state, phase, line) do
    entry = %{
      "at" => System.system_time(:millisecond) - state.started_at,
      "phase" => Atom.to_string(phase),
      "line" => line
    }

    state = %{state | timeline: state.timeline ++ [entry]}
    publish(state)
    state
  end

  defp publish(state) do
    snap = snapshot(state)
    update_registry(state.id, snap)
    Phoenix.PubSub.broadcast(Orbitorc.PubSub, topic(state.id), {:run, state.id, snap})
    Phoenix.PubSub.broadcast(Orbitorc.PubSub, "runs", {:run, state.id, snap})
    Runs.record(snap)
  end

  defp register(state) do
    if Process.whereis(Orbitorc.RunRegistry),
      do: Registry.register(Orbitorc.RunRegistry, state.id, snapshot(state))

    :ok
  end

  defp update_registry(id, snap) do
    if Process.whereis(Orbitorc.RunRegistry),
      do: Registry.update_value(Orbitorc.RunRegistry, id, fn _ -> snap end)

    :ok
  end

  defp snapshot(state) do
    %{
      id: state.id,
      phase: state.phase,
      project: state.spec.project,
      caller: state.spec.caller,
      spec: state.spec |> Map.drop([:id]) |> stringify(),
      authority: state.authority,
      link: state.link,
      load: state.load,
      failure: state.failure,
      verdicts: state.verdicts,
      timeline: state.timeline,
      started_at: state.started_at,
      finished_at: state.finished_at,
      elapsed_ms: (state.finished_at || System.system_time(:millisecond)) - state.started_at
    }
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
