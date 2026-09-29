defmodule Orbitorc.Measurement do
  @moduledoc """
  Deciding whether a run measured anything.

  A client that joins a session and simulates nothing still produces a full metrics CSV and a normal
  summary line. The transport columns carry real numbers, because the transport is the one layer that
  works whether or not the client ever built a world; every simulation column is flat zero. That reads
  as "joined cleanly, simulated nothing", which is indistinguishable from a regression in the branch
  under test — and it is what a stale import cache produces on a remote box.

  So a run of that shape is refused as a result rather than handed back. A run that can succeed by
  having nothing to do is not a measurement.

  ## Which columns testify is the project's to declare

  A manifest names them under `measurement.evidence`. This module owns the rule and the three verdicts.
  With no declaration there is nothing to judge against and every run answers `:unknown`, which is the
  safe direction: `:unknown` is not a pass, and it is never an accusation.

  ## Evidence is an allow-list, and the direction matters

  Listing the columns to ignore instead reads better — a new simulation metric would join the rule just
  by appearing in the CSV — but it fails the wrong way. A metrics CSV grows transport columns far more
  often than simulation ones, and an unlisted transport column carrying data would rescue a run in
  which nothing simulated, which is the exact answer this module exists to refuse.

  An allow-list fails the other way: a column nobody declared is not counted, which degrades to
  `:unknown` rather than to a false pass. `classify/2` names every column it did not recognize, so the
  gap is visible instead of silent.

  ## Only a mode that can produce the evidence may be accused

  Evidence columns are typically properties of a locally predicted body reconciled against an
  authority. A dedicated server has no such body and a listen host is the authority, so both write
  zeros there by construction, whatever else the run did. Calling those vacuous would be a false
  accusation, which is the one direction this must never be wrong in — so a mode the manifest did not
  list under `measurement.judged_modes` answers `:unknown` rather than `:vacuous`.
  """

  @type verdict :: :measured | :vacuous | :unknown

  @type t :: %__MODULE__{
          verdict: verdict(),
          detail: String.t(),
          rows: non_neg_integer(),
          live: [String.t()],
          zeroed: [String.t()],
          unclassified: [String.t()]
        }

  defstruct verdict: :unknown, detail: "", rows: 0, live: [], zeroed: [], unclassified: []

  @doc """
  `classify/2`, with the accusation withheld from a mode that cannot answer it.

  `spec` is a manifest's `measurement` map: `evidence`, `known_other` and `judged_modes`.
  """
  @spec verdict_for_mode(String.t(), String.t(), map()) :: t()
  def verdict_for_mode(mode, csv_text, spec \\ %{}) do
    result = classify(csv_text, spec)
    judged = Map.get(spec, "judged_modes", [])

    if result.verdict == :vacuous and mode not in judged do
      %__MODULE__{
        result
        | verdict: :unknown,
          detail:
            "a #{mode} run is not judged on these columns, so they are zero however the run went — #{result.detail}"
      }
    else
      result
    end
  end

  @doc """
  Read a metrics CSV and say whether the declared evidence columns ever moved.

  `:unknown` is not a pass. A CSV with no rows, no header or no recognized evidence column cannot be
  judged, and saying so is different from saying the run was fine. A run that has not finished writing
  is a normal thing to look at, so only `:vacuous` is a failure.
  """
  @spec classify(String.t(), map()) :: t()
  def classify(csv_text, spec \\ %{}) do
    evidence = MapSet.new(Map.get(spec, "evidence", []))
    known_other = MapSet.new(Map.get(spec, "known_other", []))

    case csv_text |> String.split(["\r\n", "\n"]) |> Enum.reject(&(String.trim(&1) == "")) do
      [] ->
        %__MODULE__{verdict: :unknown, detail: "the metrics CSV is empty"}

      [header_line | rows] ->
        header = header_line |> String.split(",") |> Enum.map(&String.trim/1)
        classify_rows(header, rows, evidence, known_other)
    end
  end

  defp classify_rows(header, rows, evidence, known_other) do
    watched =
      header
      |> Enum.with_index()
      |> Enum.filter(fn {name, _} -> MapSet.member?(evidence, name) end)

    unclassified =
      Enum.reject(header, fn name ->
        name == "" or MapSet.member?(evidence, name) or MapSet.member?(known_other, name)
      end)

    base = %__MODULE__{rows: length(rows), unclassified: unclassified}

    cond do
      watched == [] ->
        %{
          base
          | verdict: :unknown,
            detail: "the CSV carries none of the declared evidence columns"
        }

      rows == [] ->
        %{base | verdict: :unknown, detail: "the CSV has a header and no rows yet"}

      true ->
        cells = Enum.map(rows, &String.split(&1, ","))

        {live, zeroed} =
          Enum.split_with(watched, fn {_name, index} ->
            Enum.any?(cells, fn row -> row |> Enum.at(index) |> carries_data?() end)
          end)

        live = Enum.map(live, &elem(&1, 0))
        zeroed = Enum.map(zeroed, &elem(&1, 0))

        if live == [] do
          %{
            base
            | verdict: :vacuous,
              live: live,
              zeroed: zeroed,
              detail:
                "every declared evidence column stayed zero across #{length(rows)} rows (#{Enum.join(zeroed, ", ")})"
          }
        else
          %{
            base
            | verdict: :measured,
              live: live,
              zeroed: zeroed,
              detail:
                "#{length(live)} of #{length(watched)} evidence columns moved (#{Enum.join(live, ", ")})"
          }
        end
    end
  end

  # A cell carries data when it parses as a number that is not zero. A blank, a dash or an unparseable
  # cell is not evidence of anything and must never rescue a run.
  defp carries_data?(nil), do: false

  defp carries_data?(cell) do
    case cell |> to_string() |> String.trim() |> Float.parse() do
      {value, _rest} -> value != 0.0
      :error -> false
    end
  end
end
