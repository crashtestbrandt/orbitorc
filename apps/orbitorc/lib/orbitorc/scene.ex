defmodule Orbitorc.Scene do
  @moduledoc """
  Validating the scene path a job may boot.

  A mode that declares a scene names one inside the checkout the target already holds. That is strictly
  less than a session: launching one runs every line of script in the same tree, so a caller who may
  launch at all can already run any code the tree contains.

  What it must not become is a path **out** of the tree, which is why the shape is asserted rather than
  trusted. Accepts `res://a/b.tscn` or the project-relative `a/b.tscn`; answers the `res://` spelling.
  """

  @doc "The `res://…tscn` path a scene job boots, or an error naming what is wrong with it."
  @spec normalize(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def normalize(scene) do
    raw = String.trim(scene || "")

    with :ok <- refuse(raw == "", "no scene path was given (e.g. res://probes/smoke.tscn)"),
         path = String.replace_prefix(raw, "res://", ""),
         # Backslashes first: a Windows separator would slip a `..\` past a check that splits on `/`.
         :ok <-
           refuse(
             String.contains?(path, "\\"),
             "#{inspect(raw)} uses backslashes; res:// paths are forward-slashed"
           ),
         :ok <-
           refuse(absolute?(path), "#{inspect(raw)} is absolute; name a path inside the project"),
         :ok <- refuse(not String.ends_with?(path, ".tscn"), "#{inspect(raw)} is not a .tscn"),
         segments = String.split(path, "/"),
         :ok <-
           refuse(
             Enum.any?(segments, &(&1 in ["", ".", ".."])),
             "#{inspect(raw)} must not contain '.', '..' or an empty segment"
           ) do
      {:ok, "res://" <> path}
    end
  end

  defp absolute?(path) do
    String.starts_with?(path, "/") or match?(<<_::utf8, ":", _::binary>>, path)
  end

  defp refuse(true, message), do: {:error, message}
  defp refuse(false, _message), do: :ok
end
