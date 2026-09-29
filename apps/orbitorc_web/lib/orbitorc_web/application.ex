defmodule OrbitorcWeb.Application do
  @moduledoc """
  The control plane's supervision tree.

  **Persistence starts here, not in the domain.** Run history is the control plane's business. The
  domain application is also what an agent depends on, and an agent has no database.

  Start order: the repository and its migrations, then telemetry, then the endpoint. The endpoint is
  what agents dial into, so it comes up last — an agent that connected before the control plane could
  record anything would be accepted into a fleet with no memory.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Orbitorc.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:orbitorc, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:orbitorc, :dns_cluster_query) || :ignore},
      OrbitorcWeb.Telemetry,
      Orbitorc.Fleet,
      Orbitorc.Request,
      {DynamicSupervisor, name: Orbitorc.RunSupervisor, strategy: :one_for_one},
      OrbitorcWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OrbitorcWeb.Supervisor)
  end

  defp skip_migrations? do
    # Migrations run on boot for a release; a dev or test run drives them through mix.
    System.get_env("RELEASE_NAME") == nil
  end

  @impl true
  def config_change(changed, _new, removed) do
    OrbitorcWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
