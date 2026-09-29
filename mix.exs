defmodule Orbitorc.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Two releases, because the two halves ship to different places.
  #
  # `orbitorc` is the control plane: Phoenix, the database, the dashboard. It runs on one machine.
  # `orbitorc_agent` ships to every box. It carries the domain and the agent and nothing else -- no
  # Phoenix, no assets, no database -- so a box needs no Node, no SQLite and no secret key to run it.
  #
  #     MIX_ENV=prod mix release orbitorc_agent
  #     _build/prod/rel/orbitorc_agent/bin/orbitorc_agent start
  defp releases do
    [
      orbitorc: [
        applications: [orbitorc_web: :permanent],
        include_executables_for: [:unix, :windows]
      ],
      orbitorc_agent: [
        applications: [orbitorc_agent: :permanent],
        include_executables_for: [:unix, :windows]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options.
  #
  # Dependencies listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp deps do
    [
      # Required to run "mix format" on ~H/.heex files from the umbrella root
      {:phoenix_live_view, ">= 0.0.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  #
  # Aliases listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      # The standalone command line: apps/orbitorc_cli/orbitorc, an escript a consumer's task runner aliases.
      escript: ["cmd --app orbitorc_cli mix escript.build"]
    ]
  end
end
