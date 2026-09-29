defmodule Mix.Tasks.Orbitorc do
  @shortdoc "Drive the fleet from the command line"

  @moduledoc """
  `mix orbitorc <verb>` — the same command line as the `orbitorc` escript, run from the umbrella.

  See `Orbitorc.CLI` for every verb. `mix escript.build` in `apps/orbitorc_cli` produces the standalone
  executable a consumer project's task runner aliases.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    case Orbitorc.CLI.run(argv) do
      :ok -> :ok
      {:error, _} -> exit({:shutdown, 1})
    end
  end
end
