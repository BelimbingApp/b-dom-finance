defmodule Bilimbi.Finance.FixedAssets.DisposalTest do
  use Bilimbi.Base.Database.DataCase, async: false
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.{FixedAssets, Ledger}
  alias Bilimbi.Finance.FixedAssets.TestFixtures, as: Fixtures

  setup do
    context = Fixtures.setup!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    context
  end

  test "sale removes cost and depreciation and posts the exact gain; reversal restores them", c do
    asset = Fixtures.acquisition!(c)
    {:ok, run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])

    attrs = %{
      effective_date: ~D[2026-02-01],
      reason: "Sold",
      proceeds: "1300",
      settlement_account_id: c.accounts.settlement.id
    }

    {:ok, disposal} = FixedAssets.dispose(c.keeper, 73, asset.id, attrs)
    {:ok, entry} = Ledger.get_entry(c.keeper, 73, disposal.entry_id)
    gain = Enum.find(entry.lines, &(&1.account_id == c.accounts.gain.id))
    assert Decimal.eq?(gain.credit, 200)
    {:ok, report} = FixedAssets.register_report(c.keeper, 73, ~D[2026-02-01])
    assert hd(report.rows).disposed?
    assert Enum.all?(report.reconciliation, &Decimal.eq?(&1.difference, 0))
    assert {:error, :already_disposed} = FixedAssets.dispose(c.keeper, 73, asset.id, attrs)

    assert {:error, :dependent_postings} =
             FixedAssets.reverse_run(
               c.keeper,
               73,
               run.id,
               Map.take(attrs, [:effective_date, :reason])
             )

    {:ok, reversal} =
      FixedAssets.reverse_disposal(c.keeper, 73, asset.id, %{
        effective_date: ~D[2026-02-02],
        reason: "Sale cancelled"
      })

    assert reversal.reverses_event_id == disposal.id
    {:ok, restored} = FixedAssets.register_report(c.keeper, 73, ~D[2026-02-02])
    refute hd(restored.rows).disposed?
    assert Decimal.eq?(hd(restored.rows).carrying_value, 1100)
    assert Enum.all?(restored.reconciliation, &Decimal.eq?(&1.difference, 0))

    assert {:error, :not_disposed} =
             FixedAssets.reverse_disposal(c.keeper, 73, asset.id, %{
               effective_date: ~D[2026-02-02],
               reason: "Again"
             })
  end

  test "write-off posts remaining carrying value as loss and requires depreciation through completed months",
       c do
    asset = Fixtures.acquisition!(c)
    attrs = %{effective_date: ~D[2026-02-01], reason: "Written off", proceeds: "0"}
    assert {:error, :depreciation_required} = FixedAssets.dispose(c.keeper, 73, asset.id, attrs)
    {:ok, _} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    {:ok, disposal} = FixedAssets.dispose(c.keeper, 73, asset.id, attrs)
    {:ok, entry} = Ledger.get_entry(c.keeper, 73, disposal.entry_id)
    loss = Enum.find(entry.lines, &(&1.account_id == c.accounts.loss.id))
    assert Decimal.eq?(loss.debit, 1100)
    {:ok, empty} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-02-01])
    assert Decimal.eq?(empty.total, 0)
    Ledger.TestFixtures.check_deferred_constraints!()
  end
end
