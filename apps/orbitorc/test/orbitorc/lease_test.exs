defmodule Orbitorc.LeaseTest do
  @moduledoc """
  Every function takes the current time, so these tests need no clock and no sleeping.
  """
  use ExUnit.Case, async: true
  alias Orbitorc.Lease

  @t0 1_000_000

  test "a fresh box is nobody's" do
    assert Lease.holder(Lease.new(), @t0) == :free
  end

  test "a claim on a free box succeeds and reports the ttl" do
    assert {:ok, lease, ttl} = Lease.claim(Lease.new(), "alice", @t0)
    assert ttl == Lease.default_ttl_ms()
    assert {:ok, "alice", _} = Lease.holder(lease, @t0)
  end

  test "a second caller is refused, and told who has it and for how long" do
    {:ok, lease, _} = Lease.claim(Lease.new(), "alice", @t0, ttl_ms: 60_000)
    assert {:error, {:contended, "alice", remaining}} = Lease.claim(lease, "bob", @t0 + 10_000)
    assert remaining == 50_000
  end

  test "re-claiming your own live lease renews it rather than being refused" do
    # A caller that lost track of its own TTL is not locked out of a box it already owns.
    {:ok, lease, _} = Lease.claim(Lease.new(), "alice", @t0, ttl_ms: 60_000)
    assert {:ok, lease, _} = Lease.claim(lease, "alice", @t0 + 10_000, ttl_ms: 60_000)
    assert {:ok, "alice", 60_000} = Lease.holder(lease, @t0 + 10_000)
  end

  test "a lease nobody renews dies on its own" do
    {:ok, lease, _} = Lease.claim(Lease.new(), "alice", @t0, ttl_ms: 60_000)
    assert Lease.holder(lease, @t0 + 60_001) == :free
    assert {:ok, _, _} = Lease.claim(lease, "bob", @t0 + 60_001)
  end

  test "a ttl beyond the maximum is clamped rather than honored" do
    {:ok, _lease, ttl} = Lease.claim(Lease.new(), "alice", @t0, ttl_ms: 99_999_999)
    assert ttl == Lease.max_ttl_ms()
  end

  test "only the holder may renew, and a lapsed lease cannot be" do
    {:ok, lease, _} = Lease.claim(Lease.new(), "alice", @t0, ttl_ms: 60_000)
    assert {:error, :not_holder} = Lease.renew(lease, "bob", @t0)
    assert {:error, :not_holder} = Lease.renew(lease, "alice", @t0 + 60_001)
    assert {:ok, _, _} = Lease.renew(lease, "alice", @t0 + 10_000)
  end

  test "only the holder may release" do
    {:ok, lease, _} = Lease.claim(Lease.new(), "alice", @t0)
    assert {:error, :not_holder} = Lease.release(lease, "bob", @t0)
    assert {:ok, freed} = Lease.release(lease, "alice", @t0)
    assert Lease.holder(freed, @t0) == :free
  end

  describe "authorize" do
    test "A READ VERB NEVER NEEDS A LEASE" do
      # Read verbs stay open precisely so a caller who cannot take the lease can still watch, which is
      # what makes waiting tolerable.
      {:ok, lease, _} = Lease.claim(Lease.new(), "alice", @t0)
      assert Lease.authorize(lease, "bob", :read, @t0) == :ok
      assert Lease.authorize(Lease.new(), "bob", :read, @t0) == :ok
    end

    test "a mutating verb with no lease at all is refused" do
      assert Lease.authorize(Lease.new(), "alice", :mutate, @t0) == {:error, :needs_lease}
    end

    test "THE FAILURE THIS PREVENTS: a mutating verb from a caller who does not hold the box" do
      # Caller A syncs -- a force checkout and hard reset -- while B has a server mid-measurement on the
      # old tree. B's run does not crash. It produces numbers for a commit it is no longer running.
      {:ok, lease, _} = Lease.claim(Lease.new(), "measuring", @t0)

      assert {:error, {:contended, "measuring", _}} =
               Lease.authorize(lease, "syncing", :mutate, @t0)
    end

    test "the holder may mutate" do
      {:ok, lease, _} = Lease.claim(Lease.new(), "alice", @t0)
      assert Lease.authorize(lease, "alice", :mutate, @t0) == :ok
    end

    test "a holder whose lease lapsed must re-claim rather than continuing" do
      {:ok, lease, _} = Lease.claim(Lease.new(), "alice", @t0, ttl_ms: 60_000)
      assert Lease.authorize(lease, "alice", :mutate, @t0 + 60_001) == {:error, :needs_lease}
    end
  end

  test "there is no steal and no override" do
    # A force-break verb would be used by whichever caller was most confident, which is not the same as
    # whichever caller was right. Assert the module exposes no such door.
    exported = Lease.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    refute Enum.any?(exported, &(to_string(&1) =~ ~r/steal|break|force|override/))
  end
end
