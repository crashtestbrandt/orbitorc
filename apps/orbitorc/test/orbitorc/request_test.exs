defmodule Orbitorc.RequestTest do
  @moduledoc """
  A request ends one of three ways, and all three are pinned here. The one that matters most is the
  second: a caller must not be left waiting on a machine that has gone.
  """
  use ExUnit.Case, async: false

  alias Orbitorc.Request

  setup do
    start_supervised!(Request)
    :ok
  end

  test "a box that answers resolves the waiting caller" do
    {:ok, ref} = Request.open("win", 1_000)
    Request.resolve(ref, {:ok, %{"jobs" => []}})
    assert Request.await(ref, 1_000) == {:ok, %{"jobs" => []}}
  end

  test "an error from the box reaches the caller as an error" do
    {:ok, ref} = Request.open("win", 1_000)
    Request.resolve(ref, {:error, "this box has no graphical session"})
    assert {:error, "this box has no graphical session"} = Request.await(ref, 1_000)
  end

  test "A BOX THAT DISCONNECTS FAILS EVERY REQUEST WAITING ON IT, rather than leaving the caller hanging" do
    {:ok, a} = Request.open("win", 30_000)
    {:ok, b} = Request.open("win", 30_000)
    {:ok, other} = Request.open("mac", 30_000)

    Request.fail_box("win", :closed)

    assert {:error, reason} = Request.await(a, 1_000)
    assert reason =~ "win disconnected"
    assert {:error, _} = Request.await(b, 1_000)

    # A different box's request is untouched.
    Request.resolve(other, {:ok, :fine})
    assert Request.await(other, 1_000) == {:ok, :fine}
  end

  test "a box that accepted a request and never answered times out rather than hanging the fleet" do
    {:ok, ref} = Request.open("win", 50)
    assert {:error, reason} = Request.await(ref, 50)
    assert reason =~ "did not answer"
  end

  test "a reply that arrives after its timeout is dropped, not delivered to whoever owns that mailbox now" do
    {:ok, ref} = Request.open("win", 50)
    assert {:error, _} = Request.await(ref, 50)

    Request.resolve(ref, {:ok, :late})
    refute_receive {:orbitorc_reply, ^ref, _}, 200
  end

  test "refs do not collide across requests" do
    refs = for _ <- 1..200, do: elem(Request.open("win", 5_000), 1)
    assert length(Enum.uniq(refs)) == 200
  end
end
