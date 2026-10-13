defmodule Bilimbi.Finance.Attachments.TestFixtures do
  @moduledoc """
  Ledger, Base Artifacts, and attachments tables, authorization, and two
  tenants' companies for module tests, and for the tests of the Finance
  modules that keep source documents.

  The attachments tables are temporary copies built from the migration's own
  statements (`CreateAttachments.statements(temporary: true)`), constraints
  and triggers included, so a test that makes PostgreSQL refuse proves the
  migration's rule. Base Artifacts' tables and storage come from its own
  fixtures; `put_artifacts_root!/0` points storage at a temporary directory
  the test removes. `test/schema_contract_test.exs` checks the real
  migration itself.

  Files here are made up: a few bytes of text named like a scan or a
  statement export; no real document appears.
  """

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.ContributionValidator
  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Finance.Attachments
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Ecto.Adapters.SQL

  @migrations_path Path.expand("../../priv/repo/migrations", __DIR__)

  @migration_files [
    {20_261_017_090_000, Bilimbi.Finance.Attachments.Migrations.CreateAttachments,
     "20261017090000_create_finance_attachments.exs"}
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
  ledger, Base Artifacts (with its settings and audit tables), and
  attachments tables, and an Authz snapshot that knows the ledger's,
  Artifacts', and this module's capabilities. Returns the two tenants'
  system scopes.
  """
  def setup_attachments!(providers \\ []) do
    CompanyFixtures.create_company_identity_tables!()
    AuthzFixtures.create_authz_tables!()
    create_artifacts_tables!()
    LedgerFixtures.create_ledger_tables!()
    create_attachments_tables!()
    install_authz!(providers)

    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first_company"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "sibling_company"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "other_tenant_company"})

    {:ok, first} = Tenancy.scope(41)
    {:ok, second} = Tenancy.scope(42)
    %{first_scope: first, second_scope: second}
  end

  @doc "Base Artifacts' tables and the settings and audit tables it writes."
  def create_artifacts_tables! do
    Bilimbi.Base.Settings.TestFixtures.create_settings_table!()
    Bilimbi.Base.Audit.TestFixtures.create_audit_tables!()
    Bilimbi.Base.Artifacts.TestFixtures.create_artifacts_table!()
  end

  @doc """
  A snapshot over the platform's, Base Artifacts', the ledger's, and this
  module's capabilities and settings, plus any `providers`
  (`{id, otp_app, module}`) a dependent module's tests add.
  """
  def install_authz!(providers \\ []) do
    providers =
      [
        {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
        {"base/artifacts", :bilimbi_base_artifacts, Bilimbi.Base.Artifacts.Contributions},
        {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
        {"finance/ledger", :bilimbi_finance_ledger, Ledger.Contributions},
        {"finance/attachments", :bilimbi_finance_attachments, Attachments.Contributions}
      ] ++ providers

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
          Bilimbi.Base.Settings.ContributionValidator.validate_contributions!(entries.(:settings)),
        system_principals:
          Bilimbi.Base.Tenancy.SystemPrincipals.ContributionValidator.validate_contributions!(
            entries.(:system_principals)
          )
      },
      "finance-attachments-test"
    )
  end

  @doc """
  Points Base Artifacts at a temporary storage root the test removes, with
  the operator retention period an ordinary document would get.
  """
  def put_artifacts_root! do
    root = Path.join(System.tmp_dir!(), "finance-attachments-" <> Ecto.UUID.generate())
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _} = Settings.put("artifacts.storage_root", root)
    {:ok, _} = Settings.put("artifacts.retention_days", 30)
    root
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

  @doc "A made-up file: `%{file_name, content, content_type}`."
  def file(name \\ "scan.txt", content \\ "made-up scan", type \\ "text/plain"),
    do: %{file_name: name, content: content, content_type: type}

  @doc "Makes PostgreSQL run the deferred checks now."
  def check_deferred_constraints! do
    SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
  end

  def create_attachments_tables! do
    # The migrations are loaded at run time, so the calls are dynamic.
    for {_version, module} <- migrations(),
        statement <- apply(module, :statements, [[temporary: true]]) do
      SQL.query!(Repo, statement, [])
    end
  end
end
