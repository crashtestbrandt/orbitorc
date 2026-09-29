defmodule OrbitorcWeb.ApiController do
  @moduledoc """
  The JSON surface the command line drives.

  ## One action, every verb

  Every route's action name is the verb it runs (`run_status` is `run-status`), and the one action
  hands the request's params to `OrbitorcWeb.Verbs`, which is also what the dashboard's pages call.
  Nothing here decides what a verb means; this is the HTTP mapping and the envelope.

  ## Every answer is one envelope

  `ok` plus `value`, or `ok: false` plus `error`, so a client has one shape to read rather than one
  per verb. A verb that needs a caller and has none is a 400; an unknown run is a 404; a box's refusal
  is a 422.

  ## A log stream is the one exception

  `logs_stream` is not a verb: it is `logs`, then every line the box forwards until the job exits, as
  server-sent events. It exists so `orbitorc logs --follow` can watch a job the way the dashboard does.
  """

  use OrbitorcWeb, :controller

  alias OrbitorcWeb.Verbs

  def action(conn, _opts) do
    case action_name(conn) do
      :logs_stream -> logs_stream(conn, conn.params)
      name -> verb(conn, name |> Atom.to_string() |> String.replace("_", "-"))
    end
  end

  defp verb(conn, verb) do
    case Verbs.run(verb, conn.params, conn.params["caller"]) do
      {:ok, value} -> json(conn, %{"ok" => true, "value" => value})
      {:error, {status, reason}} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  # --- the log stream -------------------------------------------------------------------------------

  @keepalive_ms 15_000

  defp logs_stream(conn, %{"box" => box, "id" => id} = params) do
    caller = params["caller"]
    job = to_int(id)

    # Subscribe before reading the tail, so a line that lands between the two is repeated rather than
    # lost.
    Phoenix.PubSub.subscribe(Orbitorc.PubSub, "box:#{box}:job:#{job}")
    Phoenix.PubSub.subscribe(Orbitorc.PubSub, "box:#{box}:jobs")

    with {:ok, lines} <- Verbs.run("logs", params, caller),
         {:ok, %{"jobs" => jobs}} <- Verbs.run("status", params, caller) do
      alive = Enum.any?(jobs, &(&1["id"] == job))
      grep = compile(params["grep"])

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      case Enum.reduce_while(lines, {:ok, conn}, fn line, {:ok, conn} -> event(conn, line) end) do
        {:ok, conn} when alive -> stream(conn, box, job, grep)
        {:ok, conn} -> finish(conn, "the job has already exited")
        {:error, _closed, conn} -> conn
      end
    else
      {:error, {status, reason}} -> error(conn, status, reason)
      {:error, reason} -> error(conn, 422, reason)
    end
  end

  defp stream(conn, box, job, grep) do
    receive do
      {:log_line, ^box, ^job, line} ->
        if matches?(line, grep) do
          case event(conn, line) do
            {:cont, {:ok, conn}} -> stream(conn, box, job, grep)
            {:halt, {:error, _closed, conn}} -> conn
          end
        else
          stream(conn, box, job, grep)
        end

      {:job_event, ^box, ^job, "exited", detail} ->
        finish(conn, "exited #{Map.get(detail, "status")}")

      _other ->
        stream(conn, box, job, grep)
    after
      @keepalive_ms ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> stream(conn, box, job, grep)
          {:error, _} -> conn
        end
    end
  end

  # One line is one event. `data:` lines are what every SSE reader hands back; the end is its own event.
  defp event(conn, line) do
    case chunk(conn, "data: #{line}\n\n") do
      {:ok, conn} -> {:cont, {:ok, conn}}
      {:error, reason} -> {:halt, {:error, reason, conn}}
    end
  end

  defp finish(conn, why) do
    case chunk(conn, "event: end\ndata: #{why}\n\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp compile(nil), do: nil
  defp compile(""), do: nil

  defp compile(source) do
    case Regex.compile(source) do
      {:ok, rx} -> rx
      {:error, _} -> nil
    end
  end

  defp matches?(_line, nil), do: true
  defp matches?(line, rx), do: Regex.match?(rx, line)

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp error(conn, status, reason) do
    conn |> put_status(status) |> json(%{"ok" => false, "error" => to_string(reason)})
  end
end
