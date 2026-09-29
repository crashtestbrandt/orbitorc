defmodule Orbitorc.Agent.LogTail do
  @moduledoc """
  Following a job's log file and turning it into messages.

  ## Why the file and not stdout

  A GUI-subsystem binary on Windows never attaches stdout, so a job's output reaches nobody through the
  pipe on exactly the platform a remote fleet exists to reach. Every job is given the engine's own log
  flag instead, and this follows the file it writes. One source, every platform, no branch.

  ## Readiness is a marker, never a sleep

  The owner registers the line that proves its mode came up and is sent `{:marker, line}` when it
  appears. A fixed sleep is either too short on a cold cache or wasted on a warm one, and it cannot tell
  "slow" from "failed" — so nothing here waits a fixed time for anything.

  The file is polled rather than watched. There is no portable file-watch across the three platforms,
  and a poll interval well under a human's patience is the whole requirement.
  """

  use GenServer
  require Logger

  @poll_ms 100

  @type option ::
          {:path, Path.t()}
          | {:owner, pid()}
          | {:marker, String.t() | nil}
          | {:job_id, pos_integer() | nil}
          | {:poll_ms, pos_integer()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Every line seen so far, oldest first, at most `limit`, optionally matching `pattern`."
  @spec tail(pid(), pos_integer(), Regex.t() | nil) :: [String.t()]
  def tail(pid, limit \\ 100, pattern \\ nil), do: GenServer.call(pid, {:tail, limit, pattern})

  @doc "Whether the marker has been seen."
  @spec ready?(pid()) :: boolean()
  def ready?(pid), do: GenServer.call(pid, :ready?)

  @doc """
  Read whatever the file holds right now, and answer whether the marker has been seen.

  A job that prints its marker and exits within a millisecond — a smoke does exactly that — can be
  gone before the first poll. Its owner calls this on exit, so the last lines a process wrote are read
  before its exit is announced, and "exited before it was ready" is only ever said of a job that was.
  """
  @spec sync(pid()) :: boolean()
  def sync(pid), do: GenServer.call(pid, :sync)

  @impl true
  def init(opts) do
    state = %{
      path: Keyword.fetch!(opts, :path),
      owner: Keyword.get(opts, :owner),
      marker: Keyword.get(opts, :marker),
      job_id: Keyword.get(opts, :job_id),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      # Keep the tail bounded. A long run writes far more than anybody reads, and holding all of it in
      # a process heap is how an agent dies of a job that went well.
      lines: :queue.new(),
      count: 0,
      max_lines: Keyword.get(opts, :max_lines, 2_000),
      offset: 0,
      partial: "",
      ready: false
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:tail, limit, pattern}, _from, state) do
    lines =
      state.lines
      |> :queue.to_list()
      |> then(fn all ->
        if pattern, do: Enum.filter(all, &Regex.match?(pattern, &1)), else: all
      end)
      |> Enum.take(-limit)

    {:reply, lines, state}
  end

  @impl true
  def handle_call(:ready?, _from, state), do: {:reply, state.ready, state}

  @impl true
  def handle_call(:sync, _from, state) do
    state = read_new(state)
    {:reply, state.ready, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = read_new(state)
    schedule(state)
    {:noreply, state}
  end

  defp schedule(state), do: Process.send_after(self(), :poll, state.poll_ms)

  defp read_new(state) do
    case File.open(state.path, [:read, :binary]) do
      {:ok, file} ->
        {:ok, _} = :file.position(file, state.offset)
        chunk = read_all(file, [])
        :file.close(file)
        consume(state, chunk)

      {:error, _} ->
        # The engine has not created it yet. Not an error: a job is launched, then writes.
        state
    end
  end

  defp read_all(file, acc) do
    case IO.binread(file, 65_536) do
      :eof -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      {:error, _} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      data -> read_all(file, [data | acc])
    end
  end

  defp consume(state, ""), do: state

  defp consume(state, chunk) do
    state = %{state | offset: state.offset + byte_size(chunk)}
    buffer = state.partial <> chunk
    parts = String.split(buffer, ["\r\n", "\n"])
    {lines, [partial]} = Enum.split(parts, length(parts) - 1)

    Enum.reduce(lines, %{state | partial: partial}, &absorb(&2, &1))
  end

  defp absorb(state, line) do
    state = push(state, line)

    # Every line is also a message on the box's shared job topic. The link forwards it to the control
    # plane, so a dashboard and a run see the same stream this process matches the marker against.
    if state.job_id,
      do: Phoenix.PubSub.broadcast(Orbitorc.PubSub, "jobs", {:job_log, state.job_id, line})

    if (not state.ready and state.marker) && String.contains?(line, state.marker) do
      if state.owner, do: send(state.owner, {:marker, line})
      %{state | ready: true}
    else
      state
    end
  end

  defp push(state, line) do
    queue = :queue.in(line, state.lines)

    if state.count >= state.max_lines do
      {_, trimmed} = :queue.out(queue)
      %{state | lines: trimmed}
    else
      %{state | lines: queue, count: state.count + 1}
    end
  end
end
