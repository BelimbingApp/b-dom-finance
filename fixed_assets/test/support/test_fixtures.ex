defmodule Bilimbi.Finance.FixedAssets.TestFixtures do
  @moduledoc false
  alias Bilimbi.Base.Authz.ContributionValidator
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.{FixedAssets, Ledger, Payables}
  alias Ecto.Adapters.SQL

  def migration do
    module = Bilimbi.Finance.FixedAssets.Migrations.CreateFixedAssets

    unless Code.ensure_loaded?(module),
      do:
        Code.require_file(
          Path.expand(
            "../../priv/repo/migrations/20261015110000_create_finance_fixed_assets.exs",
            __DIR__
          )
        )

    module
  end

  def create_tables! do
    for statement <- apply(migration(), :statements, [[temporary: true]]),
        do: SQL.query!(Repo, statement, [])
  end

  def capabilities,
    do:
      FixedAssets.capabilities() ++
        Bilimbi.Finance.Payables.PayablesCase.all_capabilities() ++
        ~w(finance.ledger.periods.manage finance.ledger.periods.reopen)

  def install_authz! do
    entries =
      for {id, app, provider} <- [
            {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
            {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
            {"finance/ledger", :bilimbi_finance_ledger, Ledger.Contributions},
            {"finance/payables", :bilimbi_finance_payables, Payables.Contributions},
            {"finance/fixed_assets", :bilimbi_finance_fixed_assets, FixedAssets.Contributions}
          ],
          do: %{descriptor: %{id: id, otp_app: app}, payload: provider.contributions().authz}

    ContributionRegistry.put_consumers_for_test!(
      %{authz: ContributionValidator.validate_contributions!(entries)},
      "fixed-assets-test"
    )
  end

  def setup! do
    context = Payables.TestFixtures.setup_payables!()
    create_tables!()
    install_authz!()
    keeper = Payables.TestFixtures.sign_in!(context.first_scope, 73, 91, capabilities())
    Map.merge(context, prepare_book!(keeper))
  end

  def prepare_book!(keeper) do
    {:ok, _} = Ledger.open_book(keeper, 73, %{currency_code: "XTS", minor_units: 2})
    {:ok, year} = Ledger.open_fiscal_year(keeper, 73, %{start_date: ~D[2026-01-01]})

    accounts =
      for {key, type} <- [
            cost: "asset",
            accumulated: "asset",
            expense: "expense",
            gain: "income",
            loss: "expense",
            settlement: "asset",
            payable: "liability"
          ],
          into: %{} do
        {:ok, account} =
          Ledger.create_account(keeper, 73, %{
            code: Atom.to_string(key),
            name: Atom.to_string(key),
            account_type: type
          })

        {key, account}
      end

    {:ok, _} = Payables.put_settings(keeper, 73, %{payable_account_id: accounts.payable.id})
    {:ok, revision} = FixedAssets.create_category(keeper, 73, category_attrs(accounts))
    %{keeper: keeper, accounts: accounts, revision: revision, year: year}
  end

  def category_attrs(accounts),
    do: %{
      name: "Category",
      cost_account_id: accounts.cost.id,
      accumulated_account_id: accounts.accumulated.id,
      expense_account_id: accounts.expense.id,
      gain_account_id: accounts.gain.id,
      loss_account_id: accounts.loss.id,
      method: "straight_line",
      life_months: 12,
      reason: "Initial defaults"
    }

  def acquisition!(context, extra \\ %{}) do
    {:ok, entry} =
      Ledger.post_entry(context.keeper, 73, %{
        entry_date: ~D[2026-01-01],
        description: "Acquisition",
        lines: [
          %{account_id: context.accounts.cost.id, debit: "1200"},
          %{account_id: context.accounts.payable.id, credit: "1200"}
        ]
      })

    {:ok, asset} =
      FixedAssets.acquire_from_entry(
        context.keeper,
        73,
        Map.merge(
          %{
            category_revision_id: context.revision.id,
            entry_id: entry.id,
            entry_line_number: 1,
            description: "Asset",
            in_service_date: ~D[2026-01-01]
          },
          extra
        )
      )

    asset
  end
end
