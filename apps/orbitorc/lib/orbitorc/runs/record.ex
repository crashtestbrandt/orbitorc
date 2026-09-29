defmodule Orbitorc.Runs.Record do
  @moduledoc "One row of run history. The columns mirror the run's snapshot."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "runs" do
    field :project, :string
    field :caller, :string
    field :phase, :string
    field :failure, :string
    field :spec, :map
    field :authority, :map
    field :link, :map
    field :load, {:array, :map}
    field :verdicts, {:array, :map}
    field :timeline, {:array, :map}
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :elapsed_ms, :integer

    timestamps()
  end

  @fields ~w(id project caller phase failure spec authority link load verdicts timeline started_at finished_at elapsed_ms)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @fields)
    |> validate_required([:id, :project, :caller, :phase, :started_at])
  end
end
