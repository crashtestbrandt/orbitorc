defmodule OrbitorcWeb.Identity do
  @moduledoc """
  Who is clicking.

  The command line names its caller on every request; the lease arbitrates between callers and the
  audit log attributes to them. A browser has no such name unless it is given one, so the dashboard
  keeps one in the session: set once from the header, sent with every mutating verb a page runs, and
  refused-for-mutation while unset in exactly the way the API refuses an anonymous mutation.

  The plug puts it on the conn; the `on_mount` puts it on every page's socket, and records the page's
  own path so the header's form can bring the person back to it.
  """

  import Plug.Conn

  @key "caller"

  @doc "The session key the name lives under."
  def key, do: @key

  def init(opts), do: opts

  def call(conn, _opts), do: assign(conn, :caller, get_session(conn, @key))

  def on_mount(:default, _params, session, socket) do
    socket =
      socket
      |> Phoenix.Component.assign(:caller, Map.get(session, @key))
      |> Phoenix.Component.assign(:path, "/")
      |> Phoenix.LiveView.attach_hook(:identity_path, :handle_params, fn _params, uri, socket ->
        {:cont, Phoenix.Component.assign(socket, :path, URI.parse(uri).path || "/")}
      end)

    {:cont, socket}
  end
end
