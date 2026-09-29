defmodule Orbitorc.ReleaseTest do
  use ExUnit.Case, async: true

  alias Orbitorc.Release

  test "a tag resolves to the archive CI attached for that platform and architecture" do
    base = Release.source()

    assert {:ok, "#{base}/v0.2.0/orbitorc_agent-Windows-X64.zip"} ==
             Release.asset_url("v0.2.0", "windows", "x64")

    assert {:ok, "#{base}/v0.2.0/orbitorc_agent-macOS-ARM64.tar.gz"} ==
             Release.asset_url("0.2.0", "macos", "arm64")

    assert {:ok, "#{base}/v0.2.0/orbitorc_agent-Linux-X64.tar.gz"} ==
             Release.asset_url("0.2.0", "linux", "x86_64")
  end

  test "a URL is taken as it is" do
    assert {:ok, "https://example.invalid/agent.tar.gz"} =
             Release.asset_url("https://example.invalid/agent.tar.gz", "linux", nil)
  end

  test "A BOX THAT DID NOT REPORT ITS ARCHITECTURE cannot be given a tag" do
    assert {:error, reason} = Release.asset_url("v0.2.0", "linux", nil)
    assert reason =~ "architecture"
    assert {:error, _} = Release.asset_url("v0.2.0", "plan9", "x64")
  end
end
