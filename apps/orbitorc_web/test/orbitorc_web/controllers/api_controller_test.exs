defmodule OrbitorcWeb.ApiControllerTest do
  use OrbitorcWeb.ConnCase, async: false

  test "every endpoint answers one envelope: the fleet, empty", %{conn: conn} do
    conn = get(conn, ~p"/api/fleet")
    assert %{"ok" => true, "value" => %{"boxes" => []}} = json_response(conn, 200)
  end

  test "a verb against a box that is not connected says so", %{conn: conn} do
    conn = get(conn, ~p"/api/box/ghost/status")
    assert %{"ok" => false, "error" => "ghost is not connected"} = json_response(conn, 422)
  end

  test "A MUTATION WITHOUT A CALLER IS REFUSED, because the lease and the audit log need one", %{
    conn: conn
  } do
    conn = post(conn, ~p"/api/box/ghost/launch", %{"project" => "demo", "mode" => "server"})
    assert %{"ok" => false, "error" => error} = json_response(conn, 400)
    assert error =~ "needs a caller"
  end

  test "a run with nobody connected fails at placement, and its record says why", %{conn: conn} do
    conn = post(conn, ~p"/api/run", %{"project" => "demo", "caller" => "t"})

    assert %{"ok" => true, "value" => %{"id" => id, "phase" => "placing"}} =
             json_response(conn, 200)

    Process.sleep(200)
    conn = get(build_conn(), ~p"/api/run/#{id}")

    assert %{"ok" => true, "value" => %{"phase" => "failed", "failure" => failure}} =
             json_response(conn, 200)

    assert failure =~ "no connected box"
  end

  test "an unknown run is a 404", %{conn: conn} do
    conn = get(conn, ~p"/api/run/nope")
    assert %{"ok" => false} = json_response(conn, 404)
  end

  test "the run list answers, live first then history", %{conn: conn} do
    conn = get(conn, ~p"/api/runs")
    assert %{"ok" => true, "value" => %{"runs" => runs}} = json_response(conn, 200)
    assert is_list(runs)
  end
end
