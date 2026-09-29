defmodule OrbitorcWeb.LogsStreamTest do
  @moduledoc "The event stream `orbitorc logs --follow` reads: the tail, then live lines, then an end."
  use OrbitorcWeb.ConnCase, async: false

  alias OrbitorcWeb.FakeBox

  setup do
    pid = FakeBox.start("alpha")
    on_exit(fn -> FakeBox.leave(pid) end)
    :ok
  end

  test "a finished job's stream is its tail and an end", %{conn: conn} do
    conn = get(conn, ~p"/api/box/alpha/jobs/9/logs/stream?tail=10")
    assert conn.state == :chunked
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"
    assert conn.resp_body =~ "data: STATE PLAYING\n\n"
    assert conn.resp_body =~ "event: end\n"
  end

  test "a box that is not connected is a 422, not a stream", %{conn: conn} do
    conn = get(conn, ~p"/api/box/ghost/jobs/1/logs/stream")
    assert %{"ok" => false} = json_response(conn, 422)
  end
end
