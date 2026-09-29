defmodule OrbitorcWeb.AgentSocket do
  @moduledoc """
  Where agents connect.

  ## A token per box, not one shared secret

  Each box carries its own token, so every action is attributable to a machine and one box can be
  revoked without rotating the fleet. A shared secret makes the audit log say "somebody" and makes
  revocation an outage.

  ## The token is compared in constant time

  A comparison that returns early on the first differing byte leaks the token's prefix to anyone who can
  time the handshake, and a control plane is reachable by definition. `Plug.Crypto.secure_compare/2` is
  what the comparison goes through.

  ## Authentication is not authorization

  Connecting proves which box this is. It does not decide what the box will do — that is the box's own
  lease, its own capabilities and its own manifest, checked again on arrival. A control plane that has
  been talked into asking for something is not a reason for a box to do it.
  """

  use Phoenix.Socket

  require Logger

  channel "agent", OrbitorcWeb.AgentChannel

  @impl true
  def connect(params, socket, connect_info) do
    with {:ok, presented} <- presented_token(params, connect_info),
         {:ok, box} <- authenticate(presented) do
      {:ok, assign(socket, box: box)}
    else
      {:error, reason} ->
        # Never echo the token, and never say which half was wrong: "no such box" and "wrong token for
        # this box" are the same answer to anyone probing.
        Logger.warning("agent connection refused: #{reason}")
        :error
    end
  end

  @impl true
  def id(socket), do: "agent:#{socket.assigns.box}"

  # A header is preferred: it keeps the credential out of the request line, which is what ends up in
  # proxy logs and terminal history. A query parameter is accepted because some clients cannot set
  # headers on a WebSocket upgrade.
  #
  # **THE HEADER IS `x-orbitorc-token` RATHER THAN `authorization` BECAUSE OF WHAT PHOENIX FORWARDS.**
  # A socket's `connect_info` can request `:x_headers`, and that collects only headers whose name
  # begins with `x-`. An `authorization` header sent on the upgrade is simply not there to read, and
  # the failure is a 403 with nothing logged about why — which reads as a wrong token rather than an
  # unread one. `authorization` is still accepted, for a proxy that rewrites it into the `x-` space.
  defp presented_token(params, connect_info) do
    headers = Map.get(connect_info, :x_headers, [])

    header =
      Enum.find_value(headers, fn
        {"x-orbitorc-token", token} -> token
        {"x-authorization", "Bearer " <> token} -> token
        {"authorization", "Bearer " <> token} -> token
        _ -> nil
      end)

    case header || Map.get(params, "token") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, "no token presented"}
    end
  end

  defp authenticate(presented) do
    tokens = Application.get_env(:orbitorc_web, :agent_tokens, %{})

    # Walk every configured box and compare in constant time, then decide. Returning on the first match
    # would make the handshake's duration a function of position in the list.
    Enum.reduce(tokens, {:error, "unknown token"}, fn {box, expected}, acc ->
      if Plug.Crypto.secure_compare(to_string(expected), presented),
        do: {:ok, to_string(box)},
        else: acc
    end)
  end
end
