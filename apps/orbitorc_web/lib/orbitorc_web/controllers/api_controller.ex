defmodule OrbitorcWeb.ApiController do
  @moduledoc """
  The JSON surface the command line drives.

  ## Every verb names its caller

  A caller identity is required on anything that mutates, because it is what the lease arbitrates
  between and what the audit log attributes to. An anonymous mutation would make both useless, so a
  request without one is refused rather than defaulted.

  ## A dry run resolves everything and launches nothing

  `dry_run` answers the exact argv a box would run, built from that box's own manifest, without
  starting it. The argv is the single thing most likely to be wrong in a remote harness, and being able
  to read it before committing a fleet to it is the cheapest check available.
  """

  use OrbitorcWeb, :controller

  alias Orbitorc.{Box, Fleet, Run}

  @doc """
  Every connected box and what it reports.

  Every endpoint answers the same envelope — `ok` plus `value`, or `ok: false` plus `error` — so a
  client has one shape to read rather than one per verb.
  """
  def fleet(conn, _params) do
    json(conn, %{"ok" => true, "value" => %{"boxes" => Enum.map(Fleet.list(), &render_box/1)}})
  end

  @doc "One box's report, taken fresh from the box rather than read from the fleet's cache."
  def doctor(conn, %{"box" => name} = params) do
    reply(conn, Box.doctor(name, caller(params)))
  end

  def lease(conn, %{"box" => name, "action" => action} = params) do
    with {:ok, caller} <- require_caller(params) do
      reply(conn, Box.lease(name, caller, action, ttl_ms: params["ttl_ms"]))
    else
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  def launch(conn, %{"box" => name, "project" => project, "mode" => mode} = params) do
    with {:ok, caller} <- require_caller(params) do
      opts = [
        params: Map.get(params, "params", %{}),
        extra: Map.get(params, "extra", []),
        headless: !!Map.get(params, "headless"),
        exported: Map.get(params, "exported"),
        duration_s: Map.get(params, "duration_s")
      ]

      reply(conn, Box.launch(name, caller, project, mode, opts))
    else
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  def status(conn, %{"box" => name} = params), do: reply(conn, Box.status(name, caller(params)))

  def logs(conn, %{"box" => name, "id" => id} = params) do
    opts = [tail: to_int(params["tail"], 100), grep: params["grep"]]
    reply(conn, Box.logs(name, caller(params), to_int(id, 0), opts))
  end

  def stop(conn, %{"box" => name} = params) do
    with {:ok, caller} <- require_caller(params) do
      opts =
        []
        |> then(&if params["id"], do: [{:id, to_int(params["id"], 0)} | &1], else: &1)
        |> then(&if params["all"], do: [{:all, true} | &1], else: &1)
        |> then(&if params["force"], do: [{:force, true} | &1], else: &1)

      reply(conn, Box.stop(name, caller, opts))
    else
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  def sync(conn, %{"project" => project, "revision" => revision} = params) do
    with {:ok, caller} <- require_caller(params) do
      case Map.get(params, "boxes") do
        names when is_list(names) and names != [] ->
          json(conn, %{"ok" => true, "value" => Box.sync_all(names, caller, project, revision)})

        _ ->
          all = Enum.map(Fleet.list(), & &1.name)
          json(conn, %{"ok" => true, "value" => Box.sync_all(all, caller, project, revision)})
      end
    else
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  def build(conn, %{"box" => name, "project" => project, "target" => target} = params) do
    with {:ok, caller} <- require_caller(params) do
      reply(conn, Box.build(name, caller, project, target))
    else
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  def shot(conn, %{"box" => name, "id" => id} = params) do
    with {:ok, caller} <- require_caller(params) do
      reply(conn, Box.shot(name, caller, to_int(id, 0), window: params["window"]))
    else
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  def pull(conn, %{"box" => name, "id" => id} = params) do
    reply(
      conn,
      Box.pull(name, caller(params), to_int(id, 0), Map.get(params, "file", "metrics.csv"))
    )
  end

  def verdict(conn, %{"box" => name, "project" => project, "id" => id} = params) do
    reply(conn, Box.verdict(name, caller(params), project, to_int(id, 0)))
  end

  @doc """
  Start a fleet run.

  The run supervises itself from here: it claims its boxes, brings up an authority, fans out load,
  measures and judges. The response is its id. Its progress is read from `GET /api/run/:id`, which
  answers from the run's published snapshot rather than by calling into a process that may be blocked
  on a box.
  """
  def run(conn, %{"project" => project} = params) do
    with {:ok, caller} <- require_caller(params) do
      id = Run.new_id()

      spec =
        %{id: id, project: project, caller: caller}
        |> put_opt(params, "authority_box", :authority_box)
        |> put_opt(params, "load_boxes", :load_boxes)
        |> put_opt(params, "authority_mode", :authority_mode)
        |> put_opt(params, "load_mode", :load_mode)
        |> put_opt(params, "link_mode", :link_mode)
        |> put_opt(params, "load_per_box", :load_per_box)
        |> put_opt(params, "measure_s", :measure_s)
        |> put_opt(params, "seed", :seed)
        |> put_opt(params, "params", :params)
        |> put_opt(params, "allow_colocated", :allow_colocated)

      case DynamicSupervisor.start_child(Orbitorc.RunSupervisor, {Run, spec}) do
        {:ok, _pid} -> json(conn, %{"ok" => true, "value" => %{"id" => id, "phase" => "placing"}})
        {:error, reason} -> error(conn, 422, inspect(reason))
      end
    else
      {:error, reason} -> error(conn, 400, reason)
    end
  end

  @doc "One run's current snapshot, live or recorded."
  def run_status(conn, %{"id" => id}) do
    case Orbitorc.Runs.fetch(id) do
      {:ok, snap} -> json(conn, %{"ok" => true, "value" => snap})
      {:error, :not_found} -> error(conn, 404, "no run #{id}")
    end
  end

  @doc "Runs, live ones first, then history newest first."
  def runs(conn, params) do
    limit = to_int(params["limit"], 50)
    live = Orbitorc.Runs.live_runs()
    live_ids = MapSet.new(live, & &1.id)
    stored = Orbitorc.Runs.list(limit) |> Enum.reject(&MapSet.member?(live_ids, &1.id))
    json(conn, %{"ok" => true, "value" => %{"runs" => live ++ stored}})
  end

  @doc """
  Resolve a launch on the box to its exact argv, and launch nothing.

  This goes to the box, because the argv is built there from the box's own manifest, checkout and
  configured ports. Anything computed here instead would be a guess about a machine this process cannot
  see. It needs no lease: nothing changes.
  """
  def dry_run(conn, %{"box" => name, "project" => project, "mode" => mode} = params) do
    opts = [
      params: Map.get(params, "params", %{}),
      extra: Map.get(params, "extra", []),
      headless: !!Map.get(params, "headless"),
      exported: Map.get(params, "exported"),
      dry: true
    ]

    reply(conn, Box.launch(name, caller(params), project, mode, opts))
  end

  # --- rendering ------------------------------------------------------------------------------------

  defp render_box(box) do
    {session_ok, session_detail} = box.session

    %{
      "name" => box.name,
      "platform" => box.platform,
      "session_ok" => session_ok,
      "session" => session_detail,
      "lan" => box.lan,
      "projects" => box.projects,
      "capabilities" => box.capabilities,
      "problems" => box.problems,
      "joined_at" => DateTime.to_iso8601(box.joined_at)
    }
  end

  defp caller(params), do: Map.get(params, "caller", "anonymous")

  defp require_caller(params) do
    case Map.get(params, "caller") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error,
         "this verb mutates a box, so it needs a caller — that is what the lease arbitrates between"}
    end
  end

  defp put_opt(spec, params, key, field) do
    case Map.get(params, key) do
      nil -> spec
      value -> Map.put(spec, field, value)
    end
  end

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp to_int(_value, default), do: default

  defp reply(conn, {:ok, value}), do: json(conn, %{"ok" => true, "value" => value})
  defp reply(conn, :ok), do: json(conn, %{"ok" => true, "value" => %{}})
  defp reply(conn, {:error, reason}), do: error(conn, 422, reason)

  defp error(conn, status, reason) do
    conn |> put_status(status) |> json(%{"ok" => false, "error" => to_string(reason)})
  end
end
