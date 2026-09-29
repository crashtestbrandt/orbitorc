defmodule Orbitorc.Agent.Jobs do
  @moduledoc """
  Every job this box is running, and every directory one has left behind.

  ## A job id names a directory, so reusing one merges two jobs

  Ids never repeat for the life of a box, and the next id is chosen by looking at what is already on
  disk rather than by counting in memory — an agent restart must not hand out an id whose directory
  another job's artifacts are already in.

  ## Retention is deletion, and it happens at startup

  Ids never repeat, so job directories would otherwise grow for the life of the box. The lowest ids are
  removed at startup and the agent says what it removed. Pulling a result is how it leaves.
  """

  use GenServer
  require Logger

  alias Orbitorc.Agent.Job

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Launch a job. Answers its id."
  @spec launch(keyword()) :: {:ok, pos_integer(), map()} | {:error, term()}
  def launch(opts), do: GenServer.call(__MODULE__, {:launch, opts}, 30_000)

  @doc "Every live job, oldest first."
  def list, do: GenServer.call(__MODULE__, :list)

  @doc """
  One job's snapshot, live or finished.

  **A finished job is still a job.** A bench client self-terminates when its window closes, and its
  metrics are read after that — so a registry that only knew live processes would lose every result at
  the moment it became worth reading. A job writes its own `job.json` as it goes; once the process is
  gone, that file is the record.
  """
  def info(id) do
    case whereis(id) do
      {:ok, pid} -> live_or_disk(id, fn -> Job.info(pid) end)
      {:error, _} -> from_disk(id)
    end
  end

  # A job announces its exit and then stops. A caller that reacts to the announcement -- a run asking
  # for the verdict the moment its client finishes -- can reach the process while it is still stopping,
  # and a call into a stopping process exits. The record on disk was written before the announcement,
  # so it is the answer in exactly that window.
  defp live_or_disk(id, call) do
    {:ok, call.()}
  catch
    :exit, _ -> from_disk(id)
  end

  @doc "One job's log, live from the tail or read back from the file once the job has gone."
  def logs(id, limit \\ 100, pattern \\ nil) do
    case whereis(id) do
      {:ok, pid} ->
        case live_or_disk(id, fn -> Job.logs(pid, limit, pattern) end) do
          {:ok, lines} when is_list(lines) -> {:ok, lines}
          {:ok, _job} -> logs_from_disk(id, limit, pattern)
          error -> error
        end

      {:error, _} ->
        logs_from_disk(id, limit, pattern)
    end
  end

  defp logs_from_disk(id, limit, pattern) do
    with {:ok, job} <- from_disk(id) do
      lines =
        case File.read(Path.join(job.dir, "job.log")) do
          {:ok, body} -> body |> String.split(["\r\n", "\n"]) |> Enum.reject(&(&1 == ""))
          _ -> []
        end

      lines = if pattern, do: Enum.filter(lines, &Regex.match?(pattern, &1)), else: lines
      {:ok, Enum.take(lines, -limit)}
    end
  end

  @doc "Whether the job's process is still running."
  def alive?(id), do: match?({:ok, _}, whereis(id))

  # The keys a job records about itself, read back with the same names the live snapshot uses.
  @recorded ~w(id project mode caller argv dir os_pid marker ready ready_ms started_at exit_status stdout)a

  defp from_disk(id) when is_integer(id) do
    path = Path.join([dir(id), "job.json"])

    with {:ok, body} <- File.read(path),
         {:ok, raw} <- Jason.decode(body) do
      job =
        @recorded
        |> Map.new(fn key -> {key, Map.get(raw, Atom.to_string(key))} end)
        |> Map.put(:alive, false)

      {:ok, job}
    else
      _ -> {:error, :no_such_job}
    end
  end

  defp from_disk(_), do: {:error, :no_such_job}

  @doc "Stop one job."
  def stop(id) do
    with {:ok, pid} <- whereis(id) do
      Job.stop(pid)
      :ok
    end
  end

  @doc """
  Stop every job this caller started.

  A caller reaps its OWN jobs by default. Another caller's measurement is not litter, and a sweep that
  took everything would be the same mistake as breaking a lease.
  """
  def stop_all(caller, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    list()
    |> Enum.filter(fn job -> force or job.caller == caller end)
    |> Enum.map(fn job -> stop(job.id) && job.id end)
    |> Enum.reject(&(&1 == nil))
  end

  @doc "Where a job's artifacts are."
  def dir(id), do: GenServer.call(__MODULE__, {:dir, id})

  @doc "The topic every job on this box announces itself on. See `Orbitorc.Agent.Job.topic/0`."
  def topic, do: Job.topic()

  @doc "The root every job directory lives under."
  def root, do: GenServer.call(__MODULE__, :root)

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)
    File.mkdir_p!(root)
    removed = prune(root, Keyword.get(opts, :retention, 200))

    if removed != [],
      do: Logger.info("pruned #{length(removed)} job directories: #{Enum.join(removed, ", ")}")

    {:ok, %{root: root, next: next_id(root), jobs: %{}}}
  end

  @impl true
  def handle_call({:launch, opts}, _from, state) do
    id = state.next
    dir = Path.join(state.root, Integer.to_string(id))

    spec = {Job, Keyword.merge(opts, id: id, dir: dir)}

    case DynamicSupervisor.start_child(Orbitorc.Agent.JobSupervisor, spec) do
      {:ok, pid} ->
        Process.monitor(pid)
        state = %{state | next: id + 1, jobs: Map.put(state.jobs, id, pid)}
        {:reply, {:ok, id, Job.info(pid)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | next: id + 1}}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    jobs =
      state.jobs
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {_id, pid} ->
        if Process.alive?(pid), do: [Job.info(pid)], else: []
      end)

    {:reply, jobs, state}
  end

  @impl true
  def handle_call({:whereis, id}, _from, state) do
    case Map.fetch(state.jobs, id) do
      {:ok, pid} ->
        if Process.alive?(pid),
          do: {:reply, {:ok, pid}, state},
          else: {:reply, {:error, :gone}, state}

      :error ->
        {:reply, {:error, :no_such_job}, state}
    end
  end

  @impl true
  def handle_call({:dir, id}, _from, state),
    do: {:reply, Path.join(state.root, Integer.to_string(id)), state}

  @impl true
  def handle_call(:root, _from, state), do: {:reply, state.root, state}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | jobs: state.jobs |> Enum.reject(fn {_, p} -> p == pid end) |> Map.new()}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp whereis(id), do: GenServer.call(__MODULE__, {:whereis, id})

  # The next id is read off the disk, not counted in memory: an agent restart must not hand out an id
  # whose directory another job's artifacts already occupy.
  defp next_id(root) do
    root
    |> existing_ids()
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp existing_ids(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          case Integer.parse(entry) do
            {id, ""} -> [id]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp prune(root, keep) do
    ids = root |> existing_ids() |> Enum.sort()

    ids
    |> Enum.take(max(length(ids) - keep, 0))
    |> Enum.map(fn id ->
      File.rm_rf!(Path.join(root, Integer.to_string(id)))
      Integer.to_string(id)
    end)
  end
end
