defmodule Orbitorc.SceneTest do
  use ExUnit.Case, async: true
  alias Orbitorc.Scene

  test "a project-relative path gains the res:// spelling" do
    assert Scene.normalize("probes/smoke.tscn") == {:ok, "res://probes/smoke.tscn"}
  end

  test "an already-prefixed path is unchanged" do
    assert Scene.normalize("res://probes/smoke.tscn") == {:ok, "res://probes/smoke.tscn"}
  end

  test "surrounding whitespace is trimmed" do
    assert Scene.normalize("  probes/smoke.tscn\n") == {:ok, "res://probes/smoke.tscn"}
  end

  test "an empty path is refused" do
    assert {:error, msg} = Scene.normalize("")
    assert msg =~ "no scene path"
    assert {:error, _} = Scene.normalize(nil)
  end

  describe "paths out of the tree" do
    test "a parent segment is refused" do
      assert {:error, msg} = Scene.normalize("../../etc/passwd.tscn")
      assert msg =~ ".."
    end

    test "a parent segment in the middle is refused" do
      assert {:error, _} = Scene.normalize("probes/../../secret.tscn")
    end

    test "a BACKSLASH separator is refused before anything splits on a slash" do
      # A Windows separator would slip a `..\` past a check that only splits on `/`.
      assert {:error, msg} = Scene.normalize("probes\\..\\..\\secret.tscn")
      assert msg =~ "backslash"
    end

    test "a posix absolute path is refused" do
      assert {:error, msg} = Scene.normalize("/etc/thing.tscn")
      assert msg =~ "absolute"
    end

    test "a windows drive-letter path is refused" do
      assert {:error, msg} = Scene.normalize("C:/Windows/thing.tscn")
      assert msg =~ "absolute"
    end

    test "an empty segment is refused" do
      assert {:error, _} = Scene.normalize("probes//smoke.tscn")
    end

    test "a single-dot segment is refused" do
      assert {:error, _} = Scene.normalize("probes/./smoke.tscn")
    end
  end

  test "something that is not a scene is refused" do
    assert {:error, msg} = Scene.normalize("probes/smoke.gd")
    assert msg =~ ".tscn"
  end
end
