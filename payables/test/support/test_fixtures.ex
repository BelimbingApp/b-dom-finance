defmodule Bilimbi.Finance.Payables.TestFixtures do
  @moduledoc """
  Ledger and payables tables, authorization, and two tenants' companies for
  module tests.

  The payables tables are temporary copies built from the migrations' own
  statements (each migration's `statements(temporary: true)`, in version
  order), constraints and triggers included, so a test that makes
  PostgreSQL refuse proves a migration's rule. The ledger's come from its
  own fixtures. `test/schema_contract_test.exs` checks the real migrations
  themselves.
  """

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Finance.Attachments.TestFixtures, as: AttachmentsFixtures
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Payables
  alias Ecto.Adapters.SQL

  @migrations_path Path.expand("../../priv/repo/migrations", __DIR__)

  @migration_files [
    {20_261_012_213_700, Bilimbi.Finance.Payables.Migrations.CreatePayables,
     "20261012213700_create_finance_payables.exs"},
    {20_261_014_100_000, Bilimbi.Finance.Payables.Migrations.AddMatching,
     "20261014100000_add_finance_payables_matching.exs"},
    {20_261_015_150_200, Bilimbi.Finance.Payables.Migrations.ClaimEntries,
     "20261015150200_claim_finance_payables_entries.exs"},
    {20_261_016_100_100, Bilimbi.Finance.Payables.Migrations.AddPaymentRequests,
     "20261016100100_add_finance_payables_payment_requests.exs"}
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
  ledger, attachments (with Base Artifacts'), payables, and Authz tables,
  and an Authz snapshot that knows the ledger's, attachments', and payables'
  capabilities. Returns the two tenants' system scopes.
  """
  def setup_payables! do
    CompanyFixtures.create_company_identity_tables!()
    AuthzFixtures.create_authz_tables!()
    AttachmentsFixtures.create_artifacts_tables!()
    LedgerFixtures.create_ledger_tables!()
    AttachmentsFixtures.create_attachments_tables!()
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

  @doc """
  An Authz snapshot over the platform's, Base Artifacts', the ledger's,
  attachments', and payables' capabilities (the attachments fixtures' own,
  plus payables').
  """
  def install_authz! do
    AttachmentsFixtures.install_authz!([
      {"finance/payables", :bilimbi_finance_payables, Payables.Contributions}
    ])
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
    # The migrations are loaded at run time, so the calls are dynamic.
    for {_version, module} <- migrations(),
        statement <- apply(module, :statements, [[temporary: true]]) do
      SQL.query!(Repo, statement, [])
    end
  end
end
