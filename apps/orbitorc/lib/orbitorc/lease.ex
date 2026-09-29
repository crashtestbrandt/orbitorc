defmodule Orbitorc.Lease do
  @moduledoc """
  Who is driving a box right now.

  A box is reachable by more than one caller — that is the point. Three mechanisms keep it from turning
  into callers stepping on each other.

  **Named tokens.** An agent holds a list of `{name, token}` rather than one shared secret, so every
  action is attributable and one caller can be revoked without rotating everybody else's credential.

  **Leases, the arbiter.** Mutating verbs (sync, build, launch, stop) require a live lease; read verbs
  (health, status, logs, file) never do. The failure this prevents is specific and quiet: caller A runs
  a sync — a force checkout and hard reset — while caller B has a server mid-measurement on the old
  tree. B's run does not crash. It produces numbers for a commit it is no longer running. Read verbs
  stay open precisely so a caller who cannot take the lease can still watch, which is what makes
  waiting tolerable.

  **No stealing and no override.** A lease expires on its TTL and on agent restart, and nothing breaks
  one early. A force-break verb would be used by whichever caller was most confident, which is not the
  same as whichever caller was right.

  This module is the pure state machine: every function takes the current time, so the tests need no
  clock and no sleeping. `Orbitorc.Agent.Leases` wraps it in a process.
  """

  @default_ttl_ms 900_000
  @max_ttl_ms 7_200_000

  @type t :: %__MODULE__{holder: String.t() | nil, expires_at: integer() | nil}

  defstruct holder: nil, expires_at: nil

  @doc "A lease nobody renews dies on its own. Long enough for a build plus a measurement window, short enough that a caller which vanished mid-run does not hold the box for an afternoon."
  def default_ttl_ms, do: @default_ttl_ms
  def max_ttl_ms, do: @max_ttl_ms

  @doc "A box nobody is driving."
  def new, do: %__MODULE__{}

  @doc "Who holds it, if anyone, at `now`."
  @spec holder(t(), integer()) :: {:ok, String.t(), non_neg_integer()} | :free
  def holder(%__MODULE__{holder: nil}, _now), do: :free

  def holder(%__MODULE__{holder: name, expires_at: expires_at}, now) do
    if expires_at > now, do: {:ok, name, expires_at - now}, else: :free
  end

  @doc """
  Take the lease for `caller`, or say who has it.

  Re-claiming your own live lease renews it rather than being refused, so a caller that lost track of
  its own TTL is not locked out of a box it already owns.
  """
  @spec claim(t(), String.t(), integer(), keyword()) ::
          {:ok, t(), non_neg_integer()} | {:error, {:contended, String.t(), non_neg_integer()}}
  def claim(%__MODULE__{} = lease, caller, now, opts \\ []) do
    ttl = opts |> Keyword.get(:ttl_ms, @default_ttl_ms) |> clamp_ttl()

    case holder(lease, now) do
      :free -> {:ok, %__MODULE__{holder: caller, expires_at: now + ttl}, ttl}
      {:ok, ^caller, _} -> {:ok, %__MODULE__{holder: caller, expires_at: now + ttl}, ttl}
      {:ok, other, remaining} -> {:error, {:contended, other, remaining}}
    end
  end

  @doc "Push the expiry out. Only the holder may; a lapsed lease cannot be renewed, only re-claimed."
  @spec renew(t(), String.t(), integer(), keyword()) ::
          {:ok, t(), non_neg_integer()} | {:error, :not_holder}
  def renew(%__MODULE__{} = lease, caller, now, opts \\ []) do
    ttl = opts |> Keyword.get(:ttl_ms, @default_ttl_ms) |> clamp_ttl()

    case holder(lease, now) do
      {:ok, ^caller, _} -> {:ok, %__MODULE__{holder: caller, expires_at: now + ttl}, ttl}
      _ -> {:error, :not_holder}
    end
  end

  @doc "Give it up early. Only the holder may."
  @spec release(t(), String.t(), integer()) :: {:ok, t()} | {:error, :not_holder}
  def release(%__MODULE__{} = lease, caller, now) do
    case holder(lease, now) do
      {:ok, ^caller, _} -> {:ok, new()}
      _ -> {:error, :not_holder}
    end
  end

  @doc """
  Whether `caller` may run a verb of this kind.

  A read verb never needs a lease. A mutating verb needs a live one held by this caller.
  """
  @spec authorize(t(), String.t(), :read | :mutate, integer()) ::
          :ok | {:error, :needs_lease} | {:error, {:contended, String.t(), non_neg_integer()}}
  def authorize(_lease, _caller, :read, _now), do: :ok

  def authorize(%__MODULE__{} = lease, caller, :mutate, now) do
    case holder(lease, now) do
      :free -> {:error, :needs_lease}
      {:ok, ^caller, _} -> :ok
      {:ok, other, remaining} -> {:error, {:contended, other, remaining}}
    end
  end

  defp clamp_ttl(ttl) when is_integer(ttl) and ttl > 0, do: min(ttl, @max_ttl_ms)
  defp clamp_ttl(_), do: @default_ttl_ms
end
