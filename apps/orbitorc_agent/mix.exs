defmodule Orbitorc.Agent.MixProject do
  use Mix.Project

  @moduledoc """
  The box-side release.

  It ships to every machine that runs jobs, so it stays small on purpose: no Phoenix, no assets, no
  database. It dials OUT to the control plane over a WebSocket, which is what removes the inbound
  firewall rule, the per-box SSH key and the static hostname that a push-model fleet needs.
  """

  def project do
    [
      app: :orbitorc_agent,
      version: File.read!(Path.join(__DIR__, "../../VERSION")) |> String.trim(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Orbitorc.Agent.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:orbitorc, in_umbrella: true},
      {:slipstream, "~> 1.1"},
      {:jason, "~> 1.4"}
    ]
  end
end
