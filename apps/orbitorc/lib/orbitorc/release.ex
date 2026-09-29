defmodule Orbitorc.Release do
  @moduledoc """
  Where a release's agent lives for a given box.

  CI names each artifact by the runner that built it — `orbitorc_agent-<OS>-<ARCH>.<ext>` with the
  values GitHub's runners use (`Linux`, `macOS`, `Windows`; `X64`, `ARM64`) — and attaches them to the
  tag's release with a `.sha256` beside each. A box reports its platform and architecture in the
  agent's own words, so this is the one place the two vocabularies meet.
  """

  @default_source "https://github.com/crashtestbrandt/orbitorc/releases/download"

  @doc "The base every tag's assets hang under; `config :orbitorc, :release_source` overrides it."
  def source, do: Application.get_env(:orbitorc, :release_source, @default_source)

  @doc """
  The URL of the agent archive for a box, given a release.

  A release is a tag (`v0.2.0`, or `0.2.0`), or a URL, which is taken as it is — for a build that is
  not on the release page, or a release page that is not this project's.
  """
  @spec asset_url(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def asset_url(release, platform, arch) do
    if String.starts_with?(release, ["http://", "https://"]) do
      {:ok, release}
    else
      with {:ok, os} <- os_name(platform),
           {:ok, cpu} <- arch_name(arch) do
        ext = if platform == "windows", do: "zip", else: "tar.gz"
        {:ok, "#{source()}/#{tag(release)}/orbitorc_agent-#{os}-#{cpu}.#{ext}"}
      end
    end
  end

  @doc "The tag a release name means: `0.2.0` and `v0.2.0` are both `v0.2.0`."
  def tag("v" <> _ = tag), do: tag
  def tag(version), do: "v" <> version

  defp os_name("linux"), do: {:ok, "Linux"}
  defp os_name("macos"), do: {:ok, "macOS"}
  defp os_name("windows"), do: {:ok, "Windows"}
  defp os_name(other), do: {:error, "no release is built for platform #{inspect(other)}"}

  defp arch_name(arch) when arch in ["x64", "x86_64", "amd64"], do: {:ok, "X64"}
  defp arch_name(arch) when arch in ["arm64", "aarch64"], do: {:ok, "ARM64"}

  defp arch_name(nil),
    do:
      {:error, "the box did not report its architecture; give the archive's URL instead of a tag"}

  defp arch_name(other), do: {:error, "no release is built for architecture #{inspect(other)}"}
end
