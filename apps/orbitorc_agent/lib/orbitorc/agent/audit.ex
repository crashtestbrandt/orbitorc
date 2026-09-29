defmodule Orbitorc.Agent.Audit do
  @moduledoc """
  An append-only record of every action taken on this box.

  On a machine several callers drive, this is the only way to reconstruct who changed what. One JSON
  object per line, beside the configuration, never rotated by the agent — a log that deletes its own
  history answers a different question than the one asked of it.
  """

  use GenServer
  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Record one action. Never blocks the caller and never fails a verb."
  @spec record(String.t(), String.t(), map(), term()) :: :ok
  def record(caller, verb, args \\ %{}, result \\ :ok) do
    GenServer.cast(__MODULE__, {:record, caller, verb, args, result})
  end

  @impl true
  def init(opts) do
    path =
      Keyword.get(opts, :path) || Path.join(Orbitorc.Agent.Platform.config_dir(), "audit.jsonl")

    File.mkdir_p!(Path.dirname(path))
    {:ok, %{path: path}}
  end

  @impl true
  def handle_cast({:record, caller, verb, args, result}, state) do
    entry = %{
      at: DateTime.utc_now() |> DateTime.to_iso8601(),
      caller: caller,
      verb: verb,
      args: sanitize(args),
      result: inspect(result)
    }

    case File.open(state.path, [:append, :binary]) do
      {:ok, file} ->
        IO.binwrite(file, [Jason.encode_to_iodata!(entry), "\n"])
        File.close(file)

      {:error, reason} ->
        Logger.warning("audit write failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # A token must never reach the audit log: the record exists to be read by people, and a credential in
  # it turns a diagnostic file into a secret.
  defp sanitize(args) when is_map(args) do
    Map.new(args, fn {k, v} ->
      if to_string(k) =~ ~r/token|secret|password|key/i, do: {k, "[redacted]"}, else: {k, v}
    end)
  end

  defp sanitize(args), do: args
end
