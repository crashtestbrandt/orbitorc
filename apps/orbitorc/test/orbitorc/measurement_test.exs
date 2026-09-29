defmodule Orbitorc.MeasurementTest do
  use ExUnit.Case, async: true
  alias Orbitorc.Measurement

  @spec_ %{
    "evidence" => ["resim_ticks", "reconcile_error"],
    "known_other" => ["tick", "rtt_ms", "rx_bytes_s"],
    "judged_modes" => ["client", "bench"]
  }

  test "evidence that moved is a measurement" do
    csv = "tick,resim_ticks,reconcile_error\n1,0,0.0\n2,3,0.25\n"
    assert %{verdict: :measured, live: live} = Measurement.classify(csv, @spec_)
    assert Enum.sort(live) == ["reconcile_error", "resim_ticks"]
  end

  test "THE RUN THIS EXISTS TO REFUSE: transport alive, every evidence column flat zero" do
    csv = "tick,rtt_ms,rx_bytes_s,resim_ticks,reconcile_error\n1,42,9001,0,0.0\n2,43,8800,0,0.0\n"

    assert %{verdict: :vacuous, detail: detail, zeroed: zeroed} =
             Measurement.classify(csv, @spec_)

    assert Enum.sort(zeroed) == ["reconcile_error", "resim_ticks"]
    assert detail =~ "2 rows"
  end

  test "partly dead is still readable rather than reduced to one bit" do
    csv = "resim_ticks,reconcile_error\n0,0.5\n0,0.25\n"

    assert %{verdict: :measured, live: ["reconcile_error"], zeroed: ["resim_ticks"]} =
             Measurement.classify(csv, @spec_)
  end

  describe "unknown is not a pass" do
    test "an empty CSV" do
      assert %{verdict: :unknown, detail: detail} = Measurement.classify("", @spec_)
      assert detail =~ "empty"
    end

    test "a header and no rows yet — a run still writing is a normal thing to look at" do
      assert %{verdict: :unknown, detail: detail} =
               Measurement.classify("tick,resim_ticks\n", @spec_)

      assert detail =~ "no rows"
    end

    test "a CSV carrying none of the declared evidence columns" do
      assert %{verdict: :unknown} = Measurement.classify("tick,rtt_ms\n1,42\n", @spec_)
    end

    test "A PROJECT THAT DECLARED NOTHING IS NOT JUDGED" do
      # With no declaration there is nothing to judge against, and unknown is the safe direction:
      # it is not a pass, and it is never an accusation.
      assert %{verdict: :unknown} = Measurement.classify("resim_ticks\n0\n", %{})
    end
  end

  test "a column nobody classified is NAMED, so the gap is visible instead of silent" do
    csv = "tick,resim_ticks,brand_new_metric\n1,3,7\n"
    assert %{unclassified: ["brand_new_metric"]} = Measurement.classify(csv, @spec_)
  end

  test "an allow-list means an unlisted transport column cannot rescue a dead run" do
    # Measured against a real send-path CSV, an ignore-list let transport counters count as evidence
    # of a live simulation. This is the direction that fails safely.
    csv = "resim_ticks,reconcile_error,tx_wire_bytes_s\n0,0.0,120000\n"
    assert %{verdict: :vacuous} = Measurement.classify(csv, @spec_)
  end

  describe "a blank or unparseable cell is not evidence" do
    test "a blank cell" do
      csv = "tick,resim_ticks\n1,\n2,\n"
      assert %{verdict: :vacuous} = Measurement.classify(csv, %{"evidence" => ["resim_ticks"]})
    end

    test "a dash" do
      csv = "tick,resim_ticks\n1,-\n"
      assert %{verdict: :vacuous} = Measurement.classify(csv, %{"evidence" => ["resim_ticks"]})
    end

    test "a blank LINE is not a row at all, which is a different answer from a blank cell" do
      assert %{verdict: :unknown, rows: 0} =
               Measurement.classify("resim_ticks\n\n", %{"evidence" => ["resim_ticks"]})
    end
  end

  describe "only a mode that can produce the evidence may be accused" do
    test "a judged mode is accused" do
      csv = "resim_ticks\n0\n"
      assert %{verdict: :vacuous} = Measurement.verdict_for_mode("bench", csv, @spec_)
    end

    test "A DEDICATED SERVER IS NOT: it has no predicted body, so those columns are zero by construction" do
      csv = "resim_ticks\n0\n"

      assert %{verdict: :unknown, detail: detail} =
               Measurement.verdict_for_mode("server", csv, @spec_)

      assert detail =~ "not judged"
    end

    test "a measurement stays a measurement whatever the mode" do
      csv = "resim_ticks\n4\n"
      assert %{verdict: :measured} = Measurement.verdict_for_mode("server", csv, @spec_)
    end
  end

  test "carriage returns do not defeat the row split" do
    csv = "tick,resim_ticks\r\n1,3\r\n"
    assert %{verdict: :measured, rows: 1} = Measurement.classify(csv, @spec_)
  end
end
