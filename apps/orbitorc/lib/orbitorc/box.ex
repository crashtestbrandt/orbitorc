defmodule Orbitorc.Box do
  @moduledoc """
  Asking one box to do one thing.

  Every verb a caller can run against a machine goes through here, so there is one place where a
  request is registered, sent, awaited and attributed — rather than one per verb, each with its own
  idea of what a timeout means.

  ## A capability is checked before the request is sent

  A launch is checked against what the box reported it can serve, in the control plane, before anything
  crosses the wire. The box checks again on arrival — it is the authority over itself — but refusing
  early is what makes the failure readable: "this target has no graphical session" instead of a job that
  came up, drew nothing, and reported success.

  ## Timeouts are per verb because the work is not comparable

  A `doctor` is a few probes. A `build` is an export. Giving them one timeout means either aborting
  healthy builds or waiting minutes to learn a box is wedged.
  """

  alias Orbitorc.{Capability, Fleet, Request}

  @doc "How long each verb is given before a box is assumed wedged."
  def timeout_ms(verb) do
    case verb do
      "doctor" -> 30_000
      "launch" -> 60_000
      "build" -> 900_000
      "sync" -> 300_000
      "upgrade" -> 600_000
      _ -> 30_000
    end
  end

  @doc """
  Ask a connected box for something and wait for its answer.

  Answers `{:error, reason}` rather than raising for every way this can fail: the box is not connected,
  it disconnects mid-request, it refuses, or it never answers.
  """
  @spec ask(String.t(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, String.t()}
  def ask(box_name, verb, payload \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, timeout_ms(verb))

    with {:ok, box} <- connected(box_name),
         {:ok, ref} <- Request.open(box_name, timeout) do
      send(box.pid, {:ask, verb, Map.put(payload, "ref", ref)})
      Request.await(ref, timeout)
    end
  end

  @doc "The box's own report, taken fresh rather than read from the fleet's cache."
  def doctor(box_name, caller), do: ask(box_name, "doctor", %{"caller" => caller})

  @doc "Take, renew or give up this box's lease."
  def lease(box_name, caller, action, opts \\ []) do
    ask(box_name, "lease", %{
      "caller" => caller,
      "action" => to_string(action),
      "ttl_ms" => Keyword.get(opts, :ttl_ms)
    })
  end

  @doc """
  Launch a mode of a project on this box.

  The capability is checked here first, so a box that cannot serve the mode says so by name instead of
  accepting the request and producing a job nobody should believe.
  """
  @spec launch(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, String.t()}
  def launch(box_name, caller, project, mode, opts \\ []) do
    headless = Keyword.get(opts, :headless, false)

    with {:ok, box} <- connected(box_name),
         :ok <- launchable(box, project, mode, headless) do
      ask(box_name, "launch", %{
        "caller" => caller,
        "project" => project,
        "mode" => mode,
        "params" => Keyword.get(opts, :params, %{}),
        "extra" => Keyword.get(opts, :extra, []),
        "headless" => headless,
        "exported" => Keyword.get(opts, :exported),
        "duration_s" => Keyword.get(opts, :duration_s),
        "dry" => Keyword.get(opts, :dry, false)
      })
    end
  end

  @doc "Every job the box is running, and who holds its lease."
  def status(box_name, caller), do: ask(box_name, "status", %{"caller" => caller})

  @doc "A job's log, most recent lines first filtered by an optional pattern."
  def logs(box_name, caller, id, opts \\ []) do
    ask(box_name, "logs", %{
      "caller" => caller,
      "id" => id,
      "tail" => Keyword.get(opts, :tail, 100),
      "grep" => Keyword.get(opts, :grep)
    })
  end

  @doc "Stop one job, or every job this caller started."
  def stop(box_name, caller, opts \\ []) do
    ask(
      box_name,
      "stop",
      %{"caller" => caller}
      |> maybe(:id, Keyword.get(opts, :id))
      |> maybe(:all, Keyword.get(opts, :all))
      |> maybe(:force, Keyword.get(opts, :force))
    )
  end

  @doc "Whether a finished job measured anything."
  def verdict(box_name, caller, project, id) do
    ask(box_name, "verdict", %{"caller" => caller, "project" => project, "id" => id})
  end

  @doc """
  Bring a project's checkout to a revision.

  This is a force checkout: anything uncommitted in the tree is gone. That is intended — every machine
  in a fleet must run the same code, because a disagreement between them reads as a netcode bug — and it
  is why it needs the lease.
  """
  def sync(box_name, caller, project, revision) do
    ask(box_name, "sync", %{"caller" => caller, "project" => project, "revision" => revision})
  end

  @doc "Run a project's own build recipe for one target, and assert the artifact is not a stub."
  def build(box_name, caller, project, target) do
    ask(box_name, "build", %{"caller" => caller, "project" => project, "target" => target})
  end

  @doc """
  Replace the box's agent with a release.

  The box downloads the archive, checks it against its sha256, stages it beside the running release,
  swaps and exits; its service manager brings the new release up. It needs the lease, and a box with a
  job running refuses.
  """
  def upgrade(box_name, caller, url, opts \\ []) do
    ask(box_name, "upgrade", %{
      "caller" => caller,
      "url" => url,
      "sha256" => Keyword.get(opts, :sha256),
      "version" => Keyword.get(opts, :version)
    })
  end

  @doc "Capture one window of a running job. Never the screen."
  def shot(box_name, caller, id, opts \\ []) do
    ask(box_name, "shot", %{
      "caller" => caller,
      "id" => id,
      "window" => Keyword.get(opts, :window)
    })
  end

  @doc "Fetch one of a job's artifacts back across the socket."
  def pull(box_name, caller, id, file) do
    ask(box_name, "pull", %{"caller" => caller, "id" => id, "file" => file})
  end

  @doc """
  Bring every named box to one revision, and say which of them disagree afterward.

  **A fleet that is not on one revision is not a fleet**: two machines running different code produce a
  disagreement that reads as a netcode bug. So the check is part of the verb rather than something a
  caller is trusted to do after it.
  """
  @spec sync_all([String.t()], String.t(), String.t(), String.t()) :: %{
          synced: map(),
          failed: map(),
          agreed: boolean()
        }
  def sync_all(box_names, caller, project, revision) do
    results = Map.new(box_names, &{&1, sync(&1, caller, project, revision)})

    {ok, failed} = Enum.split_with(results, fn {_, result} -> match?({:ok, _}, result) end)

    synced = Map.new(ok, fn {name, {:ok, report}} -> {name, report} end)
    shas = synced |> Map.values() |> Enum.map(&Map.get(&1, "sha")) |> Enum.uniq()

    %{
      synced: synced,
      failed: Map.new(failed, fn {name, {:error, reason}} -> {name, reason} end),
      agreed: failed == [] and length(shas) == 1,
      revisions: shas
    }
  end

  defp connected(name) do
    case Fleet.fetch(name) do
      {:ok, box} -> {:ok, box}
      {:error, :not_connected} -> {:error, "#{name} is not connected"}
    end
  end

  # A headless run waives the graphical-session requirement, which is the same door a bot fleet goes
  # through -- so the check has to know whether this launch is one.
  defp launchable(box, project, mode, headless) do
    capability = Capability.launch(project, mode)

    cond do
      Capability.permits?(box.capabilities, capability) ->
        :ok

      headless and Map.has_key?(box.capabilities, capability) ->
        :ok

      true ->
        Capability.check(box.capabilities, capability, box.name)
    end
  end

  defp maybe(payload, _key, nil), do: payload
  defp maybe(payload, key, value), do: Map.put(payload, to_string(key), value)
end
