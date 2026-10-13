defmodule Bilimbi.Finance.Payroll.TestFixtures do
  @moduledoc """
  Ledger and payroll tables, authorization, and two tenants' companies for
  module tests.

  The payroll tables are temporary copies built from the migration's own
  statements (`CreatePayroll.statements(temporary: true)`), constraints and
  triggers included, so a test that makes PostgreSQL refuse proves the
  migration's rule. The ledger's come from its own fixtures.
  `test/schema_contract_test.exs` checks the real migration itself.

  Payroll data here is made up: pay item codes such as `basic`, a test
  currency, and whole-number amounts; no person, salary, or identity number
  appears.
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
  alias Bilimbi.Finance.Payroll
  alias Ecto.Adapters.SQL

  @migrations_path Path.expand("../../priv/repo/migrations", __DIR__)

  @migration_files [
    {20_261_015_120_000, Bilimbi.Finance.Payroll.Migrations.CreatePayroll,
     "20261015120000_create_finance_payroll.exs"}
  ]

  @doc "The first migration's module, loaded from its file once."
  def migration, do: migrations() |> hd() |> elem(1)

  @doc "The module's migrations as `{version, module}` in version order, each loaded once."
  def migrations do
    for {version, module, file} <- @migration_files do
      unless Code.ensure_loaded?(module),
        do: Code.require_file(Path.join(@migrations_path, file))

      {version, module}
    end
  end

  @doc """
  Tenant 41 with companies 73 and 74, and tenant 42 with company 75, the
  ledger, payroll, and Authz tables, and an Authz snapshot that knows the
  ledger's and this module's capabilities. Returns the two tenants' system
  scopes.
  """
  def setup_payroll! do
    CompanyFixtures.create_company_identity_tables!()
    AuthzFixtures.create_authz_tables!()
    Bilimbi.Base.Settings.TestFixtures.create_settings_table!()
    LedgerFixtures.create_ledger_tables!()
    create_payroll_tables!()
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

  @doc """
  A snapshot over the platform's, the ledger's, and this module's capabilities,
  and the company time zone setting Base DateTime defines.
  """
  def install_authz! do
    providers = [
      {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
      {"base/datetime", :bilimbi_base_datetime, Bilimbi.Base.DateTime.Contributions},
      {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
      {"finance/ledger", :bilimbi_finance_ledger, Ledger.Contributions},
      {"finance/payroll", :bilimbi_finance_payroll, Payroll.Contributions}
    ]

    entries = fn key ->
      for {id, app, provider} <- providers,
          payload = Map.get(provider.contributions(), key),
          payload != nil,
          do: %{descriptor: %{id: id, otp_app: app}, payload: payload}
    end

    ContributionRegistry.put_consumers_for_test!(
      %{
        authz: ContributionValidator.validate_contributions!(entries.(:authz)),
        settings:
          Bilimbi.Base.Settings.ContributionValidator.validate_contributions!(entries.(:settings))
      },
      "finance-payroll-test"
    )
  end

  @doc "Sets the company's time zone, as its profile does."
  def put_company_timezone!(%Scope{} = scope, company_id, timezone) do
    {:ok, _} =
      Bilimbi.Base.Settings.put(
        "localization.timezone",
        timezone,
        Bilimbi.Base.Settings.Scope.company(company_id, Scope.tenant_id(scope))
      )

    :ok
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

  @doc "Denies one capability directly, which overrides any allow."
  def revoke!(%Scope{} = scope, company_id, user_id, capability) do
    {:ok, :stored} =
      Authz.put_principal_capability(scope, company_id, :user, user_id, capability, false)

    :ok
  end

  @doc "Makes PostgreSQL run the deferred checks now."
  def check_deferred_constraints! do
    SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
  end

  def create_payroll_tables! do
    # The migrations are loaded at run time, so the calls are dynamic.
    for {_version, module} <- migrations(),
        statement <- apply(module, :statements, [[temporary: true]]) do
      SQL.query!(Repo, statement, [])
    end
  end
end
