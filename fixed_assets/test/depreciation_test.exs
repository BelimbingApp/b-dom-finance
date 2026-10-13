defmodule Bilimbi.Finance.FixedAssets.DepreciationTest do
  use Bilimbi.Base.Database.DataCase, async: false
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.{FixedAssets, Ledger}
  alias Bilimbi.Finance.FixedAssets.TestFixtures, as: Fixtures

  setup do
    context = Fixtures.setup!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    context
  end

  test "monthly run posts one balanced entry and is idempotent", c do
    asset = Fixtures.acquisition!(c, %{residual_value: "120"})
    {:ok, run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    assert Decimal.eq?(run.total, 90)
    assert [%{asset_id: id}] = run.items
    assert id == asset.id
    {:ok, entry} = Ledger.get_entry(c.keeper, 73, run.entry_id)
    assert length(entry.lines) == 2
    assert Decimal.eq?(hd(entry.lines).debit, 90)
    assert {:ok, ^run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    Ledger.TestFixtures.check_deferred_constraints!()
    {:ok, report} = FixedAssets.register_report(c.keeper, 73, ~D[2026-01-31])
    assert Enum.all?(report.reconciliation, &Decimal.eq?(&1.difference, 0))
    assert Decimal.eq?(hd(report.rows).carrying_value, 1110)
  end

  test "skipped months are caught up, reducing balance reaches residual at life end", c do
    asset =
      Fixtures.acquisition!(c, %{
        method: "reducing_balance",
        annual_rate: "24",
        life_months: 3,
        residual_value: "100"
      })

    {:ok, detail} = FixedAssets.get_asset(c.keeper, 73, asset.id)

    assert Enum.zip(detail.schedule, ["24", "23.52", "1052.48"])
           |> Enum.all?(fn {row, expected} -> Decimal.eq?(row.amount, expected) end)

    {:ok, run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-03-01])
    assert Decimal.eq?(run.total, 1100)
    {:ok, empty} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-04-01])
    assert empty.entry_id == nil
    assert Decimal.eq?(empty.total, 0)
  end

  test "closed periods refuse even an empty run and a ledger refusal rolls back the run", c do
    Fixtures.acquisition!(c)
    [period | _] = c.year.periods
    {:ok, _} = Ledger.close_period(c.keeper, 73, period.id)
    assert {:error, :period_closed} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    {:ok, []} = FixedAssets.list_runs(c.keeper, 73)
    # A zero-balance expense account can be made inactive; Ledger then refuses
    # the attempted charge, and no run or items survive that joined transaction.
    {:ok, _} = Ledger.update_account(c.keeper, 73, c.accounts.expense.id, %{active: false})
    assert {:error, %Ecto.Changeset{}} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-02-01])
    assert {:ok, []} = FixedAssets.list_runs(c.keeper, 73)
  end

  test "a run reversal retains history, occurs once, and a subsequent month catches it up", c do
    Fixtures.acquisition!(c)
    {:ok, run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    {:ok, old} = FixedAssets.register_report(c.keeper, 73, ~D[2026-02-28])

    {:ok, reversal} =
      FixedAssets.reverse_run(c.keeper, 73, run.id, %{
        effective_date: ~D[2026-02-01],
        reason: "Correct charge"
      })

    {:ok, entry} = Ledger.get_entry(c.keeper, 73, reversal.entry_id)
    assert entry.reverses_entry_id == run.entry_id

    assert {:error, :already_reversed} =
             FixedAssets.reverse_run(c.keeper, 73, run.id, %{
               effective_date: ~D[2026-02-01],
               reason: "Again"
             })

    {:ok, current} = FixedAssets.register_report(c.keeper, 73, ~D[2026-02-28])
    assert Decimal.eq?(hd(current.rows).accumulated, 0)

    watermarks =
      Map.take(old, [
        :through_asset_number,
        :through_event_number,
        :through_entry_number,
        :through_category_revision_id
      ])
      |> Map.to_list()

    assert {:ok, ^old} = FixedAssets.register_report(c.keeper, 73, old.as_of, watermarks)
    {:ok, next} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-02-01])
    assert Decimal.eq?(next.total, 200)
  end

  test "later charges must be reversed first and earlier run dates are refused", c do
    Fixtures.acquisition!(c)
    {:ok, jan} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    {:ok, _} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-03-01])

    assert {:error, :dependent_postings} =
             FixedAssets.reverse_run(c.keeper, 73, jan.id, %{
               effective_date: ~D[2026-03-31],
               reason: "Correct"
             })

    assert {:error, :later_activity} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-02-01])
  end

  test "all report watermarks reproduce a read after a backdated acquisition", c do
    Fixtures.acquisition!(c)
    {:ok, old} = FixedAssets.register_report(c.keeper, 73, ~D[2026-12-31])
    Fixtures.acquisition!(c)
    {:ok, newer} = FixedAssets.register_report(c.keeper, 73, ~D[2026-12-31])
    assert length(newer.rows) == 2

    assert {:ok, ^old} =
             FixedAssets.register_report(
               c.keeper,
               73,
               old.as_of,
               Map.take(old, [
                 :through_asset_number,
                 :through_event_number,
                 :through_entry_number,
                 :through_category_revision_id
               ])
               |> Map.to_list()
             )
  end

  test "category boundaries reproduce reconciliation after new defaults", c do
    {:ok, original} = FixedAssets.register_report(c.keeper, 73, ~D[2026-12-31])

    {:ok, account} =
      Ledger.create_account(c.keeper, 73, %{
        code: "new-cost",
        name: "New cost",
        account_type: "asset"
      })

    {:ok, _} =
      FixedAssets.revise_category(
        c.keeper,
        73,
        c.revision.category_id,
        Fixtures.category_attrs(c.accounts) |> Map.put(:cost_account_id, account.id)
      )

    {:ok, updated} = FixedAssets.register_report(c.keeper, 73, ~D[2026-12-31])
    assert length(updated.reconciliation) == length(original.reconciliation) + 1

    bounds =
      Map.take(original, [
        :through_asset_number,
        :through_event_number,
        :through_entry_number,
        :through_category_revision_id
      ])
      |> Map.to_list()

    assert {:ok, ^original} = FixedAssets.register_report(c.keeper, 73, original.as_of, bounds)
  end

  test "expense reconciliation survives year-end closing at the same ledger boundary", c do
    Fixtures.acquisition!(c)
    {:ok, _} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-12-01])

    {:ok, _} =
      Ledger.create_account(c.keeper, 73, %{
        code: "retained",
        name: "Retained",
        account_type: "equity",
        retained_earnings: true
      })

    {:ok, _} = Ledger.close_fiscal_year(c.keeper, 73, c.year.id)
    {:ok, report} = FixedAssets.depreciation_schedule_report(c.keeper, 73, ~D[2026-12-31])
    assert Enum.all?(report.reconciliation, &Decimal.eq?(&1.difference, 0))
    expense = Enum.find(report.reconciliation, &(&1.account_id == c.accounts.expense.id))
    assert expense.kind == :activity
    assert Decimal.eq?(expense.ledger_balance, 1200)
  end
end
