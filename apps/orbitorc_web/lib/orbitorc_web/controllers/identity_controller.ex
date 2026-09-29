defmodule OrbitorcWeb.IdentityController do
  @moduledoc "Sets or clears the name the dashboard acts as. A form post from the header; nothing else."

  use OrbitorcWeb, :controller

  alias OrbitorcWeb.Identity

  def update(conn, params) do
    name = params |> Map.get("caller", "") |> to_string() |> String.trim()

    conn =
      if name == "",
        do: delete_session(conn, Identity.key()),
        else: put_session(conn, Identity.key(), name)

    redirect(conn, to: local_path(Map.get(params, "return_to")))
  end

  # Only a path on this host; a redirect target that came from a form field is not trusted further.
  defp local_path("/" <> rest = path) when binary_part(rest, 0, min(1, byte_size(rest))) != "/",
    do: path

  defp local_path(_), do: "/"
end
