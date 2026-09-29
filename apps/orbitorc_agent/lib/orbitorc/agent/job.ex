defmodule Orbitorc.Agent.Job do
  @moduledoc """
  One launched process, owned by a supervised Elixir process.

  ## Supervision is teardown

  The worst failure in a harness like this is an orphan: a process that outlives the run, keeps a UDP
  port bound, and poisons the next run in a way that reads as a netcode bug rather than a teardown bug.

  Every launched process has an owner here, and the owner's `terminate/2` kills it — so a job dies when
  it is stopped, when its supervisor restarts, and when the agent itself goes down. Nothing has to
  remember to clean up, because nothing is responsible for remembering.

  **Closing a port does not kill its child.** The BEAM closes the pipes and waits. So the OS pid is
  recorded at launch and killed explicitly, and the tree with it.

  ## Launch the raw engine binary

  A wrapper script that runs the engine inside a process substitution orphans it when the wrapper is
  killed. Launching through a port with an argv list has no shell in it at all: no quoting to get wrong,
  no wrapper to orphan, and the pid the agent holds is the engine's own.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Orbitorc.Agent.{LogTail, Platform}

  @type option ::
          {:id, pos_integer()}
          | {:argv, [String.t()]}
          | {:dir, Path.t()}
          | {:env, %{String.t() => String.t()}}
          | {:marker, String.t() | nil}
          | {:project, String.t()}
          | {:mode, String.t()}
          | {:caller, String.t()}
          | {:deadline_ms, pos_integer() | nil}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "A snapshot a caller can render."
  def info(pid), do: GenServer.call(pid, :info)

  @doc "The job's log, most recent `limit` lines, optionally filtered."
  def logs(pid, limit \\ 100, pattern \\ nil), do: GenServer.call(pid, {:logs, limit, pattern})

  @doc "Stop the job. The process dies and takes its OS process with it."
  def stop(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 runs on a supervisor shutdown. Without it a stopping agent leaks every
    # job it owns, which is the single failure this module exists to prevent.
    Process.flag(:trap_exit, true)

    dir = Keyword.fetch!(opts, :dir)
    File.mkdir_p!(dir)
    log_path = Path.join(dir, "job.log")

    # ARGV IS BUILT HERE, NOT BY THE CALLER. Every job writes a log file and some write artifacts, and
    # both live in a directory that does not exist until this process makes it — so a caller building
    # argv would have to invent those paths or be told them by a directory it does not own. The caller
    # passes a function of `(dir, log_path)` instead, and the one process that knows where a job's
    # files go is the one that names them.
    with {:ok, argv} <- build(opts, dir, log_path),
         {:ok, executable} <- resolve(hd(argv)),
         {:ok, tail} <-
           LogTail.start_link(
             path: log_path,
             owner: self(),
             marker: Keyword.get(opts, :marker),
             job_id: Keyword.fetch!(opts, :id)
           ) do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :hide,
          args: tl(argv),
          cd: dir,
          env: env_for(Keyword.get(opts, :env, %{}))
        ])

      os_pid = port |> Port.info(:os_pid) |> elem(1)

      state = %{
        id: Keyword.fetch!(opts, :id),
        project: Keyword.get(opts, :project),
        mode: Keyword.get(opts, :mode),
        caller: Keyword.get(opts, :caller),
        argv: argv,
        dir: dir,
        log_path: log_path,
        port: port,
        os_pid: os_pid,
        tail: tail,
        marker: Keyword.get(opts, :marker),
        ready_at: nil,
        started_at: System.system_time(:millisecond),
        exit_status: nil,
        stdout: []
      }

      write_meta(state)
      maybe_deadline(Keyword.get(opts, :deadline_ms))
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp build(opts, dir, log_path) do
    case Keyword.fetch!(opts, :argv_builder).(dir, log_path) do
      {:ok, [_ | _] = argv} -> {:ok, argv}
      {:ok, _} -> {:error, "the command line came back empty"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve(bin) do
    cond do
      File.exists?(bin) -> {:ok, Path.expand(bin)}
      path = System.find_executable(bin) -> {:ok, path}
      true -> {:error, "#{bin} is neither a file nor on PATH"}
    end
  end

  defp env_for(env) do
    Enum.map(env, fn {k, v} ->
      {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end

  defp maybe_deadline(nil), do: :ok

  # A wall-clock backstop, generous on purpose. Reaping a healthy run early destroys the measurement the
  # run existed to take; reaping a wedged one late costs only time on the box.
  defp maybe_deadline(ms), do: Process.send_after(self(), :deadline, ms)

  @doc """
  The topic every job on this box announces itself on.

  Two events, both of which a run on the control plane acts on: `ready`, when the mode's marker
  appears in the log, and `exited`, with the status. A job that exits before it is ready is a failed
  bringup, and the run learns that from the event rather than from a timeout that names the symptom.
  """
  def topic, do: "jobs"

  @impl true
  def handle_call(:info, _from, state), do: {:reply, snapshot(state), state}

  @impl true
  def handle_call({:logs, limit, pattern}, _from, state) do
    {:reply, LogTail.tail(state.tail, limit, pattern), state}
  end

  @impl true
  def handle_info({:marker, line}, state) do
    state = %{state | ready_at: System.system_time(:millisecond)}
    Logger.info("job #{state.id} ready: #{line}")
    write_meta(state)
    announce(state, "ready", %{"ready_ms" => state.ready_at - state.started_at, "line" => line})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # A job's own log file is the record. Stdout is kept only as a bounded tail, because a crash before
    # the engine opens its log file prints there and nowhere else.
    {:noreply, %{state | stdout: Enum.take([data | state.stdout], 50)}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("job #{state.id} exited #{status}")

    # Read the last of the log before saying anything: a process that printed its marker and exited
    # at once was ready, and must not be reported as having died before it was.
    ready = LogTail.sync(state.tail) or state.ready_at != nil
    state = %{state | exit_status: status, port: nil}

    state =
      if ready and state.ready_at == nil,
        do: %{state | ready_at: System.system_time(:millisecond)},
        else: state

    write_meta(state)
    announce(state, "exited", %{"status" => status, "ready" => ready})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:deadline, state) do
    Logger.warning("job #{state.id} passed its deadline; reaping")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:EXIT, _from, _reason}, state), do: {:stop, :normal, state}

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # The whole point of this module. Kill the OS process, then close the port -- in that order, because
    # closing first loses the pid.
    if state.os_pid, do: Platform.kill_tree(state.os_pid)
    if state.port, do: safe_close(state.port)
    state = %{state | exit_status: state.exit_status || :reaped}
    write_meta(state)
    # A job that was reaped never sent its own exit; say so now, so nothing waits on it.
    if state.exit_status == :reaped,
      do: announce(state, "exited", %{"status" => "reaped", "ready" => state.ready_at != nil})

    :ok
  end

  defp announce(state, event, detail) do
    Phoenix.PubSub.broadcast(Orbitorc.PubSub, topic(), {:job_event, state.id, event, detail})
  end

  defp safe_close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  defp snapshot(state) do
    %{
      id: state.id,
      project: state.project,
      mode: state.mode,
      caller: state.caller,
      argv: state.argv,
      dir: state.dir,
      os_pid: state.os_pid,
      marker: state.marker,
      ready: state.ready_at != nil,
      ready_ms: state.ready_at && state.ready_at - state.started_at,
      started_at: state.started_at,
      exit_status: state.exit_status,
      stdout: state.stdout |> Enum.reverse() |> Enum.join(),
      alive: state.exit_status == nil
    }
  end

  # A job directory that records its own argv is the difference between reading a result and guessing
  # what produced it.
  defp write_meta(state) do
    File.write(
      Path.join(state.dir, "job.json"),
      Jason.encode_to_iodata!(snapshot(state), pretty: true)
    )
  end
end
