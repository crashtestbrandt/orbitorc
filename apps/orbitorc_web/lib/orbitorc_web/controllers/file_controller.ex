defmodule OrbitorcWeb.FileController do
  @moduledoc """
  A job's artifact as a browser download.

  `pull` over the API answers base64 in the envelope, which is what the command line writes to disk.
  A browser wants the bytes with a filename, so this runs the same verb and sends them as an attachment.
  """

  use OrbitorcWeb, :controller

  alias OrbitorcWeb.Verbs

  def pull(conn, %{"name" => box, "id" => id} = params) do
    payload = %{"box" => box, "id" => id, "file" => Map.get(params, "file", "metrics.csv")}

    case Verbs.run("pull", payload, conn.assigns[:caller]) do
      {:ok, %{"base64" => encoded, "file" => file}} ->
        send_download(conn, {:binary, Base.decode64!(encoded)}, filename: Path.basename(file))

      {:error, {status, reason}} ->
        conn |> put_status(status) |> text(reason)

      {:error, reason} ->
        conn |> put_status(422) |> text(to_string(reason))
    end
  end
end
