defmodule Orbitorc.CLITargetsTest do
  @moduledoc """
  Which boxes a verb reaches, against a stand-in control plane over real HTTP.

  `sync main orbitnet --box win --box happytop` once synced happytop alone and reported "every box
  agrees", because `--box` kept only its last value. `doctor --all` once answered from the fleet's
  cache, so a box that had just been re-imported still read as stale.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule Plane do
    @moduledoc "Records every request and answers what the command line expects."
    use Plug.Router

    plug Plug.Parsers, parsers: [:json], json_decoder: Jason
    plug :match
    plug :dispatch

    get "/api/fleet" do
      record(conn)
      reply(conn, %{"boxes" => Enum.map(~w(a b c), &%{"name" => &1, "projects" => %{}, "session_ok" => true})})
    end

    get "/api/box/:box/doctor" do
      record(conn)
      reply(conn, %{"name" => box, "fresh" => true})
    end

    post "/api/sync" do
      record(conn)
      boxes = conn.body_params["boxes"] || ["a", "b", "c"]
      synced = Map.new(boxes, &{&1, %{"sha" => "0123456789", "branch" => "HEAD"}})
      reply(conn, %{"synced" => synced, "failed" => %{}, "agreed" => true, "revisions" => ["0123456789"]})
    end

    post "/api/box/:box/lease" do
      record(conn)
      reply(conn, 900_000)
    end

    post "/api/box/:box/upgrade" do
      record(conn)
      reply(conn, %{"version" => "9.9.9", "swap" => "done", "restart" => "restarted"})
    end

    defp record(conn) do
      Agent.update(__MODULE__.Log, &[{conn.method, conn.request_path, conn.body_params} | &1])
    end

    defp reply(conn, value) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"ok" => true, "value" => value}))
    end
  end

  setup do
    start_supervised!(%{id: :log, start: {Agent, :start_link, [fn -> [] end, [name: Plane.Log]]}})
    server = start_supervised!({Bandit, plug: Plane, ip: {127, 0, 0, 1}, port: 0, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, url: "http://127.0.0.1:#{port}"}
  end

  test "SYNC TAKES EVERY --box NAMED, not the last", ctx do
    out = run!(["sync", "main", "orbitnet", "--box", "a", "--box", "b"], ctx)

    assert [{"POST", "/api/sync", %{"boxes" => ["a", "b"]}}] = requests()
    assert out =~ "  a  01234567"
    assert out =~ "  b  01234567"
  end

  test "A FAN-OUT VERB REACHES EVERY --box NAMED", ctx do
    run!(["upgrade", "v9.9.9", "--box", "a", "--box", "c"], ctx)
    assert paths() == ["/api/box/a/upgrade", "/api/box/c/upgrade"]
  end

  test "A ONE-BOX VERB REFUSES A SECOND --box rather than keeping the last", ctx do
    assert {:error, reason} = run(["lease", "claim", "--box", "a", "--box", "b"], ctx)
    assert reason =~ "acts on one box"
    assert requests() == []
  end

  test "DOCTOR --all ASKS EVERY BOX FRESH, not the fleet's cache", ctx do
    out = run!(["doctor", "--all"], ctx)

    assert paths() == ["/api/box/a/doctor", "/api/box/b/doctor", "/api/box/c/doctor", "/api/fleet"]
    assert out =~ "fresh"
  end

  test "DOCTOR WITH NAMED BOXES asks each of them fresh", ctx do
    run!(["doctor", "--box", "b", "--box", "c"], ctx)
    assert paths() == ["/api/box/b/doctor", "/api/box/c/doctor"]
  end

  test "A BARE DOCTOR is still the fleet's cache, in one request", ctx do
    run!(["doctor"], ctx)
    assert paths() == ["/api/fleet"]
  end

  defp run(argv, ctx) do
    capture_io(:stderr, fn -> send(self(), {:result, Orbitorc.CLI.run(argv ++ ["--url", ctx.url, "--caller", "t"])}) end)
    assert_received {:result, result}
    result
  end

  defp run!(argv, ctx) do
    capture_io(fn -> assert :ok = run(argv, ctx) end)
  end

  defp requests, do: Agent.get(Plane.Log, &Enum.reverse/1)
  defp paths, do: requests() |> Enum.map(&elem(&1, 1)) |> Enum.sort()
end
