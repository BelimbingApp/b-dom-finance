defmodule Bilimbi.Finance.Payables.TestFixtures do
  @moduledoc """
  Ledger and payables tables, authorization, and two tenants' companies for
  module tests.

  The payables tables are temporary copies built from the migration's own
  statements (`CreatePayables.statements(temporary: true)`), constraints
  and triggers included, so a test that makes PostgreSQL refuse proves the
  migration's rule. The ledger's come from its own fixtures.
  `test/schema_contract_test.exs` checks the real migration itself.
  """

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.ContributionValidator
  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Payables
  alias Ecto.Adapters.SQL

  @migration Path.expand(
               "../../priv/repo/migrations/20261012213700_create_finance_payables.exs",
               __DIR__
             )

  @doc "The migration module, loaded from its file once."
  def migration do
    module = Bilimbi.Finance.Payables.Migrations.CreatePayables
    unless Code.ensure_loaded?(module), do: Code.require_file(@migration)
    module
  end

  @doc """
  Tenant 41 with companies 73 and 74, and tenant 42 with company 75, the
  ledger, payables, and Authz tables, and an Authz snapshot that knows the
  ledger's and payables' capabilities. Returns the two tenants' system
  scopes.
  """
  def setup_payables! do
    CompanyFixtures.create_company_identity_tables!()
    AuthzFixtures.create_authz_tables!()
    LedgerFixtures.create_ledger_tables!()
    create_payables_tables!()
    install_authz!()

    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first_company"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "sibling_company"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "other_tenant_company"})

    {:ok, first} = Tenancy.scope(41)
    {:ok, second} = Tenancy.scope(42)
    %{first_scope: first, second_scope: second}
  end

  @doc "An Authz snapshot over the platform's, the ledger's, and payables' capabilities."
  def install_authz! do
    entries =
      for {id, app, provider} <- [
            {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
            {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
            {"finance/ledger", :bilimbi_finance_ledger, Ledger.Contributions},
            {"finance/payables", :bilimbi_finance_payables, Payables.Contributions}
          ],
          do: %{descriptor: %{id: id, otp_app: app}, payload: provider.contributions().authz}

    ContributionRegistry.put_consumers_for_test!(
      %{authz: ContributionValidator.validate_contributions!(entries)},
      "finance-payables-test"
    )
  end

  @doc """
  A scope signed in as the user, after granting the capabilities directly
  in the company. Tests are the only module code that calls the edge.
  """
  def sign_in!(%Scope{} = scope, company_id, user_id, capabilities) do
    for capability <- capabilities do
      {:ok, :stored} =
        Authz.put_principal_capability(scope, company_id, :user, user_id, capability, true)
    end

    Authentication.sign_in(scope, user_id, company_id)
  end

  @doc "Makes PostgreSQL run the deferred checks now."
  def check_deferred_constraints! do
    SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
  end

  def create_payables_tables! do
    # The migration is loaded at run time, so the call is dynamic.
    migration()
    |> apply(:statements, [[temporary: true]])
    |> Enum.each(&SQL.query!(Repo, &1, []))
  end
end
