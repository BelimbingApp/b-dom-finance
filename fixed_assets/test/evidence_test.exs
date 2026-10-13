defmodule Bilimbi.Finance.FixedAssets.EvidenceTest do
  use Bilimbi.Base.Database.DataCase, async: false
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.{FixedAssets, Ledger}
  alias Bilimbi.Finance.FixedAssets.TestFixtures, as: Fixtures

  setup do
    context = Fixtures.setup!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    context
  end

  test "pages populated asset records and events under the company view grant", context do
    first = Fixtures.acquisition!(context)
    second = Fixtures.acquisition!(context)

    assert {:ok, %{rows: [row], next: cursor}} =
             FixedAssets.evidence_page(context.keeper, 73, "asset", limit: 1)

    assert row.id == first.id
    assert Decimal.equal?(row.cost, Decimal.new("1200"))
    assert row.recorded_by_user_id == 91

    assert {:ok, %{rows: [following], next: nil}} =
             FixedAssets.evidence_page(context.keeper, 73, "asset", after: cursor)

    assert following.id == second.id
    assert {:ok, _run} = FixedAssets.depreciate(context.keeper, 73, ~D[2026-01-01])

    assert {:ok, disposal} =
             FixedAssets.dispose(context.keeper, 73, first.id, %{
               effective_date: ~D[2026-02-01],
               reason: "Evidence fixture disposal",
               proceeds: "1300",
               settlement_account_id: context.accounts.settlement.id
             })

    assert {:ok, %{rows: [event]}} = FixedAssets.evidence_page(context.keeper, 73, "event")
    assert event.id == disposal.id
    assert event.tenant_id == 41
    assert event.company_id == 73
    assert event.entry_id == disposal.entry_id
    assert event.action == "disposed"

    assert {:error, :invalid_option} = FixedAssets.evidence_page(context.keeper, 73, "unknown")

    assert {:error, :invalid_option} =
             FixedAssets.evidence_page(context.keeper, 73, "asset", limit: 501)

    stranger = Ledger.TestFixtures.sign_in!(context.first_scope, 73, 97, [])
    assert {:error, :unauthorized} = FixedAssets.evidence_page(stranger, 73, "asset")
    assert {:error, :company_not_found} = FixedAssets.evidence_page(context.keeper, 999, "asset")
  end
end
