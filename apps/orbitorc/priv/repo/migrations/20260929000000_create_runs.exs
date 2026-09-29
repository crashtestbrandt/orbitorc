defmodule Orbitorc.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs, primary_key: false) do
      add :id, :string, primary_key: true
      add :project, :string, null: false
      add :caller, :string, null: false
      add :phase, :string, null: false
      add :failure, :text
      add :spec, :map
      add :authority, :map
      add :link, :map
      add :load, {:array, :map}
      add :verdicts, {:array, :map}
      add :timeline, {:array, :map}
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :elapsed_ms, :integer

      timestamps()
    end

    create index(:runs, [:started_at])
    create index(:runs, [:project])
  end
end
