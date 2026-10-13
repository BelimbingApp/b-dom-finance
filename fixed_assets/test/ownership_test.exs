defmodule Bilimbi.Finance.FixedAssets.OwnershipTest do
  use Bilimbi.Base.Database.DataCase, async: false
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.{FixedAssets, Ledger}
  alias Bilimbi.Finance.FixedAssets.TestFixtures, as: Fixtures

  @module "finance/fixed_assets"

  setup do
    context = Fixtures.setup!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    context
  end

  defp reverse(c, entry_id, date \\ ~D[2026-03-01]) do
    Ledger.reverse_entry(c.keeper, 73, entry_id, %{entry_date: date, description: "Undo"})
  end

  test "a depreciation run owns its entry, which only reverse_run/4 reverses", c do
    _asset = Fixtures.acquisition!(c)
    {:ok, run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    owner = %{module: @module, record: "run:#{run.id}"}

    assert {:ok, %{owner: ^owner}} = Ledger.get_entry(c.keeper, 73, run.entry_id)
    assert {:error, {:owned_by, ^owner}} = reverse(c, run.entry_id)

    {:ok, event} =
      FixedAssets.reverse_run(c.keeper, 73, run.id, %{
        effective_date: ~D[2026-02-01],
        reason: "Wrong rate"
      })

    assert {:ok, %{owner: ^owner, reverses_entry_id: reverses}} =
             Ledger.get_entry(c.keeper, 73, event.entry_id)

    assert reverses == run.entry_id
    {:ok, report} = FixedAssets.register_report(c.keeper, 73, ~D[2026-02-01])
    assert Enum.all?(report.reconciliation, &Decimal.eq?(&1.difference, 0))
  end

  test "a disposal owns its entry, which only reverse_disposal/4 reverses", c do
    asset = Fixtures.acquisition!(c)
    {:ok, _run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])

    {:ok, disposal} =
      FixedAssets.dispose(c.keeper, 73, asset.id, %{
        effective_date: ~D[2026-02-01],
        reason: "Scrapped",
        proceeds: "0"
      })

    owner = %{module: @module, record: "event:#{disposal.id}"}
    assert {:ok, %{owner: ^owner}} = Ledger.get_entry(c.keeper, 73, disposal.entry_id)
    assert {:error, {:owned_by, ^owner}} = reverse(c, disposal.entry_id)

    {:ok, reversal} =
      FixedAssets.reverse_disposal(c.keeper, 73, asset.id, %{
        effective_date: ~D[2026-02-02],
        reason: "Not scrapped"
      })

    assert {:ok, %{owner: ^owner, reverses_entry_id: reverses}} =
             Ledger.get_entry(c.keeper, 73, reversal.entry_id)

    assert reverses == disposal.entry_id
  end

  test "a void's mirror entry and a partial run reversal's mirror are the event's own", c do
    first = Fixtures.acquisition!(c)
    _second = Fixtures.acquisition!(c)
    {:ok, run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])

    # The acquisition entry belongs to whoever posted it, here a manual
    # journal, and is reversed there; the void then mirrors the charges.
    {:ok, _} = reverse(c, first.entry_id, ~D[2026-02-01])

    {:ok, void} =
      FixedAssets.void_acquisition(c.keeper, 73, first.id, %{
        effective_date: ~D[2026-02-01],
        reason: "Acquisition cancelled"
      })

    void_owner = %{module: @module, record: "event:#{void.id}"}

    assert {:ok, %{owner: ^void_owner, reverses_entry_id: nil}} =
             Ledger.get_entry(c.keeper, 73, void.entry_id)

    assert {:error, {:owned_by, ^void_owner}} = reverse(c, void.entry_id)

    # With one asset voided, the run's reversal mirrors the live charge
    # rather than reversing the run's entry.
    {:ok, event} =
      FixedAssets.reverse_run(c.keeper, 73, run.id, %{
        effective_date: ~D[2026-02-02],
        reason: "Wrong rate"
      })

    event_owner = %{module: @module, record: "event:#{event.id}"}

    assert {:ok, %{owner: ^event_owner, reverses_entry_id: nil}} =
             Ledger.get_entry(c.keeper, 73, event.entry_id)

    assert {:ok, %{reversed_by_entry_id: nil}} = Ledger.get_entry(c.keeper, 73, run.entry_id)
    {:ok, report} = FixedAssets.register_report(c.keeper, 73, ~D[2026-02-02])
    assert Enum.all?(report.reconciliation, &Decimal.eq?(&1.difference, 0))
  end
end
