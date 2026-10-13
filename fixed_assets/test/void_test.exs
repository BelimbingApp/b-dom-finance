defmodule Bilimbi.Finance.FixedAssets.VoidTest do
  use Bilimbi.Base.Database.DataCase, async: false
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.{FixedAssets, Ledger}
  alias Bilimbi.Finance.FixedAssets.TestFixtures, as: Fixtures

  setup do
    context = Fixtures.setup!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    context
  end

  defp reverse_source!(c, asset, date) do
    {:ok, _} =
      Ledger.reverse_entry(c.keeper, 73, asset.entry_id, %{
        entry_date: date,
        description: "Supplier bill voided"
      })
  end

  defp void!(c, asset, date) do
    {:ok, event} =
      FixedAssets.void_acquisition(c.keeper, 73, asset.id, %{
        effective_date: date,
        reason: "Acquisition cancelled"
      })

    event
  end

  defp balanced!(c, date) do
    {:ok, report} = FixedAssets.register_report(c.keeper, 73, date)
    assert Enum.all?(report.reconciliation, &Decimal.eq?(&1.difference, 0))
    report
  end

  test "a reversed acquisition is listed as an exception while the other assets are charged", c do
    first = Fixtures.acquisition!(c)
    second = Fixtures.acquisition!(c)
    reverse_source!(c, first, ~D[2026-01-02])

    {:ok, run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    assert Decimal.eq?(run.total, 100)
    assert [%{asset_id: id}] = run.items
    assert id == second.id

    assert [%{asset_id: skipped, asset_number: 1, reason: :acquisition_reversed}] =
             run.exceptions

    assert skipped == first.id
    assert {:ok, ^run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    assert {:ok, [^run]} = FixedAssets.list_runs(c.keeper, 73)
    Ledger.TestFixtures.check_deferred_constraints!()
  end

  test "a run with only excepted assets records an empty run with its exceptions", c do
    asset = Fixtures.acquisition!(c)
    reverse_source!(c, asset, ~D[2026-01-02])
    {:ok, run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    assert run.entry_id == nil
    assert Decimal.eq?(run.total, 0)
    assert [%{asset_id: id}] = run.exceptions
    assert id == asset.id
    Ledger.TestFixtures.check_deferred_constraints!()
  end

  test "voiding reverses only that asset's depreciation and later runs skip it", c do
    first = Fixtures.acquisition!(c)
    second = Fixtures.acquisition!(c)
    {:ok, january} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    assert Decimal.eq?(january.total, 200)
    reverse_source!(c, first, ~D[2026-01-31])

    event = void!(c, first, ~D[2026-02-01])
    assert event.action == "acquisition_voided"
    assert Decimal.eq?(event.accumulated, 100)
    {:ok, entry} = Ledger.get_entry(c.keeper, 73, event.entry_id)
    assert Decimal.eq?(hd(entry.lines).debit, 100)
    assert event.recorded_by_user_id == 91
    assert event.recorded_at

    report = balanced!(c, ~D[2026-02-01])
    row = Enum.find(report.rows, &(&1.asset.id == first.id))
    assert row.voided?
    assert Decimal.eq?(row.accumulated, 0)
    kept = Enum.find(report.rows, &(&1.asset.id == second.id))
    refute kept.voided?
    assert Decimal.eq?(kept.accumulated, 100)

    {:ok, february} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-02-01])
    assert Decimal.eq?(february.total, 100)
    assert [%{asset_id: id}] = february.items
    assert id == second.id
    assert february.exceptions == []
    balanced!(c, ~D[2026-02-28])

    {:ok, detail} = FixedAssets.get_asset(c.keeper, 73, first.id)
    assert detail.voided?
    assert [%{reversal: %{action: "acquisition_voided"}}] = detail.charges
    assert Enum.map(detail.events, & &1.action) == ["acquisition_voided"]
    Ledger.TestFixtures.check_deferred_constraints!()
  end

  test "an asset voided before any depreciation records an entry-less event", c do
    asset = Fixtures.acquisition!(c)
    reverse_source!(c, asset, ~D[2026-01-02])
    event = void!(c, asset, ~D[2026-01-03])
    assert event.entry_id == nil
    assert Decimal.eq?(event.accumulated, 0)
    {:ok, run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    assert run.exceptions == []
    assert run.entry_id == nil
    balanced!(c, ~D[2026-01-31])
  end

  test "an entry-less void needs a date in an open fiscal period", c do
    asset = Fixtures.acquisition!(c)
    reverse_source!(c, asset, ~D[2026-01-02])
    attrs = fn date -> %{effective_date: date, reason: "Acquisition cancelled"} end

    assert {:error, :period_not_found} =
             FixedAssets.void_acquisition(c.keeper, 73, asset.id, attrs.(~D[2062-02-01]))

    assert {:error, :period_not_found} =
             FixedAssets.void_acquisition(c.keeper, 73, asset.id, attrs.(~D[2025-12-31]))

    [january | _] = c.year.periods
    {:ok, _} = Ledger.close_period(c.keeper, 73, january.id)

    assert {:error, :period_closed} =
             FixedAssets.void_acquisition(c.keeper, 73, asset.id, attrs.(~D[2026-01-15]))

    {:ok, detail} = FixedAssets.get_asset(c.keeper, 73, asset.id)
    assert detail.events == []

    event = void!(c, asset, ~D[2026-02-01])
    assert event.entry_id == nil
    assert {:ok, %{voided?: true}} = FixedAssets.get_asset(c.keeper, 73, asset.id)
  end

  test "a voided asset cannot be disposed or voided again, and a live acquisition cannot be voided",
       c do
    asset = Fixtures.acquisition!(c)
    attrs = %{effective_date: ~D[2026-02-01], reason: "Retire", proceeds: "0"}

    assert {:error, :acquisition_not_reversed} =
             FixedAssets.void_acquisition(c.keeper, 73, asset.id, Map.delete(attrs, :proceeds))

    reverse_source!(c, asset, ~D[2026-01-02])
    void!(c, asset, ~D[2026-02-01])
    assert {:error, :asset_voided} = FixedAssets.dispose(c.keeper, 73, asset.id, attrs)

    assert {:error, :already_voided} =
             FixedAssets.void_acquisition(c.keeper, 73, asset.id, Map.delete(attrs, :proceeds))

    assert {:error, :not_disposed} =
             FixedAssets.reverse_disposal(c.keeper, 73, asset.id, %{
               effective_date: ~D[2026-02-02],
               reason: "Nothing to undo"
             })
  end

  test "a standing disposal must be reversed before the acquisition is voided", c do
    asset = Fixtures.acquisition!(c)
    {:ok, _} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])

    {:ok, disposal} =
      FixedAssets.dispose(c.keeper, 73, asset.id, %{
        effective_date: ~D[2026-02-01],
        reason: "Written off",
        proceeds: "0"
      })

    reverse_source!(c, asset, ~D[2026-02-02])
    attrs = %{effective_date: ~D[2026-02-03], reason: "Acquisition cancelled"}

    assert {:error, :disposal_standing} =
             FixedAssets.void_acquisition(c.keeper, 73, asset.id, attrs)

    {:ok, _} =
      FixedAssets.reverse_disposal(c.keeper, 73, asset.id, %{
        effective_date: ~D[2026-02-03],
        reason: "Undo #{disposal.id}"
      })

    assert {:ok, %{action: "acquisition_voided"}} =
             FixedAssets.void_acquisition(c.keeper, 73, asset.id, attrs)
  end

  test "reversing a run after a void leaves the voided asset's reversal alone", c do
    first = Fixtures.acquisition!(c)
    second = Fixtures.acquisition!(c)
    {:ok, january} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    reverse_source!(c, first, ~D[2026-01-31])
    void!(c, first, ~D[2026-02-01])

    {:ok, reversal} =
      FixedAssets.reverse_run(c.keeper, 73, january.id, %{
        effective_date: ~D[2026-02-01],
        reason: "Correct charge"
      })

    {:ok, entry} = Ledger.get_entry(c.keeper, 73, reversal.entry_id)
    assert Decimal.eq?(hd(entry.lines).debit, 100)
    assert {:ok, [%{reversed?: true}]} = FixedAssets.list_runs(c.keeper, 73)

    assert {:error, :already_reversed} =
             FixedAssets.reverse_run(c.keeper, 73, january.id, %{
               effective_date: ~D[2026-02-01],
               reason: "Again"
             })

    report = balanced!(c, ~D[2026-02-28])
    kept = Enum.find(report.rows, &(&1.asset.id == second.id))
    assert Decimal.eq?(kept.accumulated, 0)
    Ledger.TestFixtures.check_deferred_constraints!()
  end

  test "a later run holding only voided charges does not block reversing an earlier run", c do
    first = Fixtures.acquisition!(c, %{in_service_date: ~D[2026-02-01]})
    second = Fixtures.acquisition!(c, %{life_months: 1})
    {:ok, january} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    assert [%{asset_id: id}] = january.items
    assert id == second.id
    {:ok, february} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-02-01])
    assert [%{asset_id: id}] = february.items
    assert id == first.id

    reverse_source!(c, first, ~D[2026-02-28])
    void!(c, first, ~D[2026-03-01])

    assert {:ok, %{action: "run_reversed"}} =
             FixedAssets.reverse_run(c.keeper, 73, january.id, %{
               effective_date: ~D[2026-03-01],
               reason: "Correct charge"
             })

    balanced!(c, ~D[2026-03-31])

    assert {:error, :empty_run} =
             FixedAssets.reverse_run(c.keeper, 73, february.id, %{
               effective_date: ~D[2026-03-01],
               reason: "Nothing left"
             })
  end
end
