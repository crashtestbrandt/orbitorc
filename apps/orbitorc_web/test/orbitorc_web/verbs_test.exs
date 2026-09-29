defmodule OrbitorcWeb.VerbsTest do
  @moduledoc """
  The one table of verbs, and the parity it enforces: every verb is routed in the JSON API and bound
  to a page, so the command line and the dashboard can do the same things.
  """
  use OrbitorcWeb.ConnCase, async: false

  alias OrbitorcWeb.Verbs

  @pages [
    OrbitorcWeb.FleetLive,
    OrbitorcWeb.BoxLive,
    OrbitorcWeb.JobLive,
    OrbitorcWeb.RunsLive,
    OrbitorcWeb.RunLive
  ]

  test "EVERY VERB IS IN THE API AND ON A PAGE" do
    routed =
      OrbitorcWeb.Router.__routes__()
      |> Enum.filter(&(&1.plug == OrbitorcWeb.ApiController))
      |> Enum.map(&(&1.plug_opts |> Atom.to_string() |> String.replace("_", "-")))
      |> MapSet.new()

    on_pages = @pages |> Enum.flat_map(& &1.verbs()) |> MapSet.new()

    for verb <- Verbs.names() do
      assert verb in routed, "#{verb} has no API route"
      assert verb in on_pages, "#{verb} is on no page"
    end

    # And a page claims nothing the table does not have.
    for verb <- on_pages, do: assert(Verbs.verb?(verb), "a page names #{verb}, which is no verb")
  end

  # The command line is its own application and not a dependency of this one, so its usage is read
  # off the disk rather than out of the module.
  @cli Path.expand("../../../orbitorc_cli/lib/orbitorc/cli.ex", __DIR__)

  test "the command line's usage names every verb" do
    usage = File.read!(@cli)

    for verb <- Verbs.names(),
        do: assert(usage =~ "orbitorc #{verb}", "#{verb} is not in the command line's usage")
  end

  test "A MUTATION WITHOUT A CALLER IS REFUSED, and a read is not" do
    assert {:error, {400, reason}} =
             Verbs.run("launch", %{"box" => "ghost", "project" => "p", "mode" => "m"}, nil)

    assert reason =~ "needs a caller"
    assert {:error, {400, _}} = Verbs.run("sync", %{"project" => "p", "revision" => "main"}, "")
    assert {:ok, %{"boxes" => []}} = Verbs.run("fleet", %{}, nil)
  end

  test "an unknown verb is a 404, a missing parameter a 400, an unknown run a 404" do
    assert {:error, {404, _}} = Verbs.run("teleport", %{}, "t")
    assert {:error, {400, "box is required"}} = Verbs.run("status", %{}, "t")

    assert {:error, {400, "id must be a number"}} =
             Verbs.run("logs", %{"box" => "b", "id" => "x"}, "t")

    assert {:error, {404, _}} = Verbs.run("run-status", %{"id" => "nope"}, nil)
  end

  test "a verb against a box that is not connected says so" do
    assert {:error, "ghost is not connected"} = Verbs.run("status", %{"box" => "ghost"}, nil)
  end

  test "a numeric-looking parameter is coerced, the rest left alone" do
    assert Verbs.coerce("47900") == 47_900
    assert Verbs.coerce("1.5") == 1.5
    assert Verbs.coerce("10.0.0.1:47900") == "10.0.0.1:47900"
    assert Verbs.coerce(7) == 7
  end
end
