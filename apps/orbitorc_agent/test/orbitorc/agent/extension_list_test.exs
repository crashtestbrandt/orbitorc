defmodule Orbitorc.Agent.ExtensionListTest do
  @moduledoc """
  A cold project's extensions are listed before it is imported.

  Godot 4.7.2 loads an extension it finds during its first scan mid-session, and a headless session that
  did so crashes at exit (godotengine/godot#123511). With `.godot/extension_list.cfg` written first, it
  loads them at startup and exits cleanly.
  """
  use ExUnit.Case, async: true

  alias Orbitorc.Agent.Command

  setup do
    root = Path.join(System.tmp_dir!(), "orbitorc-extlist-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "A COLD PROJECT GETS EVERY EXTENSION THE ENGINE'S SCAN WOULD FIND, sorted", %{root: root} do
    touch(root, "addons/b_native/b.gdextension")
    touch(root, "addons/a_native/a.gdextension")
    touch(root, "addons/a_native/bin/liba.dylib")
    touch(root, "project.godot")

    assert Command.seed_extension_list(root) == [
             "res://addons/a_native/a.gdextension",
             "res://addons/b_native/b.gdextension"
           ]

    assert File.read!(Path.join(root, ".godot/extension_list.cfg")) ==
             "res://addons/a_native/a.gdextension\nres://addons/b_native/b.gdextension\n"
  end

  test "HIDDEN AND .gdignore DIRECTORIES ARE SKIPPED, as the engine skips them", %{root: root} do
    touch(root, "addons/n/n.gdextension")
    # A checkout of the engine's own sources beside the project, as a profiling box keeps one.
    touch(root, ".godot-macos/godot-source/tests/compat.gdextension")
    touch(root, "vendor/.gdignore")
    touch(root, "vendor/x/x.gdextension")

    assert Command.seed_extension_list(root) == ["res://addons/n/n.gdextension"]
  end

  test "AN EXISTING LIST IS THE ENGINE'S OWN and is left alone", %{root: root} do
    touch(root, "addons/n/n.gdextension")
    File.mkdir_p!(Path.join(root, ".godot"))
    File.write!(Path.join(root, ".godot/extension_list.cfg"), "res://kept.gdextension\n")

    assert Command.seed_extension_list(root) == []
    assert File.read!(Path.join(root, ".godot/extension_list.cfg")) == "res://kept.gdextension\n"
  end

  test "A PROJECT WITH NO EXTENSION GETS NO FILE", %{root: root} do
    touch(root, "project.godot")
    assert Command.seed_extension_list(root) == []
    refute File.exists?(Path.join(root, ".godot/extension_list.cfg"))
  end

  defp touch(root, rel) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end
end
