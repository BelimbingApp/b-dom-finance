defmodule Bilimbi.Finance.FixedAssets.AssetsTest do
  use Bilimbi.Base.Database.DataCase, async: false
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.{FixedAssets, Ledger, Payables}
  alias Bilimbi.Finance.FixedAssets.TestFixtures, as: Fixtures
  alias Ecto.Adapters.SQL

  setup do
    context = Fixtures.setup!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    context
  end

  test "derives cost from a posted debit; refused registration consumes no asset number", c do
    asset = Fixtures.acquisition!(c)
    assert asset.asset_number == 1
    assert Decimal.eq?(asset.cost, 1200)
    assert asset.recorded_by_user_id == 91
    assert asset.recorded_at

    attrs = %{
      entry_id: asset.entry_id,
      entry_line_number: 1,
      category_revision_id: c.revision.id,
      description: "Duplicate",
      in_service_date: ~D[2026-01-01]
    }

    assert {:error, %Ecto.Changeset{}} = FixedAssets.acquire_from_entry(c.keeper, 73, attrs)
    second = Fixtures.acquisition!(c)
    assert second.asset_number == 2

    assert {:error, :not_acquisition_debit} =
             FixedAssets.acquire_from_entry(c.keeper, 73, %{attrs | entry_line_number: 2})
  end

  test "a category's new defaults never change an acquired asset", c do
    asset = Fixtures.acquisition!(c)

    {:ok, revision} =
      FixedAssets.revise_category(c.keeper, 73, c.revision.category_id, %{
        Fixtures.category_attrs(c.accounts)
        | life_months: 24,
          reason: "New life"
      })

    assert revision.id != c.revision.id
    {:ok, detail} = FixedAssets.get_asset(c.keeper, 73, asset.id)
    assert detail.asset.life_months == 12
    assert detail.revision.id == c.revision.id
    {:ok, [category]} = FixedAssets.list_categories(c.keeper, 73)
    assert length(category.revisions) == 2
  end

  test "acquires a posted supplier bill line using the payables facade", c do
    {:ok, bill} =
      Payables.create_bill(c.keeper, 73, %{
        party_key: "party",
        party_name: "Party",
        party_document_number: "B-1",
        document_date: ~D[2026-01-01],
        lines: [%{description: "Acquisition", account_id: c.accounts.cost.id, amount: "600"}]
      })

    attrs = %{
      bill_id: bill.id,
      bill_line_number: 1,
      category_revision_id: c.revision.id,
      description: "Asset",
      in_service_date: ~D[2026-01-01]
    }

    assert {:error, :bill_not_posted} = FixedAssets.acquire_from_bill(c.keeper, 73, attrs)
    assert {:error, :same_person} = Payables.approve_document(c.keeper, 73, bill.id)

    approver =
      Payables.TestFixtures.sign_in!(c.first_scope, 73, 92, [
        "finance.payables.documents.approve",
        "finance.ledger.view"
      ])

    {:ok, _} = Payables.approve_document(approver, 73, bill.id)
    {:ok, posted} = Payables.post_document(c.keeper, 73, bill.id)
    {:ok, asset} = FixedAssets.acquire_from_bill(c.keeper, 73, attrs)
    assert asset.entry_id == posted.entry_id
    assert asset.bill_id == bill.id
    assert Decimal.eq?(asset.cost, 600)
  end

  test "each action rechecks capability and company reach; system scopes cannot act", c do
    assert {:error, :unauthorized} = FixedAssets.list_categories(c.first_scope, 73)
    assert {:error, :company_not_found} = FixedAssets.list_categories(c.keeper, 75)
    asset = Fixtures.acquisition!(c)
    assert {:error, :unauthorized} = FixedAssets.get_asset(c.keeper, 74, asset.id)

    {:ok, :stored} =
      Authz.put_principal_capability(
        c.first_scope,
        73,
        :user,
        91,
        FixedAssets.depreciate_capability(),
        false
      )

    assert {:error, :unauthorized} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])

    {:ok, :stored} =
      Authz.put_principal_capability(
        c.first_scope,
        73,
        :user,
        91,
        FixedAssets.acquire_capability(),
        false
      )

    assert {:error, :unauthorized} = FixedAssets.acquire_from_entry(c.keeper, 73, %{})
  end

  test "asset records, revisions and items refuse update and deletion in PostgreSQL", c do
    asset = Fixtures.acquisition!(c)
    {:ok, _run} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    Ledger.TestFixtures.check_deferred_constraints!()

    for statement <- [
          "UPDATE finance_fixed_assets_assets SET cost = 1 WHERE id = #{asset.id}",
          "DELETE FROM finance_fixed_assets_category_revisions",
          "TRUNCATE finance_fixed_assets_run_items"
        ] do
      assert_raise Postgrex.Error, ~r/retain every record/, fn ->
        Repo.transaction(fn -> SQL.query!(Repo, statement, []) end)
      end
    end
  end

  test "book precision and residual ceiling are validated", c do
    {:ok, entry} =
      Ledger.post_entry(c.keeper, 73, %{
        entry_date: ~D[2026-01-01],
        description: "Acquisition",
        lines: [
          %{account_id: c.accounts.cost.id, debit: "10"},
          %{account_id: c.accounts.payable.id, credit: "10"}
        ]
      })

    attrs = %{
      entry_id: entry.id,
      entry_line_number: 1,
      category_revision_id: c.revision.id,
      description: "Asset",
      in_service_date: ~D[2026-01-01],
      residual_value: "10.001"
    }

    assert {:error, %Ecto.Changeset{}} = FixedAssets.acquire_from_entry(c.keeper, 73, attrs)

    assert {:error, %Ecto.Changeset{}} =
             FixedAssets.acquire_from_entry(c.keeper, 73, %{attrs | residual_value: "11"})
  end

  test "configuration, disposal, reversal and every read reauthorize independently", c do
    for {capability, action} <- [
          {FixedAssets.configure_capability(),
           fn -> FixedAssets.create_category(c.keeper, 73, %{}) end},
          {FixedAssets.dispose_capability(), fn -> FixedAssets.dispose(c.keeper, 73, 0, %{}) end},
          {FixedAssets.reverse_capability(),
           fn -> FixedAssets.reverse_run(c.keeper, 73, 0, %{}) end},
          {FixedAssets.void_capability(),
           fn -> FixedAssets.void_acquisition(c.keeper, 73, 0, %{}) end}
        ] do
      {:ok, :stored} =
        Authz.put_principal_capability(c.first_scope, 73, :user, 91, capability, false)

      assert {:error, :unauthorized} = action.()
    end

    {:ok, :stored} =
      Authz.put_principal_capability(
        c.first_scope,
        73,
        :user,
        91,
        FixedAssets.view_capability(),
        false
      )

    for action <- [
          fn -> FixedAssets.list_categories(c.keeper, 73) end,
          fn -> FixedAssets.list_runs(c.keeper, 73) end,
          fn -> FixedAssets.get_asset(c.keeper, 73, 0) end,
          fn -> FixedAssets.register_report(c.keeper, 73, ~D[2026-01-31]) end,
          fn -> FixedAssets.depreciation_schedule_report(c.keeper, 73, ~D[2026-01-31]) end
        ],
        do: assert({:error, :unauthorized} = action.())
  end

  test "an archived company remains readable and refuses all asset writes", c do
    asset = Fixtures.acquisition!(c)
    SQL.query!(Repo, "UPDATE companies SET status = 'archived' WHERE id = 73", [])
    assert {:ok, _} = FixedAssets.get_asset(c.keeper, 73, asset.id)
    assert {:error, :company_archived} = FixedAssets.create_category(c.keeper, 73, %{})
    assert {:error, :company_archived} = FixedAssets.acquire_from_entry(c.keeper, 73, %{})
    assert {:error, :company_archived} = FixedAssets.depreciate(c.keeper, 73, ~D[2026-01-01])
    assert {:error, :company_archived} = FixedAssets.dispose(c.keeper, 73, asset.id, %{})
    assert {:error, :company_archived} = FixedAssets.reverse_run(c.keeper, 73, 0, %{})
    assert {:error, :company_archived} = FixedAssets.void_acquisition(c.keeper, 73, asset.id, %{})
  end

  test "impersonated operations record both identities from the sealed scope", c do
    Payables.TestFixtures.sign_in!(c.first_scope, 73, 95, Fixtures.capabilities())

    actor =
      Bilimbi.Base.Tenancy.Authentication.sign_in(c.first_scope, 95, 73,
        impersonator_id: 91,
        impersonation_session_id: "asset-test-session"
      )

    {:ok, revision} =
      FixedAssets.create_category(
        actor,
        73,
        Fixtures.category_attrs(c.accounts) |> Map.put(:name, "Other category")
      )

    assert revision.recorded_by_user_id == 95
    assert revision.recorded_by_impersonator_id == 91
  end
end
