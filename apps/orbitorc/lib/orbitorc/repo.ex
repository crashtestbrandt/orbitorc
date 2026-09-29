defmodule Orbitorc.Repo do
  @moduledoc """
  Run history.

  **Defined here, started by the control plane.** The agent depends on this application and has no
  database: it holds no history, it is not a source of truth about anything, and a box that failed to
  start because a database was missing would fail for a reason having nothing to do with the job it was
  asked to run. `OrbitorcWeb.Application` is what puts this in a supervision tree.
  """

  use Ecto.Repo,
    otp_app: :orbitorc,
    adapter: Ecto.Adapters.SQLite3
end
