defmodule OrbitorcWeb.Verbs do
  @moduledoc """
  Every verb, once.

  The JSON API the command line drives and the dashboard's pages call the same function per verb, so a
  verb exists in both or in neither. `names/0` is the table the parity test reads against the router
  and the pages, and `mutates?/1` is the one rule about callers: a verb that changes a box needs one,
  because the lease arbitrates between callers and the audit log attributes to them.

  Parameters arrive as the JSON API receives them -- string keys, values as typed by whoever sent
  them -- and a page builds the same map from its form. Answers are `{:ok, value}` or `{:error, reason}`;
  an error that maps to a particular HTTP status carries it as `{:error, {status, reason}}`.
  """

  alias Orbitorc.{Box, Fleet, Run, Runs}

  @reads ~w(fleet doctor status logs pull verdict runs run-status dry-run)
  @mutations ~w(lease launch stop build shot sync run)

  @doc "Every verb, sorted."
  @spec names() :: [String.t()]
  def names, do: Enum.sort(@reads ++ @mutations)

  @doc "Whether a verb changes a box, and therefore needs a caller."
  @spec mutates?(String.t()) :: boolean()
  def mutates?(verb), do: verb in @mutations

  @doc "Whether the name is a verb at all."
  @spec verb?(String.t()) :: boolean()
  def verb?(verb), do: verb in @reads or verb in @mutations

  @type result :: {:ok, term()} | {:error, String.t()} | {:error, {pos_integer(), String.t()}}

  @doc """
  Run one verb.

  A read with no caller runs as `anonymous`. A mutation with no caller is refused before anything is
  asked of a box.
  """
  @spec run(String.t(), map(), String.t() | nil) :: result()
  def run(verb, params, caller) when is_binary(verb) and is_map(params) do
    cond do
      not verb?(verb) ->
        {:error, {404, "no verb #{inspect(verb)}"}}

      mutates?(verb) and not present?(caller) ->
        {:error,
         {400,
          "this verb mutates a box, so it needs a caller — that is what the lease arbitrates between"}}

      true ->
        do_run(verb, params, if(present?(caller), do: caller, else: "anonymous"))
    end
  end

  # --- reads ----------------------------------------------------------------------------------------

  defp do_run("fleet", _params, _caller) do
    {:ok, %{"boxes" => Enum.map(Fleet.list(), &render_box/1)}}
  end

  # Fresh from the box, and the fleet's cache learns it, so the next placement and the next page read
  # what the box just said rather than what it said when it joined.
  defp do_run("doctor", params, caller) do
    with {:ok, box} <- required(params, "box"),
         {:ok, report} <- Box.doctor(box, caller) do
      Fleet.update(box, report)
      {:ok, report}
    end
  end

  defp do_run("status", params, caller) do
    with {:ok, box} <- required(params, "box"), do: Box.status(box, caller)
  end

  defp do_run("logs", params, caller) do
    with {:ok, box} <- required(params, "box"),
         {:ok, id} <- required_int(params, "id") do
      Box.logs(box, caller, id,
        tail: to_int(params["tail"], 100),
        grep: blank_to_nil(params["grep"])
      )
    end
  end

  defp do_run("pull", params, caller) do
    with {:ok, box} <- required(params, "box"),
         {:ok, id} <- required_int(params, "id") do
      Box.pull(box, caller, id, blank_to_nil(params["file"]) || "metrics.csv")
    end
  end

  defp do_run("verdict", params, caller) do
    with {:ok, box} <- required(params, "box"),
         {:ok, id} <- required_int(params, "id"),
         {:ok, project} <- required(params, "project") do
      Box.verdict(box, caller, project, id)
    end
  end

  defp do_run("runs", params, _caller) do
    limit = to_int(params["limit"], 50)
    live = Runs.live_runs()
    live_ids = MapSet.new(live, & &1.id)
    stored = Runs.list(limit) |> Enum.reject(&MapSet.member?(live_ids, &1.id))
    {:ok, %{"runs" => live ++ stored}}
  end

  defp do_run("run-status", params, _caller) do
    with {:ok, id} <- required(params, "id") do
      case Runs.fetch(id) do
        {:ok, snap} -> {:ok, snap}
        {:error, :not_found} -> {:error, {404, "no run #{id}"}}
      end
    end
  end

  # A dry run goes to the box, because the argv is built there from the box's own manifest, checkout
  # and ports. Anything computed here would be a guess about a machine this process cannot see. It
  # needs no lease: nothing changes.
  defp do_run("dry-run", params, caller) do
    with {:ok, box} <- required(params, "box"),
         {:ok, project} <- required(params, "project"),
         {:ok, mode} <- required(params, "mode") do
      Box.launch(box, caller, project, mode, launch_opts(params) ++ [dry: true])
    end
  end

  # --- mutations ------------------------------------------------------------------------------------

  defp do_run("lease", params, caller) do
    with {:ok, box} <- required(params, "box"),
         {:ok, action} <- required(params, "action") do
      Box.lease(box, caller, action, ttl_ms: to_int(params["ttl_ms"], nil))
    end
  end

  defp do_run("launch", params, caller) do
    with {:ok, box} <- required(params, "box"),
         {:ok, project} <- required(params, "project"),
         {:ok, mode} <- required(params, "mode") do
      opts = launch_opts(params) ++ [duration_s: to_int(params["duration_s"], nil)]
      Box.launch(box, caller, project, mode, opts)
    end
  end

  defp do_run("stop", params, caller) do
    with {:ok, box} <- required(params, "box") do
      # An id arrives as a number from the command line's JSON and as a string from a page's button.
      opts =
        []
        |> then(&if given?(params["id"]), do: [{:id, to_int(params["id"], 0)} | &1], else: &1)
        |> then(&if truthy?(params["all"]), do: [{:all, true} | &1], else: &1)
        |> then(&if truthy?(params["force"]), do: [{:force, true} | &1], else: &1)

      Box.stop(box, caller, opts)
    end
  end

  defp do_run("build", params, caller) do
    with {:ok, box} <- required(params, "box"),
         {:ok, project} <- required(params, "project"),
         {:ok, target} <- required(params, "target") do
      Box.build(box, caller, project, target)
    end
  end

  defp do_run("shot", params, caller) do
    with {:ok, box} <- required(params, "box"),
         {:ok, id} <- required_int(params, "id") do
      Box.shot(box, caller, id, window: blank_to_nil(params["window"]))
    end
  end

  # Every named box, or every connected one; and whether they agree afterward. A fleet that is not on
  # one revision is not a fleet, so the check is part of the verb.
  defp do_run("sync", params, caller) do
    with {:ok, project} <- required(params, "project"),
         {:ok, revision} <- required(params, "revision") do
      names =
        case Map.get(params, "boxes") do
          names when is_list(names) and names != [] -> names
          _ -> Enum.map(Fleet.list(), & &1.name)
        end

      {:ok, Box.sync_all(names, caller, project, revision)}
    end
  end

  # The run supervises itself from here: it claims its boxes, brings up an authority, fans out load,
  # measures and judges. The answer is its id; its progress is read from `run-status`.
  defp do_run("run", params, caller) do
    with {:ok, project} <- required(params, "project") do
      id = Run.new_id()

      spec =
        %{id: id, project: project, caller: caller}
        |> put_opt(params, "authority_box", :authority_box)
        |> put_opt(params, "load_boxes", :load_boxes)
        |> put_opt(params, "authority_mode", :authority_mode)
        |> put_opt(params, "load_mode", :load_mode)
        |> put_opt(params, "link_mode", :link_mode)
        |> put_opt(params, "load_per_box", :load_per_box, &to_int(&1, nil))
        |> put_opt(params, "measure_s", :measure_s, &to_int(&1, nil))
        |> put_opt(params, "seed", :seed, &to_int(&1, nil))
        |> put_opt(params, "params", :params)
        |> put_opt(params, "allow_colocated", :allow_colocated, &truthy?/1)

      case DynamicSupervisor.start_child(Orbitorc.RunSupervisor, {Run, spec}) do
        {:ok, _pid} -> {:ok, %{"id" => id, "phase" => "placing"}}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  # --- shapes ---------------------------------------------------------------------------------------

  @doc "A fleet entry as the API and the pages render it."
  def render_box(box) do
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

  @doc """
  A launch parameter as typed on a command line or in a form is a string. An integer that stays a
  string builds a different argv than the one intended, so a numeric-looking value becomes a number.
  """
  def coerce(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> value
        end
    end
  end

  def coerce(value), do: value

  defp launch_opts(params) do
    [
      params: Map.get(params, "params", %{}),
      extra: List.wrap(Map.get(params, "extra", [])),
      headless: truthy?(Map.get(params, "headless")),
      exported: blank_to_nil(Map.get(params, "exported"))
    ]
  end

  defp required(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, {400, "#{key} is required"}}
    end
  end

  defp required_int(params, key) do
    with {:ok, value} <- required(params, key) do
      case to_int(value, nil) do
        nil -> {:error, {400, "#{key} must be a number"}}
        int -> {:ok, int}
      end
    end
  end

  defp put_opt(spec, params, key, field, convert \\ & &1) do
    case Map.get(params, key) do
      nil -> spec
      "" -> spec
      value -> Map.put(spec, field, convert.(value))
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
  defp given?(value), do: is_integer(value) or present?(value)
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp to_int(_value, default), do: default
end
