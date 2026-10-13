defmodule Bilimbi.Finance.Reconciliation.TestFixtures do
  @moduledoc """
  Ledger and reconciliation tables, authorization, and two tenants'
  companies for module tests.

  The reconciliation tables are temporary copies built from the migration's
  own statements (`CreateReconciliation.statements(temporary: true)`),
  constraints and triggers included, so a test that makes PostgreSQL refuse
  proves the migration's rule. The ledger's come from its own fixtures.
  `test/schema_contract_test.exs` checks the real migration itself.

  Bank data here is made up: a bank account called "Operating account", a
  test currency, and descriptions such as "Transfer in".
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
  alias Bilimbi.Finance.Reconciliation
  alias Ecto.Adapters.SQL

  @migrations_path Path.expand("../../priv/repo/migrations", __DIR__)

  @migration_files [
    {20_261_014_090_000, Bilimbi.Finance.Reconciliation.Migrations.CreateReconciliation,
     "20261014090000_create_finance_reconciliation.exs"},
    {20_261_015_150_600, Bilimbi.Finance.Reconciliation.Migrations.ClaimEntries,
     "20261015150600_claim_finance_reconciliation_entries.exs"},
    {20_261_017_090_100, Bilimbi.Finance.Reconciliation.Migrations.AddImportMapping,
     "20261017090100_add_finance_reconciliation_import_mapping.exs"}
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
  ledger, reconciliation, and Authz tables, and an Authz snapshot that knows
  the ledger's and this module's capabilities. Returns the two tenants'
  system scopes.
  """
  def setup_reconciliation! do
    CompanyFixtures.create_company_identity_tables!()
    AuthzFixtures.create_authz_tables!()
    AttachmentsFixtures.create_artifacts_tables!()
    LedgerFixtures.create_ledger_tables!()
    AttachmentsFixtures.create_attachments_tables!()
    create_reconciliation_tables!()
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
  attachments', and this module's capabilities (the attachments fixtures'
  own, plus this module's).
  """
  def install_authz! do
    AttachmentsFixtures.install_authz!([
      {"finance/reconciliation", :bilimbi_finance_reconciliation, Reconciliation.Contributions}
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

  def create_reconciliation_tables! do
    # The migrations are loaded at run time, so the calls are dynamic.
    for {_version, module} <- migrations(),
        statement <- apply(module, :statements, [[temporary: true]]) do
      SQL.query!(Repo, statement, [])
    end
  end

  @doc """
  CSV text from `rows`, each a list of cells, with a header row of
  `Date,Description,Reference,Amount,Balance` unless `header: false`.
  """
  def csv(rows, options \\ []) do
    header = Keyword.get(options, :header, ~w(Date Description Reference Amount Balance))
    delimiter = Keyword.get(options, :delimiter, ",")
    all = if header, do: [header | rows], else: rows

    Enum.map_join(all, "\n", fn row ->
      Enum.map_join(row, delimiter, fn cell ->
        text = to_string(cell)

        if String.contains?(text, [delimiter, "\"", "\n"]),
          do: "\"" <> String.replace(text, "\"", "\"\"") <> "\"",
          else: text
      end)
    end) <> "\n"
  end

  @doc "The import mapping the shared case's bank account uses: header-named columns with a running balance."
  def mapping do
    %{
      "date" => "Date",
      "description" => "Description",
      "reference" => "Reference",
      "amount" => "Amount",
      "balance" => "Balance"
    }
  end
end
