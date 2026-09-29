defmodule Orbitorc.Agent.JobTest do
  @moduledoc """
  The teardown guarantee, exercised against a real operating-system process.

  Every other test in this repository runs with nothing outside the BEAM. This one launches a shell,
  because the property under test — a stopped job is a dead process — is a property of the operating
  system, and a fake would prove nothing about it.
  """
  use ExUnit.Case, async: false

  alias Orbitorc.Agent.{Jobs, Platform}

  @moduletag :unix

  setup_all do
    if Platform.kind() == :windows, do: {:ok, skip: true}, else: :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "orbitorc-jobs-#{System.unique_integer([:positive])}")
    start_supervised!({Jobs, root: root, retention: 5})
    Phoenix.PubSub.subscribe(Orbitorc.PubSub, Jobs.topic())
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  # A job that writes its marker to the log file it was given, then lives until killed.
  defp long_lived(marker) do
    fn _dir, log_path ->
      {:ok, ["/bin/sh", "-c", "echo #{marker} >> '#{log_path}'; sleep 60"]}
    end
  end

  defp wait_until(pred, left \\ 40) do
    cond do
      pred.() ->
        :ok

      left == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(50)
        wait_until(pred, left - 1)
    end
  end

  defp alive?(os_pid),
    do:
      match?(
        {_, 0},
        System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
      )

  test "READINESS IS THE MARKER: the job is ready when its log shows the line, not after a sleep" do
    {:ok, id, info} = Jobs.launch(argv_builder: long_lived("UP"), marker: "UP", caller: "t")
    refute info.ready

    assert_receive {:job_event, ^id, "ready", %{"ready_ms" => ms}}, 3_000
    assert is_integer(ms)
    assert {:ok, %{ready: true}} = Jobs.info(id)
  end

  test "A STOPPED JOB IS A DEAD PROCESS" do
    {:ok, id, %{os_pid: os_pid}} =
      Jobs.launch(argv_builder: long_lived("UP"), marker: "UP", caller: "t")

    assert_receive {:job_event, ^id, "ready", _}, 3_000
    assert alive?(os_pid)

    :ok = Jobs.stop(id)

    assert_receive {:job_event, ^id, "exited", %{"status" => "reaped"}}, 3_000
    Process.sleep(100)
    refute alive?(os_pid), "the operating-system process outlived its owner"
  end

  test "a job that exits on its own reports its status, and is still readable afterward" do
    builder = fn _dir, log_path ->
      {:ok, ["/bin/sh", "-c", "echo UP >> '#{log_path}'; exit 3"]}
    end

    {:ok, id, _} = Jobs.launch(argv_builder: builder, marker: "UP", caller: "t")

    assert_receive {:job_event, ^id, "exited", %{"status" => 3, "ready" => true}}, 3_000

    # The event is announced before the owner stops; the registry forgets it only once it has. Wait
    # for that rather than sleeping a fixed time a loaded runner may exceed.
    wait_until(fn -> not Jobs.alive?(id) end)

    # The process is gone; the record is not. A bench client self-terminates, and its results are read
    # after that, so a registry that only knew live jobs would lose every result worth reading.
    refute Jobs.alive?(id)
    assert {:ok, %{alive: false, exit_status: 3, mode: nil, dir: dir}} = Jobs.info(id)
    assert File.exists?(Path.join(dir, "job.json"))
    assert {:ok, ["UP"]} = Jobs.logs(id)
  end

  test "a job whose argv cannot be built never starts, and says why" do
    builder = fn _dir, _log -> {:error, "mode bench needs join"} end
    assert {:error, reason} = Jobs.launch(argv_builder: builder, caller: "t")
    assert inspect(reason) =~ "needs join"
  end

  test "a job whose executable does not exist never starts" do
    builder = fn _dir, _log -> {:ok, ["/no/such/engine", "--headless"]} end
    assert {:error, reason} = Jobs.launch(argv_builder: builder, caller: "t")
    assert inspect(reason) =~ "neither a file nor on PATH"
  end

  test "stop_all reaps only the caller's own jobs unless forced" do
    {:ok, mine, _} = Jobs.launch(argv_builder: long_lived("UP"), marker: "UP", caller: "me")

    {:ok, theirs, _} =
      Jobs.launch(argv_builder: long_lived("UP"), marker: "UP", caller: "someone")

    assert Jobs.stop_all("me") == [mine]
    Process.sleep(50)
    assert Jobs.alive?(theirs)

    assert Jobs.stop_all("me", force: true) == [theirs]
  end

  test "ids never repeat across a restart, because the next one is read off the disk", %{
    root: root
  } do
    {:ok, first, _} = Jobs.launch(argv_builder: long_lived("UP"), marker: "UP", caller: "t")
    :ok = Jobs.stop(first)
    Process.sleep(50)

    stop_supervised!(Jobs)
    start_supervised!({Jobs, root: root, retention: 5})

    {:ok, second, _} = Jobs.launch(argv_builder: long_lived("UP"), marker: "UP", caller: "t")
    assert second > first
  end
end
