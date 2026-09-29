defmodule Mix.Tasks.Orbitorc do
  @shortdoc "Drive the fleet from the command line"

  @moduledoc """
  The command line over the control plane's JSON API.

      mix orbitorc doctor                              every box: platform, session, projects, checks
      mix orbitorc doctor --box win                    one box, asked fresh rather than read from cache
      mix orbitorc sync main                           every box to the same revision, and say if they disagree
      mix orbitorc lease claim --box win               take a box; mutating verbs need it
      mix orbitorc lease release --box win
      mix orbitorc launch orbitnet server --box win    launch a mode a project declares
      mix orbitorc launch orbitnet bench --box mac --param join=192.168.1.9:47900
      mix orbitorc status --box win                    what it is running, and who holds it
      mix orbitorc logs 3 --box win --tail 80 --grep 'net_peer'
      mix orbitorc stop 3 --box win                    stop one job
      mix orbitorc stop --box win --all                stop the jobs THIS caller started
      mix orbitorc dry-run orbitnet server --box win   the exact argv the box would run, and nothing launched
      mix orbitorc build orbitnet linux --box linux
      mix orbitorc shot 3 --box win                    capture one window, never the screen
      mix orbitorc pull 3 --box win --file metrics.csv
      mix orbitorc verdict 3 orbitnet --box win        did that job measure anything
      mix orbitorc run orbitnet                        a whole fleet run: place, bring up, fan out, judge
      mix orbitorc run orbitnet --measure 40 --link relay --load-per-box 4
      mix orbitorc run orbitnet --wait                 follow the run to its verdict
      mix orbitorc runs                                live runs, then history
      mix orbitorc run-status <id>

  ## Options

      --box NAME          which box (required for anything box-scoped)
      --caller NAME       who is asking. Defaults to `$USER@$(hostname)`, which is what the lease
                          arbitrates between and the audit log attributes to
      --url URL           the control plane. Defaults to $ORBITORC_URL, else http://localhost:4000
      --param k=v         a launch parameter; repeatable
      --headless          run a rendering mode without a window: bot fleets, display-less boxes
      --json              print the raw response instead of a rendered table

  ## A caller identity is not decoration

  It is what the lease arbitrates between and what the audit log attributes to. The default is derived
  rather than blank, because an anonymous mutation makes both useless — and on a box several people
  drive, the audit log is the only way to reconstruct who changed what.
  """

  use Mix.Task

  @default_url "http://localhost:4000"

  @switches [
    box: :string,
    caller: :string,
    url: :string,
    param: :keep,
    headless: :boolean,
    json: :boolean,
    tail: :integer,
    grep: :string,
    file: :string,
    measure: :integer,
    link: :string,
    load_per_box: :integer,
    seed: :integer,
    authority_box: :string,
    load_box: :keep,
    allow_colocated: :boolean,
    force: :boolean,
    all: :boolean,
    window: :string,
    ttl: :integer,
    wait: :boolean,
    id: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    Application.ensure_all_started(:req)
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    case args do
      ["doctor" | _] ->
        doctor(opts)

      ["fleet" | _] ->
        get("/api/fleet", %{}, opts)

      ["sync", revision | rest] ->
        sync(revision, project(rest), opts)

      ["lease", action | _] ->
        lease(action, opts)

      ["launch", project, mode | _] ->
        launch(project, mode, opts)

      ["status" | _] ->
        get("/api/box/#{box!(opts)}/status", %{}, opts)

      ["logs", id | _] ->
        logs(id, opts)

      ["stop", id | _] ->
        stop(Keyword.put(opts, :id, String.to_integer(id)))

      ["stop" | _] ->
        stop(opts)

      ["dry-run", project, mode | _] ->
        dry_run(project, mode, opts)

      ["runs" | _] ->
        get("/api/runs", %{}, opts)

      ["run-status", id | _] ->
        get("/api/run/#{id}", %{}, opts)

      ["build", project, target | _] ->
        post("/api/box/#{box!(opts)}/build", %{"project" => project, "target" => target}, opts)

      ["shot", id | _] ->
        post("/api/box/#{box!(opts)}/jobs/#{id}/shot", %{"window" => opts[:window]}, opts)

      ["pull", id | _] ->
        pull(id, opts)

      ["verdict", id, project | _] ->
        get("/api/box/#{box!(opts)}/jobs/#{id}/verdict", %{"project" => project}, opts)

      ["run", project | _] ->
        run_fleet(project, opts)

      _ ->
        Mix.raise(usage())
    end
  end

  defp usage, do: "usage: mix orbitorc <verb> [args] [options]\n\n" <> @moduledoc

  # --- verbs ----------------------------------------------------------------------------------------

  defp doctor(opts) do
    case opts[:box] do
      nil -> get("/api/fleet", %{}, opts)
      box -> get("/api/box/#{box}/doctor", %{}, opts)
    end
  end

  defp lease(action, opts) do
    box = box!(opts)

    case request(
           :post,
           "/api/box/#{box}/lease",
           %{"action" => action, "ttl_ms" => ttl(opts)},
           opts
         ) do
      {:ok, ttl} when is_integer(ttl) and action in ["claim", "renew"] ->
        Mix.shell().info("#{box} is yours for #{div(ttl, 1000)}s as #{caller(opts)}")

      {:ok, _} when action == "release" ->
        Mix.shell().info("released #{box}")

      other ->
        render(other, opts)
    end
  end

  defp sync(revision, project, opts) do
    body =
      %{
        "project" =>
          project || Mix.raise("sync needs a project: mix orbitorc sync <revision> <project>"),
        "revision" => revision
      }
      |> put_boxes(opts)

    post("/api/sync", body, opts)
  end

  defp launch(project, mode, opts) do
    body = %{
      "project" => project,
      "mode" => mode,
      "params" => params(opts),
      "headless" => !!opts[:headless]
    }

    post("/api/box/#{box!(opts)}/launch", body, opts)
  end

  defp logs(id, opts) do
    get(
      "/api/box/#{box!(opts)}/jobs/#{id}/logs",
      %{"tail" => opts[:tail] || 100, "grep" => opts[:grep]},
      opts
    )
  end

  defp stop(opts) do
    body =
      %{}
      |> put_if(opts[:all], "all", true)
      |> put_if(opts[:force], "force", true)
      |> put_if(opts[:id], "id", opts[:id])

    post("/api/box/#{box!(opts)}/stop", body, opts)
  end

  defp pull(id, opts) do
    file = opts[:file] || "metrics.csv"

    case request(:get, "/api/box/#{box!(opts)}/jobs/#{id}/pull", %{"file" => file}, opts) do
      {:ok, %{"base64" => encoded, "file" => name, "bytes" => bytes}} ->
        {:ok, body} = Base.decode64(encoded)
        File.write!(name, body)
        Mix.shell().info("wrote #{name} (#{bytes} bytes)")

      other ->
        render(other, opts)
    end
  end

  defp dry_run(project, mode, opts) do
    body = %{
      "project" => project,
      "mode" => mode,
      "params" => params(opts),
      "headless" => !!opts[:headless]
    }

    case request(:post, "/api/box/#{box!(opts)}/dry-run", body, opts) do
      {:ok, %{"argv" => argv} = value} when is_list(argv) ->
        if opts[:json] do
          render({:ok, value}, opts)
        else
          Mix.shell().info("would run, in #{value["cwd"]}:")
          Mix.shell().info("  " <> Enum.map_join(argv, " ", &shell_quote/1))

          if value["marker"],
            do: Mix.shell().info("ready when the log shows: #{inspect(value["marker"])}")

          if map_size(value["env"] || %{}) > 0,
            do: Mix.shell().info("env: #{inspect(value["env"])}")
        end

      other ->
        render(other, opts)
    end
  end

  defp shell_quote(arg) do
    if arg =~ ~r/[\s"'$]/, do: "'" <> String.replace(arg, "'", "'\\''") <> "'", else: arg
  end

  defp run_fleet(project, opts) do
    body =
      %{"project" => project}
      |> put_if(opts[:measure], "measure_s", opts[:measure])
      |> put_if(opts[:link], "link_mode", opts[:link])
      |> put_if(opts[:load_per_box], "load_per_box", opts[:load_per_box])
      |> put_if(opts[:seed], "seed", opts[:seed])
      |> put_if(opts[:authority_box], "authority_box", opts[:authority_box])
      |> put_if(opts[:allow_colocated], "allow_colocated", true)
      |> then(fn body ->
        case Keyword.get_values(opts, :load_box) do
          [] -> body
          boxes -> Map.put(body, "load_boxes", boxes)
        end
      end)
      |> Map.put("params", params(opts))

    wait? = opts[:wait] == true

    case request(:post, "/api/run", body, opts) do
      {:ok, %{"id" => id}} when wait? -> follow(id, opts)
      other -> render(other, opts)
    end
  end

  # Follow a run to its end, printing each transition once. The run's snapshot is read from the
  # control plane, which answers from what the run published rather than by calling into it.
  defp follow(id, opts) do
    Mix.shell().info("run #{id}")
    follow(id, opts, 0)
  end

  defp follow(id, opts, seen) do
    case request(:get, "/api/run/#{id}", %{}, opts) do
      {:ok, snap} ->
        timeline = snap["timeline"] || []

        timeline
        |> Enum.drop(seen)
        |> Enum.each(fn entry ->
          Mix.shell().info("  #{pad_ms(entry["at"])}  #{entry["phase"]}  #{entry["line"]}")
        end)

        case snap["phase"] do
          "done" ->
            Enum.each(snap["verdicts"] || [], fn v ->
              Mix.shell().info(
                "  verdict  #{v["box"]} job #{v["job"]}: #{v["verdict"]} — #{v["detail"]}"
              )
            end)

          "failed" ->
            Mix.shell().error("failed: #{snap["failure"]}")
            exit({:shutdown, 1})

          _ ->
            Process.sleep(2_000)
            follow(id, opts, length(timeline))
        end

      {:error, reason} ->
        Mix.shell().error(reason)
        exit({:shutdown, 1})
    end
  end

  defp pad_ms(ms) when is_integer(ms),
    do: String.pad_leading("#{div(ms, 1000)}.#{rem(div(ms, 100), 10)}s", 7)

  defp pad_ms(_), do: "      ?"

  # --- transport ------------------------------------------------------------------------------------

  defp get(path, query, opts), do: request(:get, path, query, opts) |> render(opts)
  defp post(path, body, opts), do: request(:post, path, body, opts) |> render(opts)

  defp request(method, path, payload, opts) do
    url = (opts[:url] || System.get_env("ORBITORC_URL") || @default_url) <> path
    payload = Map.put(payload, "caller", caller(opts)) |> Map.reject(fn {_, v} -> is_nil(v) end)

    result =
      case method do
        :get -> Req.get(url, params: payload, receive_timeout: 960_000)
        :post -> Req.post(url, json: payload, receive_timeout: 960_000)
      end

    case result do
      {:ok, %{body: %{"ok" => true, "value" => value}}} ->
        {:ok, value}

      {:ok, %{body: %{"ok" => false, "error" => reason}}} ->
        {:error, reason}

      {:ok, %{status: status, body: body}} ->
        {:error, "the control plane answered #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "could not reach #{url}: #{Exception.message(reason)}"}
    end
  end

  defp render({:error, reason}, _opts) do
    Mix.shell().error(reason)
    exit({:shutdown, 1})
  end

  defp render({:ok, value}, opts) do
    if opts[:json] do
      Mix.shell().info(Jason.encode!(value, pretty: true))
    else
      Mix.shell().info(pretty(value))
    end
  end

  defp pretty(%{"boxes" => boxes}) when is_list(boxes) do
    if boxes == [] do
      "no box is connected. An agent dials out to the control plane; start one and it appears here."
    else
      Enum.map_join(boxes, "\n", &box_block/1)
    end
  end

  defp pretty(value) when is_map(value) or is_list(value), do: Jason.encode!(value, pretty: true)
  defp pretty(value), do: to_string(value)

  defp box_block(box) do
    projects =
      box["projects"]
      |> Enum.sort()
      |> Enum.map_join("\n", fn {name, report} ->
        "      #{name}  #{short_sha(report)}#{flags(report)}"
      end)

    """
      #{box["name"]}  #{box["platform"]}#{if box["session_ok"], do: "", else: "  [no graphical session]"}
        lan     #{box["lan"] || "—"}
        session #{box["session"]}
    #{projects}#{problems(box)}\
    """
  end

  defp problems(%{"problems" => []}), do: ""
  defp problems(%{"problems" => list}), do: "\n    problems " <> Enum.join(list, "; ")
  defp problems(_), do: ""

  defp short_sha(report) do
    case get_in(report, ["revision", "sha"]) do
      sha when is_binary(sha) -> String.slice(sha, 0, 8)
      _ -> "—"
    end
  end

  defp flags(report) do
    [
      if(get_in(report, ["revision", "dirty"]) == true, do: " dirty"),
      if(get_in(report, ["import", "ok"]) == false, do: " stale-import"),
      if(get_in(report, ["engine", "ok"]) == false, do: " no-engine"),
      if(get_in(report, ["manifest", "ok"]) == false, do: " no-manifest"),
      if(get_in(report, ["requires", "ok"]) == false, do: " missing-deps")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  # --- options --------------------------------------------------------------------------------------

  defp box!(opts) do
    opts[:box] ||
      Mix.raise("this verb needs --box NAME (mix orbitorc doctor lists what is connected)")
  end

  defp caller(opts) do
    opts[:caller] || System.get_env("ORBITORC_CALLER") ||
      "#{System.get_env("USER") || "unknown"}@#{hostname()}"
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "unknown"
    end
  end

  defp params(opts) do
    opts
    |> Keyword.get_values(:param)
    |> Map.new(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> {key, coerce(value)}
        [key] -> {key, true}
      end
    end)
  end

  # A parameter typed on a command line is a string. An integer that stays a string builds a different
  # argv than the one intended, so a numeric-looking value is coerced here rather than at the box.
  defp coerce(value) do
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

  defp project([project | _]), do: project
  defp project(_), do: nil

  defp ttl(opts), do: opts[:ttl] && opts[:ttl] * 1_000

  defp put_boxes(body, opts) do
    case Keyword.get_values(opts, :load_box) ++ List.wrap(opts[:box]) do
      [] -> body
      boxes -> Map.put(body, "boxes", Enum.uniq(boxes))
    end
  end

  defp put_if(map, nil, _key, _value), do: map
  defp put_if(map, false, _key, _value), do: map
  defp put_if(map, _present, key, value), do: Map.put(map, key, value)
end
