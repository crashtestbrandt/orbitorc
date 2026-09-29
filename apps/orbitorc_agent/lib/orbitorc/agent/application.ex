defmodule Orbitorc.Agent.Application do
  @moduledoc """
  The box-side supervision tree.

  ## Start order is a rule, not an accident

  The lease and the audit log come up before anything can be launched, and the job supervisor comes up
  before the link that accepts launch requests. An agent that accepted a request it could not record or
  arbitrate would be worse than one that was not running.

  ## A misconfigured box starts anyway

  With no configuration, or one that does not parse, the agent starts and reports the problem rather
  than crash-looping. A box that vanishes from the fleet says nothing about why; a box that appears and
  names its own misconfiguration can be fixed.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # The test environment starts the agent idle: a developer's own box configuration must not be
    # loaded by a test run, or the tests would dial a control plane and register jobs under a real name.
    config =
      if Application.get_env(:orbitorc_agent, :autostart, true), do: load_config(), else: nil

    children =
      [
        {Orbitorc.Agent.Audit, []},
        {Orbitorc.Agent.Leases, []},
        {DynamicSupervisor, name: Orbitorc.Agent.JobSupervisor, strategy: :one_for_one}
      ] ++ job_registry(config) ++ link(config)

    # A generous restart budget on purpose. The link is the child most likely to fail, and what it fails
    # on is usually a control plane that is not up yet. The default budget — three restarts in five
    # seconds — turns that into a dead agent on a box nobody is sitting at, which is the one outcome
    # that needs a person to go and fix it.
    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Orbitorc.Agent.Supervisor,
      max_restarts: 100,
      max_seconds: 60
    )
  end

  defp load_config do
    case Orbitorc.Agent.Config.load() do
      {:ok, config, []} ->
        Logger.info(
          "orbitorc agent: #{config.name}, serving #{config.projects |> Map.keys() |> Enum.join(", ")}"
        )

        config

      {:ok, config, problems} ->
        Enum.each(problems, &Logger.warning("orbitorc agent: #{&1}"))
        config

      {:error, reason} ->
        Logger.warning("orbitorc agent: #{reason} — starting idle, nothing can be launched")
        nil
    end
  end

  defp job_registry(nil), do: []

  defp job_registry(config) do
    [{Orbitorc.Agent.Jobs, root: config.jobs_dir, retention: config.job_retention}]
  end

  # The link is only started when the box knows who it is. Without a configuration there is nothing to
  # authenticate with and nowhere to dial.
  defp link(nil), do: []
  defp link(config), do: [{Orbitorc.Agent.Link, config: config}]
end
