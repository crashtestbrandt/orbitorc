defmodule Orbitorc.Application do
  @moduledoc """
  What every consumer of the domain needs, and nothing else.

  **No repository here.** The agent depends on this application, and an agent has no database: it holds
  no run history, it is not a source of truth about anything, and a box that needed one to start would
  be a box that fails to start for a reason having nothing to do with the job it was asked to run.
  Persistence belongs to the control plane, which starts it in its own tree.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Orbitorc.PubSub},
      # Live run snapshots, readable without calling the run's process. Small, in memory, no database.
      {Registry, keys: :unique, name: Orbitorc.RunRegistry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Orbitorc.Supervisor)
  end
end
