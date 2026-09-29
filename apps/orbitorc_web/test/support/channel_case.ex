defmodule OrbitorcWeb.ChannelCase do
  @moduledoc """
  Channel tests against the real endpoint. The fleet and request table are the application's own, so
  every test cleans up the box it joined by closing its socket.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import OrbitorcWeb.ChannelCase

      @endpoint OrbitorcWeb.Endpoint
    end
  end

  setup _tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Orbitorc.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
