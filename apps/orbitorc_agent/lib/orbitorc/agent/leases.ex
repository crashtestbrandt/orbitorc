defmodule Orbitorc.Agent.Leases do
  @moduledoc """
  The box's single lease, held in a process.

  `Orbitorc.Lease` is the rule; this is where it lives. A lease dies on its TTL and on agent restart,
  and there is nothing here that breaks one early — the state is simply gone when the process is.
  """

  use GenServer

  alias Orbitorc.Lease

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Take the lease, or learn who has it."
  def claim(caller, opts \\ []), do: GenServer.call(__MODULE__, {:claim, caller, opts})

  @doc "Push the expiry out. Only the holder may."
  def renew(caller, opts \\ []), do: GenServer.call(__MODULE__, {:renew, caller, opts})

  @doc "Give it up early. Only the holder may."
  def release(caller), do: GenServer.call(__MODULE__, {:release, caller})

  @doc "Who holds it, if anyone."
  def holder, do: GenServer.call(__MODULE__, :holder)

  @doc """
  Whether `caller` may run a verb of this kind.

  A read verb never needs a lease, so watching is always allowed — which is what makes waiting for a
  contended box tolerable.
  """
  @spec authorize(String.t(), :read | :mutate) :: :ok | {:error, term()}
  def authorize(caller, kind), do: GenServer.call(__MODULE__, {:authorize, caller, kind})

  @impl true
  def init(_opts), do: {:ok, Lease.new()}

  @impl true
  def handle_call({:claim, caller, opts}, _from, lease) do
    case Lease.claim(lease, caller, now(), opts) do
      {:ok, lease, ttl} -> {:reply, {:ok, ttl}, lease}
      {:error, _} = err -> {:reply, err, lease}
    end
  end

  @impl true
  def handle_call({:renew, caller, opts}, _from, lease) do
    case Lease.renew(lease, caller, now(), opts) do
      {:ok, lease, ttl} -> {:reply, {:ok, ttl}, lease}
      {:error, _} = err -> {:reply, err, lease}
    end
  end

  @impl true
  def handle_call({:release, caller}, _from, lease) do
    case Lease.release(lease, caller, now()) do
      {:ok, freed} -> {:reply, :ok, freed}
      {:error, _} = err -> {:reply, err, lease}
    end
  end

  @impl true
  def handle_call(:holder, _from, lease), do: {:reply, Lease.holder(lease, now()), lease}

  @impl true
  def handle_call({:authorize, caller, kind}, _from, lease) do
    {:reply, Lease.authorize(lease, caller, kind, now()), lease}
  end

  defp now, do: System.system_time(:millisecond)
end
