defmodule OrbitorcWeb.FakeBox do
  @moduledoc """
  A box for the dashboard's tests: joins the fleet as the channel would and answers every verb the way
  an agent does, without a socket. The test process receives one message per verb the box was asked.
  """

  alias Orbitorc.{Fleet, Request}

  @report %{
    "platform" => "linux",
    "arch" => "x64",
    "agent_version" => "0.1.0",
    "session_ok" => true,
    "session_detail" => "a display is present",
    "lan" => "10.0.0.5",
    "game_port" => 47_900,
    "relay_port" => 47_910,
    "exports" => ["linux"],
    "capabilities" => %{
      "launch.demo.server" => true,
      "launch.demo.bench" => true,
      "launch.demo.scene" => true,
      "export.linux" => true,
      "export.windows" => false,
      "shot" => true,
      "git" => true,
      "just" => true
    },
    "projects" => %{
      "demo" => %{
        "repo" => "/boxes/demo",
        "engine_bin" => "godot",
        "engine" => %{"ok" => true, "version" => "4.7"},
        "revision" => %{
          "ok" => true,
          "sha" => "abcdef0123456789",
          "branch" => "main",
          "dirty" => false
        },
        "manifest" => %{
          "ok" => true,
          "project" => "demo",
          "modes" => ["bench", "scene", "server"],
          "params" => %{
            "server" => %{
              "defaults" => %{"port" => 47_900},
              "required" => [],
              "gui" => false,
              "scene" => false,
              "ready" => "STATE PLAYING"
            },
            "bench" => %{
              "defaults" => %{"duration" => 30},
              "required" => ["join"],
              "gui" => true,
              "scene" => false,
              "ready" => "STATE PLAYING"
            },
            "scene" => %{
              "defaults" => %{},
              "required" => [],
              "gui" => true,
              "scene" => true,
              "ready" => nil
            }
          }
        },
        "import" => %{"ok" => true, "detail" => "fresh"},
        "requires" => %{"ok" => true, "detail" => "nothing declared"},
        "pinned" => %{"ok" => true, "detail" => "no pinned backend"}
      }
    },
    "problems" => []
  }

  def report, do: @report

  @doc "Join as `name`; the box process answers until `leave/1`."
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
    report = Map.merge(@report, Keyword.get(opts, :report, %{}))
    :ok = Fleet.join(name, report)
    send(test, {:fake_joined, name})
    loop(name, %{next: 1, jobs: %{}, lease: nil}, test)
  end

  defp loop(name, state, test) do
    receive do
      :leave ->
        exit(:normal)

      {:ask, verb, %{"ref" => ref} = payload} ->
        send(test, {:asked, name, verb, Map.delete(payload, "ref")})
        {result, state} = answer(name, verb, payload, state)
        Request.resolve(ref, result)
        loop(name, state, test)
    end
  end

  defp answer(_name, "doctor", _payload, state), do: {{:ok, @report}, state}

  defp answer(_name, "lease", %{"action" => "release"}, state),
    do: {{:ok, %{}}, %{state | lease: nil}}

  defp answer(_name, "lease", %{"caller" => caller}, state),
    do: {{:ok, 900_000}, %{state | lease: caller}}

  defp answer(_name, "status", _payload, state) do
    lease =
      case state.lease do
        nil -> %{"held" => false}
        holder -> %{"held" => true, "holder" => holder, "remaining_ms" => 900_000}
      end

    {{:ok, %{"jobs" => state.jobs |> Map.values() |> Enum.sort_by(& &1["id"]), "lease" => lease}},
     state}
  end

  defp answer(_name, "launch", %{"dry" => true} = p, state) do
    argv = ["godot", "--path", "/boxes/demo", "--", "--mode=#{p["mode"]}"] ++ (p["extra"] || [])

    {{:ok,
      %{
        "dry" => true,
        "argv" => argv,
        "cwd" => "/boxes/demo",
        "marker" => "STATE PLAYING",
        "env" => %{}
      }}, state}
  end

  defp answer(_name, "launch", %{"mode" => mode}, %{lease: nil} = state) when mode != "scene",
    do: {{:error, "this verb needs the lease; claim it first"}, state}

  defp answer(name, "launch", p, state) do
    id = state.next

    job = %{
      "id" => id,
      "project" => p["project"],
      "mode" => p["mode"],
      "caller" => p["caller"],
      "marker" => "STATE PLAYING",
      "ready" => false,
      "params" => p["params"],
      "extra" => p["extra"]
    }

    Phoenix.PubSub.broadcast(
      Orbitorc.PubSub,
      "box:#{name}:jobs",
      {:job_event, name, id, "started", %{}}
    )

    {{:ok, %{"id" => id, "job" => job}},
     %{state | next: id + 1, jobs: Map.put(state.jobs, id, job)}}
  end

  defp answer(_name, "logs", %{"id" => id} = p, state) do
    lines = ["job #{id} line 1", "STATE PLAYING", "net_peer 2 joined"]

    lines =
      if p["grep"],
        do: Enum.filter(lines, &Regex.match?(Regex.compile!(p["grep"]), &1)),
        else: lines

    {{:ok, lines}, state}
  end

  defp answer(name, "stop", %{"id" => id}, state) when is_integer(id) do
    Phoenix.PubSub.broadcast(
      Orbitorc.PubSub,
      "box:#{name}:jobs",
      {:job_event, name, id, "exited", %{"status" => "reaped"}}
    )

    {{:ok, %{"stopped" => [id]}}, %{state | jobs: Map.delete(state.jobs, id)}}
  end

  defp answer(_name, "stop", _p, state),
    do: {{:ok, %{"stopped" => Map.keys(state.jobs)}}, %{state | jobs: %{}}}

  defp answer(_name, "build", p, state),
    do: {{:ok, %{"artifacts" => %{"#{p["target"]}-build" => 40_000_000}}}, state}

  defp answer(_name, "shot", %{"id" => id}, state),
    do: {{:ok, %{"path" => "/jobs/#{id}/shot.png", "bytes" => 68}}, state}

  # A 1x1 PNG, so the page has an image to show.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
       )

  defp answer(_name, "pull", %{"file" => "shot.png"}, state),
    do:
      {{:ok,
        %{"file" => "shot.png", "bytes" => byte_size(@png), "base64" => Base.encode64(@png)}},
       state}

  defp answer(_name, "pull", %{"file" => file}, state) do
    body = "t,x\n1,2\n"
    {{:ok, %{"file" => file, "bytes" => byte_size(body), "base64" => Base.encode64(body)}}, state}
  end

  defp answer(_name, "verdict", _p, state),
    do: {{:ok, %{"verdict" => "measured", "detail" => "2 columns moved"}}, state}

  defp answer(_name, "sync", %{"revision" => rev}, state),
    do:
      {{:ok, %{"sha" => "feedfacefeedface", "branch" => "HEAD", "log" => "checked out #{rev}"}},
       state}

  defp answer(_name, "upgrade", %{"url" => url}, state),
    do:
      {{:ok, %{"version" => "0.2.0", "url" => url, "swap" => "done", "restart" => "pending"}},
       state}

  defp answer(_name, verb, _p, state), do: {{:error, "fake box does not serve #{verb}"}, state}
end
