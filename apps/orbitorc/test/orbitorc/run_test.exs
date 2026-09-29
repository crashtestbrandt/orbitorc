defmodule Orbitorc.RunTest do
  @moduledoc """
  The fleet run, driven end to end against boxes that are processes rather than machines.

  A fake box does what a connected box's channel does: it joins the fleet with a report, answers each
  ask by resolving the request, and announces its jobs' readiness and exit on the box's job topic. That
  is the whole surface a run touches, so the run under test is the real one — every phase, every wait,
  every deadline, every refusal — with no engine and no network.
  """
  use ExUnit.Case, async: false

  alias Orbitorc.{Fleet, Request, Run}

  defmodule FakeBox do
    @moduledoc false

    @doc """
    Options:
      * `:on_launch` — `fn mode -> :ready | :silent | {:exit, status}` decides what a launched job does.
      * `:load_lifetime_ms` — how long a load job runs before it exits on its own.
      * `:verdict` — what the box answers for a verdict.
      * `:report` — overrides for the joined report.
    """
    def start(name, opts \\ []) do
      test = self()
      pid = spawn_link(fn -> boot(name, opts, test) end)

      receive do
        {:fake_joined, ^name} -> pid
      after
        1_000 -> raise "#{name} never joined"
      end
    end

    def leave(pid), do: send(pid, :leave)

    defp boot(name, opts, test) do
      report =
        Map.merge(
          %{
            "platform" => "linux",
            "session_ok" => true,
            "lan" => "10.0.0.#{:erlang.phash2(name, 200) + 1}",
            "game_port" => 47_900,
            "relay_port" => 47_910,
            "capabilities" => %{
              "launch.demo.server" => true,
              "launch.demo.bench" => true,
              "launch.demo.relay" => true
            }
          },
          Keyword.get(opts, :report, %{})
        )

      :ok = Fleet.join(name, report)
      send(test, {:fake_joined, name})
      loop(name, opts, test, 1)
    end

    defp loop(name, opts, test, next) do
      receive do
        :leave ->
          exit(:normal)

        {:ask, "lease", %{"ref" => ref, "action" => action}} ->
          send(test, {:lease, name, action})
          Request.resolve(ref, {:ok, 900_000})
          loop(name, opts, test, next)

        {:ask, "launch", %{"ref" => ref, "mode" => mode} = payload} ->
          id = next
          send(test, {:launched, name, id, mode, payload["params"]})
          Request.resolve(ref, {:ok, %{"id" => id, "job" => %{"ready" => false}}})

          case Keyword.get(opts, :on_launch, fn _ -> :ready end).(mode) do
            :ready ->
              event(name, id, "ready", %{"ready_ms" => 12})

              if mode == "bench" do
                Process.send_after(
                  self(),
                  {:finish, id},
                  Keyword.get(opts, :load_lifetime_ms, 30)
                )
              end

            :ready_twice ->
              event(name, id, "ready", %{"ready_ms" => 12})
              event(name, id, "ready", %{"ready_ms" => 12})

              if mode == "bench" do
                Process.send_after(
                  self(),
                  {:finish, id},
                  Keyword.get(opts, :load_lifetime_ms, 30)
                )
              end

            :silent ->
              :ok

            {:exit, status} ->
              event(name, id, "exited", %{"status" => status, "ready" => false})
          end

          loop(name, opts, test, next + 1)

        {:finish, id} ->
          event(name, id, "exited", %{"status" => 0, "ready" => true})
          loop(name, opts, test, next)

        {:ask, "verdict", %{"ref" => ref}} ->
          Request.resolve(
            ref,
            {:ok, Keyword.get(opts, :verdict, %{verdict: :measured, detail: "2 columns moved"})}
          )

          loop(name, opts, test, next)

        {:ask, "stop", %{"ref" => ref} = payload} ->
          send(test, {:stopped, name, payload["id"]})
          Request.resolve(ref, {:ok, %{}})
          loop(name, opts, test, next)

        {:ask, verb, %{"ref" => ref}} ->
          Request.resolve(ref, {:error, "fake box does not serve #{verb}"})
          loop(name, opts, test, next)
      end
    end

    # What the real channel does with a "job_event" push from the box.
    defp event(name, id, event, detail) do
      Phoenix.PubSub.broadcast(
        Orbitorc.PubSub,
        "box:#{name}:jobs",
        {:job_event, name, id, event, detail}
      )
    end
  end

  setup do
    start_supervised!(Request)
    start_supervised!(Fleet)
    :ok
  end

  # Start a run and return the last snapshot it published before stopping.
  defp run(spec) do
    spec =
      Map.merge(
        %{
          project: "demo",
          caller: "test",
          measure_s: 1,
          finish_grace_s: 2,
          bringup_timeout_ms: 500
        },
        spec
      )

    id = Run.new_id()
    Phoenix.PubSub.subscribe(Orbitorc.PubSub, Run.topic(id))
    {:ok, pid} = Run.start_link(Map.put(spec, :id, id))
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      10_000 -> flunk("the run did not end")
    end

    last_snapshot(id, nil)
  end

  defp last_snapshot(id, last) do
    receive do
      {:run, ^id, snap} -> last_snapshot(id, snap)
    after
      0 -> last || flunk("the run published nothing")
    end
  end

  test "TWO BOXES: the authority on one, the load on the other, and a verdict at the end" do
    FakeBox.start("alpha")
    FakeBox.start("beta")

    snap = run(%{})

    assert snap.phase == :done, "failed: #{snap.failure}"
    assert snap.authority.box != hd(snap.load).box, "load was placed beside the authority"
    assert [%{"verdict" => :measured}] = snap.verdicts

    # Every box it touched was claimed before anything launched, and released at the end.
    assert_received {:lease, _, "claim"}
    assert_received {:lease, _, "claim"}
    assert_received {:lease, _, "release"}
    assert_received {:lease, _, "release"}

    # The load client finished on its own; the authority was stopped by the run.
    assert_received {:stopped, authority_box, 1}
    assert authority_box == snap.authority.box
  end

  test "the load client joins the authority's LAN address on the box's declared game port" do
    FakeBox.start("alpha", report: %{"lan" => "192.168.7.7", "game_port" => 48_123})
    FakeBox.start("beta")

    snap = run(%{authority_box: "alpha"})
    assert snap.phase == :done, "failed: #{snap.failure}"
    assert_received {:launched, "beta", 1, "bench", %{"join" => "192.168.7.7:48123"}}
  end

  test "with a link, the load joins the link's port and the link targets the authority" do
    FakeBox.start("alpha", report: %{"lan" => "10.9.9.9"})
    FakeBox.start("beta")

    snap = run(%{authority_box: "alpha", link_mode: "relay"})
    assert snap.phase == :done, "failed: #{snap.failure}"
    assert_received {:launched, "alpha", 2, "relay", %{"target" => "10.9.9.9:47900"}}
    assert_received {:launched, "beta", 1, "bench", %{"join" => "10.9.9.9:47910"}}
  end

  test "ONE BOX: the run refuses to place load beside the authority, and launches nothing" do
    FakeBox.start("alpha")

    snap = run(%{})

    assert snap.phase == :failed
    assert snap.failure =~ "measures the harness, not the netcode"
    refute_received {:launched, _, _, _, _}
    refute_received {:lease, _, "claim"}
  end

  test "one box with allow_colocated is permitted, and says so in the placement line" do
    FakeBox.start("alpha")
    snap = run(%{allow_colocated: true})
    assert snap.phase == :done, "failed: #{snap.failure}"
  end

  test "an authority that exits before its marker fails the run at once, naming the job" do
    FakeBox.start("alpha", on_launch: fn _ -> {:exit, 1} end)
    FakeBox.start("beta")

    snap = run(%{authority_box: "alpha"})

    assert snap.phase == :failed
    assert snap.failure =~ "exited (1) before it was ready"
    # It failed on the event, not on the deadline: well under the 500 ms bringup timeout.
    assert snap.elapsed_ms < 450
  end

  test "an authority that never prints its marker fails on the deadline, naming what was waited on" do
    FakeBox.start("alpha", on_launch: fn _ -> :silent end)
    FakeBox.start("beta")

    snap = run(%{authority_box: "alpha", bringup_timeout_ms: 200})

    assert snap.phase == :failed
    assert snap.failure =~ "no ready marker"
    assert snap.failure =~ "alpha job 1"
  end

  test "a load box leaving the fleet mid-measurement fails the run, naming the box" do
    FakeBox.start("alpha")
    beta = FakeBox.start("beta", load_lifetime_ms: 5_000)

    id = Run.new_id()
    Phoenix.PubSub.subscribe(Orbitorc.PubSub, Run.topic(id))

    {:ok, pid} =
      Run.start_link(%{
        id: id,
        project: "demo",
        caller: "test",
        authority_box: "alpha",
        measure_s: 3,
        finish_grace_s: 3
      })

    ref = Process.monitor(pid)

    # Wait until the run is measuring, then take the box away.
    assert_receive {:run, ^id, %{phase: :measuring}}, 2_000
    FakeBox.leave(beta)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 3_000
    snap = last_snapshot(id, nil)
    assert snap.phase == :failed
    assert snap.failure =~ "beta left the fleet"
  end

  test "a client that measured nothing fails the run, naming the box" do
    FakeBox.start("alpha")

    FakeBox.start("beta",
      verdict: %{verdict: :vacuous, detail: "every evidence column stayed zero"}
    )

    snap = run(%{authority_box: "alpha"})

    assert snap.phase == :failed
    assert snap.failure =~ "measured nothing (beta)"
  end

  test "a client still running past the window and its grace fails the run rather than hanging it" do
    FakeBox.start("alpha")
    FakeBox.start("beta", load_lifetime_ms: 60_000)

    snap = run(%{authority_box: "alpha", measure_s: 1, finish_grace_s: 0})

    assert snap.phase == :failed
    assert snap.failure =~ "still running"
    assert snap.failure =~ "beta job 1"
  end

  test "A COLOCATED RUN WAITS ITS WINDOW: one box's events arrive once, and a ready never ends measuring" do
    # The authority and the load on one box. Every job event on that box reaches the run through one
    # subscription, and a stray second `ready` from the client is ignored rather than ending the window.
    FakeBox.start("alpha", load_lifetime_ms: 400, on_launch: fn _ -> :ready_twice end)

    snap = run(%{allow_colocated: true, measure_s: 1, finish_grace_s: 2})

    assert snap.phase == :done, "failed: #{snap.failure}"

    assert snap.elapsed_ms >= 400,
           "the window ended after #{snap.elapsed_ms} ms, before the client finished"

    assert Enum.count(snap.timeline, &(&1["line"] =~ "job 1 ready")) == 1
  end

  test "the timeline records every phase with a time, so a failed run says how far it got" do
    FakeBox.start("alpha")
    FakeBox.start("beta")

    snap = run(%{})
    phases = Enum.map(snap.timeline, & &1["phase"])

    assert Enum.take(phases, 3) == ["placing", "placing", "authority"]
    assert "measuring" in phases
    assert List.last(phases) == "done"
    assert Enum.all?(snap.timeline, &is_integer(&1["at"]))
  end

  test "a run is readable from the registry while it is alive, without calling its process" do
    FakeBox.start("alpha")
    FakeBox.start("beta", load_lifetime_ms: 500)

    id = Run.new_id()

    {:ok, pid} =
      Run.start_link(%{id: id, project: "demo", caller: "test", measure_s: 1, finish_grace_s: 2})

    Process.sleep(50)
    assert {:ok, %{id: ^id, alive: true}} = Orbitorc.Runs.fetch(id)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end
end
