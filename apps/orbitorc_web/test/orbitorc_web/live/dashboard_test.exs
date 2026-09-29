defmodule OrbitorcWeb.DashboardTest do
  @moduledoc """
  The pages, driven as a browser drives them, against a fake box that answers every verb.

  The one rule every page shares is checked first: without a name in the session, the mutating verbs
  are closed, exactly as the API refuses an anonymous mutation.
  """
  use OrbitorcWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias OrbitorcWeb.FakeBox

  setup %{conn: conn} do
    pid = FakeBox.start("alpha")
    on_exit(fn -> FakeBox.leave(pid) end)
    {:ok, conn: conn, named: Plug.Test.init_test_session(conn, %{"caller" => "tester"})}
  end

  test "the identity form sets the name and returns to the page", %{conn: conn} do
    conn = post(conn, ~p"/identity", %{"caller" => "tester", "return_to" => "/box/alpha"})
    assert redirected_to(conn) == "/box/alpha"
    assert get_session(conn, "caller") == "tester"

    conn =
      post(build_conn(), ~p"/identity", %{"caller" => "x", "return_to" => "https://elsewhere"})

    assert redirected_to(conn) == "/"
  end

  test "WITHOUT A NAME THE MUTATING VERBS ARE CLOSED", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/box/alpha")
    assert html =~ "Set a name above"
    assert has_element?(view, "button[phx-click=lease][disabled]")
    assert has_element?(view, "button[name=intent][value=launch][disabled]")
    # A read still works.
    assert has_element?(view, "button[name=intent][value=dry-run]:not([disabled])")
  end

  test "the fleet page syncs every box and shows the agreement", %{named: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "alpha"

    view
    |> form("#sync-form", %{"project" => "demo", "revision" => "main", "box" => ""})
    |> render_submit()

    assert_receive {:asked, "alpha", "sync", %{"revision" => "main", "caller" => "tester"}}
    assert render_async(view) =~ "every box agrees on feedface"
  end

  test "the fleet page asks a box for a fresh report", %{named: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[phx-click=doctor][phx-value-box=alpha]") |> render_click()
    assert_receive {:asked, "alpha", "doctor", _}
    render_async(view)
  end

  test "the box page: lease, dry run, launch, then the job appears and can be stopped", %{
    named: conn
  } do
    {:ok, view, html} = live(conn, ~p"/box/alpha")
    assert html =~ "STATE PLAYING"

    view |> element("button[phx-click=lease][phx-value-action=claim]") |> render_click()
    assert_receive {:asked, "alpha", "lease", %{"action" => "claim", "caller" => "tester"}}
    assert render_async(view) =~ "yours for 900s"

    # Choosing the mode re-renders the form with that mode's parameters; then the dry run shows the
    # argv, extra arguments in place, and launches nothing.
    view |> form("#launch-form", %{"project" => "demo", "mode" => "server"}) |> render_change()

    view
    |> form("#launch-form", %{
      "project" => "demo",
      "mode" => "server",
      "params" => %{"port" => "47901"},
      "extra" => "--arena=x"
    })
    |> render_submit(%{"intent" => "dry-run"})

    assert_receive {:asked, "alpha", "launch",
                    %{"dry" => true, "params" => %{"port" => 47_901}, "extra" => ["--arena=x"]}}

    assert render_async(view) =~ "--arena=x"
    refute_receive {:asked, "alpha", "launch", %{"dry" => false}}, 50

    view
    |> form("#launch-form", %{"project" => "demo", "mode" => "server"})
    |> render_submit(%{"intent" => "launch"})

    assert_receive {:asked, "alpha", "launch", %{"dry" => false, "mode" => "server"}}
    html = render_async(view)
    assert html =~ "job 1 started"
    assert has_element?(view, "a[href='/box/alpha/job/1']")

    view |> element("button[phx-click=stop][phx-value-id='1']") |> render_click()
    assert_receive {:asked, "alpha", "stop", %{"id" => 1}}
    assert render_async(view) =~ "stopped job 1"
  end

  test "the box page builds and reports the artifact", %{named: conn} do
    {:ok, view, _} = live(conn, ~p"/box/alpha")

    view
    |> form("#build-form", %{"project" => "demo", "target" => "linux"})
    |> render_submit()

    assert_receive {:asked, "alpha", "build", %{"target" => "linux"}}
    assert render_async(view) =~ "linux-build (40000000 bytes)"
  end

  test "the job page: the tail, a live line, a filtered reload, a verdict", %{named: conn} do
    {:ok, view, html} = live(conn, ~p"/box/alpha/job/7")
    assert html =~ "net_peer 2 joined"

    Phoenix.PubSub.broadcast(
      Orbitorc.PubSub,
      "box:alpha:job:7",
      {:log_line, "alpha", 7, "ARENA-STATE PLAYING now"}
    )

    assert render(view) =~ "ARENA-STATE PLAYING now"

    view
    |> form("#logs-form", %{"tail" => "50", "grep" => "net_peer"})
    |> render_submit()

    assert_receive {:asked, "alpha", "logs", %{"grep" => "net_peer", "tail" => 50}}
    refute render(view) =~ "job 7 line 1"

    view |> form("#verdict-form", %{"project" => "demo"}) |> render_submit()
    assert_receive {:asked, "alpha", "verdict", %{"project" => "demo", "id" => 7}}
    assert render_async(view) =~ "measured — 2 columns moved"
  end

  test "a running job's page can capture its window and shows it", %{named: conn} do
    {:ok, box_view, _} = live(conn, ~p"/box/alpha")
    box_view |> element("button[phx-click=lease][phx-value-action=claim]") |> render_click()
    render_async(box_view)

    box_view
    |> form("#launch-form", %{"project" => "demo", "mode" => "server"})
    |> render_submit(%{"intent" => "launch"})

    render_async(box_view)

    {:ok, view, html} = live(conn, ~p"/box/alpha/job/1")
    assert html =~ "running"
    view |> element("button[phx-click=shot]") |> render_click()
    assert_receive {:asked, "alpha", "shot", %{"id" => 1}}
    assert render_async(view) =~ "data:image/png;base64,"
  end

  test "a pulled artifact downloads with its name", %{named: conn} do
    conn = get(conn, ~p"/box/alpha/job/3/pull?file=metrics.csv")
    assert response(conn, 200) == "t,x\n1,2\n"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "metrics.csv"
  end

  test "the runs page starts a run and lands on it", %{named: conn} do
    {:ok, view, _} = live(conn, ~p"/runs")

    view
    |> form("#run-form", %{
      "project" => "demo",
      "measure_s" => "5",
      "load_per_box" => "1",
      "params" => "seed=4\nlabel=x"
    })
    |> render_submit()

    assert {path, _flash} = assert_redirect(view)
    assert path =~ ~r"^/run/"
  end
end
