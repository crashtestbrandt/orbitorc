defmodule Orbitorc.CLI.MixProject do
  use Mix.Project

  @moduledoc """
  The command line, as a standalone executable.

  A consumer project's task runner aliases its verbs to this. An escript runs from any directory on any
  machine with Erlang installed and needs no checkout of this repository, which is what lets `pull`
  land artifacts where the person is standing rather than inside a control plane's working tree.

      mix escript.build        # from this directory: ./orbitorc
      mix orbitorc <verb>      # the same code, from the umbrella root
  """

  def project do
    [
      app: :orbitorc_cli,
      version: File.read!(Path.join(__DIR__, "../../VERSION")) |> String.trim(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: false,
      escript: [main_module: Orbitorc.CLI, name: "orbitorc"],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
