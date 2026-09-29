defmodule Orbitorc.Request do
  @moduledoc """
  Asking a box something and waiting for its answer.

  A box is asked over a socket and answers whenever it can. A launch takes seconds; a doctor takes less.
  Neither may block the socket, so requests are asynchronous and this is what holds the waiting caller.

  ## Every wait ends

  A request ends one of three ways, and all three are handled rather than two:

  | | |
  | --- | --- |
  | The box answers | The reply resolves the ref. |
  | The box disconnects | `fail_box/2` resolves every outstanding ref for that box. **A caller must not wait on a machine that has gone.** |
  | Neither happens | The timeout fires. A box that accepted a request and never answered is a bug, and a caller hanging on it forever turns that bug into a hung fleet. |

  The table is keyed by ref and holds the caller's `from`, so a reply arriving after its timeout is
  dropped rather than delivered to whatever now occupies that mailbox.
  """

  use GenServer

  require Logger

  @default_timeout_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Register a pending request and answer its ref.

  The caller pushes the ref to the box itself; this only remembers who is waiting.
  """
  @spec open(String.t(), timeout()) :: {:ok, String.t()}
  def open(box, timeout_ms \\ @default_timeout_ms) do
    GenServer.call(__MODULE__, {:open, box, timeout_ms})
  end

  @doc "Block until the box answers, it disconnects, or the request times out."
  @spec await(String.t(), timeout()) :: {:ok, term()} | {:error, term()}
  def await(ref, timeout_ms \\ @default_timeout_ms) do
    receive do
      {:orbitorc_reply, ^ref, result} -> result
    after
      timeout_ms + 1_000 -> {:error, "the box did not answer in #{div(timeout_ms, 1000)}s"}
    end
  end

  @doc "A box answered. Dropped silently if nobody is waiting any more."
  @spec resolve(String.t(), term()) :: :ok
  def resolve(ref, result), do: GenServer.cast(__MODULE__, {:resolve, ref, result})

  @doc "A box disconnected. Every caller waiting on it is told, rather than left to time out."
  @spec fail_box(String.t(), term()) :: :ok
  def fail_box(box, reason), do: GenServer.cast(__MODULE__, {:fail_box, box, reason})

  @impl true
  def init(_opts), do: {:ok, %{pending: %{}}}

  @impl true
  def handle_call({:open, box, timeout_ms}, {pid, _tag}, state) do
    ref = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    timer = Process.send_after(self(), {:timeout, ref}, timeout_ms)
    {:reply, {:ok, ref}, put_in(state.pending[ref], %{box: box, waiter: pid, timer: timer})}
  end

  @impl true
  def handle_cast({:resolve, ref, result}, state), do: {:noreply, deliver(state, ref, result)}

  @impl true
  def handle_cast({:fail_box, box, reason}, state) do
    state =
      state.pending
      |> Enum.filter(fn {_ref, entry} -> entry.box == box end)
      |> Enum.reduce(state, fn {ref, _}, acc ->
        deliver(acc, ref, {:error, "#{box} disconnected (#{inspect(reason)})"})
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:timeout, ref}, state) do
    {:noreply, deliver(state, ref, {:error, "the box accepted the request and did not answer"})}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp deliver(state, ref, result) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        # A reply that arrived after its timeout. Dropping it is deliberate: the waiter has moved on and
        # delivering it would put a stale answer in whatever now owns that mailbox.
        state

      {entry, pending} ->
        Process.cancel_timer(entry.timer)
        send(entry.waiter, {:orbitorc_reply, ref, result})
        %{state | pending: pending}
    end
  end
end
