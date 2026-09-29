defmodule Orbitorc.Capability do
  @moduledoc """
  What a box can actually serve, asked of the box rather than assumed from its name.

  A caller's verb is checked against this list before anything is launched, so a refusal reads as "this
  target cannot do that" instead of an obscure error from three layers down. The list a box reports is
  the authority; nothing here infers a capability from a platform name.

  ## Launch capabilities are per project

  One box serves several projects and they do not agree about which modes render, so a launch capability
  is named `launch.<project>.<mode>`. A box holding no manifest for a project reports no launch
  capability for it at all, rather than a guess.
  """

  @doc "The capability name a launch verb is checked against."
  @spec launch(String.t(), String.t()) :: String.t()
  def launch(project, mode), do: "launch.#{project}.#{mode}"

  @doc """
  Whether `caps` permits `name`.

  An unknown capability is refused. A box reports what it can do; anything absent from that report is
  something it cannot do, not something to try and see.
  """
  @spec permits?(map(), String.t()) :: boolean()
  def permits?(caps, name) when is_map(caps), do: Map.get(caps, name) == true

  @doc """
  Check a verb against a box's report, answering a message a caller can read.

  `label` names the box, so a fleet-wide refusal says which target declined.
  """
  @spec check(map(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def check(caps, name, label) do
    cond do
      permits?(caps, name) -> :ok
      Map.has_key?(caps, name) -> {:error, "#{label} cannot serve #{name}"}
      true -> {:error, "#{label} does not report #{name} at all"}
    end
  end

  @doc """
  Launch capabilities for every mode of every manifest a box holds.

  A mode that renders needs a graphical session; a mode that declares itself headless is honestly
  headless and is offered whether or not the box has a display.
  """
  @spec for_projects(%{optional(String.t()) => Orbitorc.Manifest.t()}, boolean()) :: map()
  def for_projects(manifests, session_ok?) do
    for {name, manifest} <- manifests,
        mode <- Orbitorc.Manifest.mode_names(manifest),
        into: %{} do
      {launch(name, mode),
       if(Orbitorc.Manifest.needs_gui?(manifest, mode), do: session_ok?, else: true)}
    end
  end
end
