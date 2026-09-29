defmodule Orbitorc.CLI do
  @moduledoc """
  The command line over the control plane's JSON API.

      orbitorc fleet                                every box, from the fleet's cache
      orbitorc doctor                               the same, as a report per box
      orbitorc doctor --box win                     one box, asked fresh
      orbitorc sync main orbitnet                   every box to one revision, and say if they disagree
      orbitorc lease claim --box win                take a box; mutating verbs need it
      orbitorc launch orbitnet server --box win     launch a mode a project declares
      orbitorc launch orbitnet bench --all --headless --param join=192.168.1.9:47900
      orbitorc launch spaceman scene --box win --param scene=tools/instr/orbit_shot.tscn -- --arena=orbit-travel
      orbitorc dry-run orbitnet server --box win    the exact argv, and nothing launched
      orbitorc status --box win
      orbitorc logs 3 --box win --tail 80 --grep net_peer
      orbitorc logs 3 --box win --follow            the tail, then every line until the job exits
      orbitorc stop 3 --box win                     one job
      orbitorc stop --all                           the jobs THIS caller started, on every box
      orbitorc build spaceman windows --box win     the project's own export recipe, size asserted
      orbitorc build spaceman windows --all         on every box that can produce that target
      orbitorc shot 3 --box win                     capture one window, never the screen
      orbitorc pull 3 --box win --out ./artifacts   fetch an artifact to where you are standing
      orbitorc verdict 3 orbitnet --box win
      orbitorc run orbitnet --measure 30 --load-per-box 4 --wait
      orbitorc runs                                 live runs, then history
      orbitorc upgrade v0.2.0 --all                 every agent to a release; each swaps and restarts
      orbitorc run-status ID

  ## Targets

  `--box NAME` is one box. `--all` is every connected box that can serve the verb: for a launch, the
  boxes reporting `launch.<project>.<mode>`; for a build, the boxes reporting `export.<target>`; for a
  stop or a sync, every box. A fan-out reports one block per box and exits non-zero if any refused.

  ## Passthrough

  Everything after a bare `--` reaches the game's own argv, after everything the manifest built. It works
  on `launch` and `dry-run`. A dry run shows it in place, which is the way to check it before a box is
  committed to it.

  ## Options

      --caller NAME     who is asking; defaults to `$USER@hostname`. The lease arbitrates between callers
                        and the audit log attributes to them, so an anonymous mutation is refused.
      --url URL         the control plane; defaults to $ORBITORC_URL, else http://localhost:4000
      --param k=v       a launch parameter, repeatable; a numeric value is coerced
      --headless        run a rendering mode without a window
      --json            the raw response
  """

  @default_url "http://localhost:4000"

  @switches [
    box: :string,
    all: :boolean,
    caller: :string,
    url: :string,
    param: :keep,
    headless: :boolean,
    json: :boolean,
    tail: :integer,
    grep: :string,
    follow: :boolean,
    file: :string,
    out: :string,
    measure: :integer,
    link: :string,
    load_per_box: :integer,
    seed: :integer,
    authority_box: :string,
    load_box: :keep,
    allow_colocated: :boolean,
    force: :boolean,
    window: :string,
    ttl: :integer,
    sha256: :string,
    wait: :boolean,
    id: :integer
  ]

  @doc "Escript entry."
  def main(argv) do
    case run(argv) do
      :ok -> :ok
      {:error, _} -> System.halt(1)
    end
  end

  @doc "Run one invocation. Answers `:ok` or `{:error, reason}` rather than halting, so a task can wrap it."
  @spec run([String.t()]) :: :ok | {:error, String.t()}
  def run(argv) do
    Application.ensure_all_started(:req)
    # A bare `--` ends the options and starts the game's own argv.
    {ours, extra} =
      case Enum.split_while(argv, &(&1 != "--")) do
        {ours, ["--" | extra]} -> {ours, extra}
        {ours, []} -> {ours, []}
      end

    {opts, args, invalid} = OptionParser.parse(ours, strict: @switches)

    if invalid != [] do
      {:error, "unknown option: " <> Enum.map_join(invalid, ", ", fn {k, _} -> k end)}
    else
      dispatch(args, Keyword.put(opts, :extra, extra))
    end
    |> report(opts_json?(argv))
  end

  defp opts_json?(argv), do: "--json" in argv

  # --- verbs ----------------------------------------------------------------------------------------

  defp dispatch(["doctor" | _], opts) do
    case opts[:box] do
      nil -> get("/api/fleet", %{}, opts) |> show(opts, &fleet_block/1)
      box -> get("/api/box/#{box}/doctor", %{}, opts) |> show(opts)
    end
  end

  defp dispatch(["fleet" | _], opts), do: get("/api/fleet", %{}, opts) |> show(opts, &fleet_block/1)

  defp dispatch(["sync", revision, project | _], opts) do
    body = %{"project" => project, "revision" => revision} |> put_boxes(opts)

    post("/api/sync", body, opts)
    |> show(opts, fn %{"synced" => synced, "failed" => failed, "agreed" => agreed} = v ->
      lines =
        Enum.map(synced, fn {box, r} -> "  #{box}  #{String.slice(r["sha"] || "?", 0, 8)}  #{r["branch"]}" end) ++
          Enum.map(failed, fn {box, reason} -> "  #{box}  FAILED  #{reason}" end)

      verdict =
        cond do
          agreed -> "every box agrees on #{Enum.join(v["revisions"] || [], ", ")}"
          failed != %{} -> "#{map_size(failed)} box(es) failed to sync"
          true -> "THE FLEET DISAGREES: #{Enum.join(v["revisions"] || [], ", ")}"
        end

      Enum.join(lines ++ [verdict], "\n")
    end)
  end

  defp dispatch(["sync" | _], _opts), do: {:error, "usage: orbitorc sync <revision> <project> [--box NAME | --all]"}

  defp dispatch(["lease", action | _], opts) do
    with {:ok, box} <- box!(opts) do
      post("/api/box/#{box}/lease", %{"action" => action, "ttl_ms" => ttl(opts)}, opts)
      |> show(opts, fn
        ttl when is_integer(ttl) and action in ["claim", "renew"] -> "#{box} is yours for #{div(ttl, 1000)}s as #{caller(opts)}"
        _ when action == "release" -> "released #{box}"
        other -> pretty(other)
      end)
    end
  end

  defp dispatch(["launch", project, mode | _], opts) do
    body = launch_body(project, mode, opts)
    fan_out(opts, {:capability, "launch.#{project}.#{mode}", !!opts[:headless]}, fn box ->
      post("/api/box/#{box}/launch", body, opts)
    end)
    |> show_each(opts, fn %{"id" => id, "job" => job} ->
      "job #{id}  pid #{job["os_pid"]}  #{if job["marker"], do: "ready when the log shows #{inspect(job["marker"])}", else: "no marker declared"}"
    end)
  end

  defp dispatch(["dry-run", project, mode | _], opts) do
    body = launch_body(project, mode, opts)
    fan_out(opts, {:capability, "launch.#{project}.#{mode}", true}, fn box ->
      post("/api/box/#{box}/dry-run", body, opts)
    end)
    |> show_each(opts, fn %{"argv" => argv} = v ->
      [
        "would run, in #{v["cwd"]}:",
        "  " <> Enum.map_join(argv, " ", &shell_quote/1),
        if(v["marker"], do: "ready when the log shows: #{inspect(v["marker"])}", else: "no marker declared"),
        if(map_size(v["env"] || %{}) > 0, do: "env: " <> Enum.map_join(v["env"], " ", fn {k, val} -> "#{k}=#{val}" end))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end)
  end

  defp dispatch(["status" | _], opts) do
    with {:ok, box} <- box!(opts) do
      get("/api/box/#{box}/status", %{}, opts)
      |> show(opts, fn %{"jobs" => jobs, "lease" => lease} ->
        held = if lease["held"], do: "#{lease["holder"]}, #{div(lease["remaining_ms"] || 0, 1000)}s left", else: "free"
        rows = Enum.map(jobs, fn j -> "  job #{j["id"]}  #{j["project"]}/#{j["mode"]}  #{j["caller"]}  #{ready_line(j)}" end)
        Enum.join(["lease: #{held}" | if(rows == [], do: ["  nothing running"], else: rows)], "\n")
      end)
    end
  end

  defp dispatch(["logs", id | _], opts) do
    with {:ok, box} <- box!(opts) do
      query = %{"tail" => opts[:tail] || 100, "grep" => opts[:grep]}

      if opts[:follow] do
        follow_logs("/api/box/#{box}/jobs/#{id}/logs/stream", query, opts)
      else
        get("/api/box/#{box}/jobs/#{id}/logs", query, opts) |> show(opts, &Enum.join(&1, "\n"))
      end
    end
  end

  defp dispatch(["stop", id | _], opts) when id != "--all" do
    with {:ok, box} <- box!(opts) do
      post("/api/box/#{box}/stop", %{"id" => String.to_integer(id)}, opts) |> show(opts, fn _ -> "stopped job #{id} on #{box}" end)
    end
  end

  defp dispatch(["stop" | _], opts) do
    body = %{"all" => true} |> put_if(opts[:force], "force", true)

    fan_out(opts, :every_box, fn box -> post("/api/box/#{box}/stop", body, opts) end)
    |> show_each(opts, fn %{"stopped" => ids} -> "stopped #{length(ids)} job(s): #{Enum.join(ids, ", ")}" end)
  end

  defp dispatch(["build", project, target | _], opts) do
    fan_out(opts, {:capability, "export.#{target}", false}, fn box ->
      post("/api/box/#{box}/build", %{"project" => project, "target" => target}, opts)
    end)
    |> show_each(opts, fn v ->
      if v["ok"] == false, do: "BUILD REFUSED: #{v["detail"]}", else: "artifacts: " <> Enum.map_join(v["artifacts"] || %{}, ", ", fn {n, s} -> "#{n} (#{s} bytes)" end)
    end)
  end

  defp dispatch(["shot", id | _], opts) do
    with {:ok, box} <- box!(opts) do
      post("/api/box/#{box}/jobs/#{id}/shot", %{"window" => opts[:window]}, opts)
      |> show(opts, fn %{"path" => path, "bytes" => bytes} -> "captured #{path} (#{bytes} bytes); pull it with: orbitorc pull #{id} --box #{box} --file shot.png" end)
    end
  end

  defp dispatch(["pull", id | _], opts) do
    with {:ok, box} <- box!(opts) do
      file = opts[:file] || "metrics.csv"

      case request(:get, "/api/box/#{box}/jobs/#{id}/pull", %{"file" => file}, opts) do
        {:ok, %{"base64" => encoded, "file" => name, "bytes" => bytes}} ->
          dir = opts[:out] || "."
          File.mkdir_p!(dir)
          path = Path.join(dir, name)
          File.write!(path, Base.decode64!(encoded))
          out("wrote #{path} (#{bytes} bytes)")
          :ok

        other ->
          show(other, opts)
      end
    end
  end

  defp dispatch(["verdict", id, project | _], opts) do
    with {:ok, box} <- box!(opts) do
      get("/api/box/#{box}/jobs/#{id}/verdict", %{"project" => project}, opts)
      |> show(opts, fn v -> "#{v["verdict"]} — #{v["detail"]}" end)
    end
  end

  defp dispatch(["run", project | _], opts) do
    body =
      %{"project" => project}
      |> put_if(opts[:measure], "measure_s", opts[:measure])
      |> put_if(opts[:link], "link_mode", opts[:link])
      |> put_if(opts[:load_per_box], "load_per_box", opts[:load_per_box])
      |> put_if(opts[:seed], "seed", opts[:seed])
      |> put_if(opts[:authority_box], "authority_box", opts[:authority_box])
      |> put_if(opts[:allow_colocated], "allow_colocated", true)
      |> then(fn b ->
        case Keyword.get_values(opts, :load_box) do
          [] -> b
          boxes -> Map.put(b, "load_boxes", boxes)
        end
      end)
      |> Map.put("params", params(opts))

    wait? = opts[:wait] == true

    case request(:post, "/api/run", body, opts) do
      {:ok, %{"id" => id}} when wait? -> follow(id, opts)
      other -> show(other, opts, fn %{"id" => id} -> "run #{id} started; follow it with: orbitorc run-status #{id}" end)
    end
  end

  defp dispatch(["upgrade", release | _], opts) do
    body = %{"release" => release} |> put_if(opts[:sha256], "sha256", opts[:sha256])

    fan_out(opts, :every_box, fn box -> post("/api/box/#{box}/upgrade", body, opts) end)
    |> show_each(opts, fn v -> "#{v["version"]} staged (swap #{v["swap"]}); #{v["restart"]}" end)
  end

  defp dispatch(["upgrade" | _], _opts),
    do: {:error, "usage: orbitorc upgrade <tag or URL> [--box NAME | --all] [--sha256 HEX]"}

  defp dispatch(["runs" | _], opts) do
    get("/api/runs", %{}, opts)
    |> show(opts, fn %{"runs" => runs} ->
      if runs == [],
        do: "no run yet",
        else: Enum.map_join(runs, "\n", fn r -> "  #{r["id"]}  #{r["phase"]}  #{r["project"]}  authority #{get_in(r, ["authority", "box"]) || "—"}  load #{length(r["load"] || [])}" end)
    end)
  end

  defp dispatch(["run-status", id | _], opts) do
    get("/api/run/#{id}", %{}, opts) |> show(opts, &run_block/1)
  end

  defp dispatch(_, _opts), do: {:error, "usage: orbitorc <verb> [args] [options]\n\n" <> @moduledoc}

  # --- fan-out --------------------------------------------------------------------------------------

  # One box, or every box that can serve the verb. A fan-out returns `{:many, [{box, result}]}`.
  defp fan_out(opts, selector, call) do
    cond do
      opts[:box] -> call.(opts[:box])
      opts[:all] ->
        case boxes_for(selector, opts) do
          {:ok, []} -> {:error, "no connected box can serve this"}
          {:ok, boxes} -> {:many, boxes |> Task.async_stream(fn b -> {b, call.(b)} end, timeout: 960_000, ordered: true) |> Enum.map(fn {:ok, r} -> r end)}
          {:error, _} = e -> e
        end
      true -> {:error, "this verb needs --box NAME or --all (orbitorc doctor lists what is connected)"}
    end
  end

  defp boxes_for(:every_box, opts) do
    with {:ok, %{"boxes" => boxes}} <- request(:get, "/api/fleet", %{}, opts), do: {:ok, Enum.map(boxes, & &1["name"])}
  end

  # A headless launch waives the session requirement, which is the same door a bot fleet goes through:
  # the box must report the capability key, even as false.
  defp boxes_for({:capability, name, headless}, opts) do
    with {:ok, %{"boxes" => boxes}} <- request(:get, "/api/fleet", %{}, opts) do
      {:ok,
       boxes
       |> Enum.filter(fn b ->
         caps = b["capabilities"] || %{}
         caps[name] == true or (headless and Map.has_key?(caps, name))
       end)
       |> Enum.map(& &1["name"])}
    end
  end

  # --- log following --------------------------------------------------------------------------------

  # The control plane streams the tail and then every line the box forwards, as server-sent events,
  # until the job exits. Each `data:` line is one log line; an `end` event closes the stream.
  defp follow_logs(path, query, opts) do
    url = (opts[:url] || System.get_env("ORBITORC_URL") || @default_url) <> path
    query = query |> Map.put("caller", caller(opts)) |> Map.reject(fn {_, v} -> is_nil(v) end)

    case Req.get(url, params: query, into: :self, receive_timeout: :infinity, retry: false) do
      {:ok, %{status: 200} = resp} ->
        # A control plane that goes away mid-stream closes the connection; that is the end of the
        # follow, said plainly, not a crash.
        try do
          resp.body
          |> Enum.reduce_while("", fn chunk, buffer -> consume(buffer <> chunk) end)
          |> then(fn _ -> :ok end)
        rescue
          e -> {:error, "the stream ended: #{Exception.message(e)}"}
        end

      {:ok, %{status: status, body: body}} ->
        body = if is_struct(body), do: Enum.join(body), else: inspect(body)
        {:error, "the control plane answered #{status}: #{body}"}

      {:error, reason} ->
        {:error, "could not reach #{url}: #{Exception.message(reason)}"}
    end
  end

  # Complete events are printed; a partial one waits for the next chunk.
  defp consume(buffer) do
    case String.split(buffer, "\n\n") do
      [partial] ->
        {:cont, partial}

      events ->
        {complete, [partial]} = Enum.split(events, -1)

        Enum.reduce_while(complete, {:cont, partial}, fn event, acc ->
          lines = String.split(event, "\n")
          data = lines |> Enum.filter(&String.starts_with?(&1, "data: ")) |> Enum.map(&String.replace_prefix(&1, "data: ", ""))

          if "event: end" in lines do
            {:halt, {:halt, ""}}
          else
            Enum.each(data, &out/1)
            {:cont, acc}
          end
        end)
    end
  end

  # --- run following --------------------------------------------------------------------------------

  defp follow(id, opts) do
    out("run #{id}")
    follow(id, opts, 0)
  end

  defp follow(id, opts, seen) do
    case request(:get, "/api/run/#{id}", %{}, opts) do
      {:ok, snap} ->
        timeline = snap["timeline"] || []
        timeline |> Enum.drop(seen) |> Enum.each(fn e -> out("  #{pad_ms(e["at"])}  #{e["phase"]}  #{e["line"]}") end)

        case snap["phase"] do
          "done" ->
            Enum.each(snap["verdicts"] || [], fn v -> out("  verdict  #{v["box"]} job #{v["job"]}: #{v["verdict"]} — #{v["detail"]}") end)
            :ok

          "failed" ->
            {:error, "failed: #{snap["failure"]}"}

          _ ->
            Process.sleep(2_000)
            follow(id, opts, length(timeline))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_block(snap) do
    lines =
      ["#{snap["id"]}  #{snap["phase"]}  #{snap["project"]}#{if snap["failure"], do: "  FAILED: #{snap["failure"]}", else: ""}"] ++
        Enum.map(snap["timeline"] || [], fn e -> "  #{pad_ms(e["at"])}  #{e["phase"]}  #{e["line"]}" end) ++
        Enum.map(snap["verdicts"] || [], fn v -> "  verdict  #{v["box"]} job #{v["job"]}: #{v["verdict"]} — #{v["detail"]}" end)

    Enum.join(lines, "\n")
  end

  # --- transport ------------------------------------------------------------------------------------

  defp get(path, query, opts), do: request(:get, path, query, opts)
  defp post(path, body, opts), do: request(:post, path, body, opts)

  defp request(method, path, payload, opts) do
    url = (opts[:url] || System.get_env("ORBITORC_URL") || @default_url) <> path
    payload = payload |> Map.put("caller", caller(opts)) |> Map.reject(fn {_, v} -> is_nil(v) end)

    result =
      case method do
        :get -> Req.get(url, params: payload, receive_timeout: 960_000, retry: false)
        :post -> Req.post(url, json: payload, receive_timeout: 960_000, retry: false)
      end

    case result do
      {:ok, %{body: %{"ok" => true, "value" => value}}} -> {:ok, value}
      {:ok, %{body: %{"ok" => false, "error" => reason}}} -> {:error, reason}
      {:ok, %{status: status, body: body}} -> {:error, "the control plane answered #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, "could not reach #{url}: #{Exception.message(reason)}"}
    end
  end

  # --- rendering ------------------------------------------------------------------------------------

  defp show(result, opts, render \\ &pretty/1)

  defp show({:ok, value}, opts, render) do
    out(if opts[:json], do: Jason.encode!(value, pretty: true), else: render.(value))
    :ok
  end

  defp show({:error, reason}, _opts, _render), do: {:error, reason}

  defp show_each({:many, results}, opts, render) do
    if opts[:json] do
      out(Jason.encode!(Map.new(results, fn {box, r} -> {box, encode(r)} end), pretty: true))
    else
      Enum.each(results, fn
        {box, {:ok, v}} -> out("#{box}\n" <> indent(render.(v)))
        {box, {:error, reason}} -> out("#{box}\n  REFUSED: #{reason}")
      end)
    end

    failed = Enum.count(results, &match?({_, {:error, _}}, &1))
    if failed == 0, do: :ok, else: {:error, "#{failed} of #{length(results)} box(es) refused"}
  end

  defp show_each(single, opts, render), do: show(single, opts, render)

  defp report(:ok, _json?), do: :ok

  defp report({:error, reason}, _json?) do
    IO.puts(:stderr, reason)
    {:error, reason}
  end

  defp out(text), do: IO.puts(text)
  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  defp pretty(value) when is_binary(value), do: value
  defp pretty(value), do: Jason.encode!(value, pretty: true)
  defp encode({:ok, v}), do: %{"ok" => true, "value" => v}
  defp encode({:error, r}), do: %{"ok" => false, "error" => r}

  defp fleet_block(%{"boxes" => []}), do: "no box is connected. An agent dials out to the control plane; start one and it appears here."

  defp fleet_block(%{"boxes" => boxes}) do
    Enum.map_join(boxes, "\n", fn box ->
      projects =
        box["projects"]
        |> Enum.sort()
        |> Enum.map_join("\n", fn {name, report} -> "      #{name}  #{short_sha(report)}#{flags(report)}" end)

      problems = if (box["problems"] || []) == [], do: "", else: "\n    problems " <> Enum.join(box["problems"], "; ")
      "  #{box["name"]}  #{box["platform"]}#{if box["arch"], do: "/#{box["arch"]}", else: ""}#{if box["version"], do: "  agent #{box["version"]}", else: ""}#{if box["session_ok"], do: "", else: "  [no graphical session]"}\n    lan     #{box["lan"] || "—"}\n    session #{box["session"]}\n#{projects}#{problems}"
    end)
  end

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
      if(get_in(report, ["requires", "ok"]) == false, do: " missing-deps"),
      if(get_in(report, ["pinned", "ok"]) == false, do: " stale-backend")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp ready_line(%{"ready" => true, "ready_ms" => ms}) when is_integer(ms), do: "ready in #{ms} ms"
  defp ready_line(%{"ready" => true}), do: "ready"
  defp ready_line(%{"marker" => nil}), do: "no marker declared"
  defp ready_line(_), do: "waiting for its marker"

  defp pad_ms(ms) when is_integer(ms), do: String.pad_leading("#{div(ms, 1000)}.#{rem(div(ms, 100), 10)}s", 7)
  defp pad_ms(_), do: "      ?"

  defp shell_quote(arg), do: if(arg =~ ~r/[\s"'$]/, do: "'" <> String.replace(arg, "'", "'\\''") <> "'", else: arg)

  # --- options --------------------------------------------------------------------------------------

  defp launch_body(project, mode, opts) do
    %{
      "project" => project,
      "mode" => mode,
      "params" => params(opts),
      "extra" => Keyword.get(opts, :extra, []),
      "headless" => !!opts[:headless]
    }
  end

  defp box!(opts) do
    case opts[:box] do
      nil -> {:error, "this verb needs --box NAME (orbitorc doctor lists what is connected)"}
      box -> {:ok, box}
    end
  end

  defp caller(opts) do
    opts[:caller] || System.get_env("ORBITORC_CALLER") || "#{System.get_env("USER") || "unknown"}@#{hostname()}"
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
