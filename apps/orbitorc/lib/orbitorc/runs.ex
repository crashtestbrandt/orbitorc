defmodule Orbitorc.Runs do
  @moduledoc """
  Run history, and the live runs beside it.

  A run publishes a snapshot on every transition. While the run's process is alive that snapshot sits
  in `Orbitorc.RunRegistry`, where a dashboard or an API call reads it **without calling the process**
  — a run between phases is blocked on a box, and a caller must not be blocked behind it. When the run
  ends, the last snapshot is what the history keeps.

  ## Recording is best-effort by design

  The domain application starts no database; the control plane does. `record/1` writes when a
  repository is running and does nothing when one is not, so a run behaves the same in a test with no
  database and in a control plane with one. A run must never fail because its history could not be
  written — the measurement is the point, the record is a convenience.
  """

  import Ecto.Query, only: [from: 2]

  alias Orbitorc.Runs.Record

  @doc "The current snapshot of a run: live from the registry, else the last one recorded."
  @spec fetch(String.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch(id) do
    case live(id) do
      {:ok, snap} -> {:ok, Map.put(snap, :alive, true)}
      :error -> stored(id)
    end
  end

  @doc "Every run known to the registry right now."
  @spec live_runs() :: [map()]
  def live_runs do
    if Process.whereis(Orbitorc.RunRegistry) do
      Orbitorc.RunRegistry
      |> Registry.select([{{:"$1", :_, :"$2"}, [], [:"$2"]}])
      |> Enum.map(&Map.put(&1, :alive, true))
    else
      []
    end
  end

  @doc "Recorded runs, newest first."
  @spec list(pos_integer()) :: [map()]
  def list(limit \\ 50) do
    if repo_up?() do
      from(r in Record, order_by: [desc: r.started_at], limit: ^limit)
      |> Orbitorc.Repo.all()
      |> Enum.map(&to_map/1)
    else
      []
    end
  end

  @doc "Upsert a run's snapshot. A no-op without a repository."
  @spec record(map()) :: :ok
  def record(snap) do
    if repo_up?() do
      attrs = %{
        id: snap.id,
        project: snap.project,
        caller: snap.caller,
        phase: Atom.to_string(snap.phase),
        failure: snap.failure,
        spec: snap.spec,
        authority: snap.authority && stringify(snap.authority),
        link: snap.link && stringify(snap.link),
        load: Enum.map(snap.load, &stringify/1),
        verdicts: snap.verdicts,
        timeline: snap.timeline,
        started_at: DateTime.from_unix!(snap.started_at, :millisecond),
        finished_at: snap.finished_at && DateTime.from_unix!(snap.finished_at, :millisecond),
        elapsed_ms: snap.elapsed_ms
      }

      %Record{}
      |> Record.changeset(attrs)
      |> Orbitorc.Repo.insert(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: :id
      )
      |> case do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          require Logger
          Logger.warning("run record failed: #{inspect(changeset.errors)}")
          :ok
      end
    else
      :ok
    end
  end

  defp live(id) do
    if Process.whereis(Orbitorc.RunRegistry) do
      case Registry.lookup(Orbitorc.RunRegistry, id) do
        [{_pid, snap}] -> {:ok, snap}
        _ -> :error
      end
    else
      :error
    end
  end

  defp stored(id) do
    if repo_up?() do
      case Orbitorc.Repo.get(Record, id) do
        nil -> {:error, :not_found}
        record -> {:ok, record |> to_map() |> Map.put(:alive, false)}
      end
    else
      {:error, :not_found}
    end
  end

  defp repo_up?, do: Process.whereis(Orbitorc.Repo) != nil

  defp to_map(%Record{} = r) do
    %{
      id: r.id,
      phase: String.to_existing_atom(r.phase),
      project: r.project,
      caller: r.caller,
      spec: r.spec,
      authority: r.authority,
      link: r.link,
      load: r.load || [],
      failure: r.failure,
      verdicts: r.verdicts || [],
      timeline: r.timeline || [],
      started_at: r.started_at && DateTime.to_unix(r.started_at, :millisecond),
      finished_at: r.finished_at && DateTime.to_unix(r.finished_at, :millisecond),
      elapsed_ms: r.elapsed_ms
    }
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(other), do: other
end
