defmodule Bilimbi.Finance.Ledger.TestFixtures do
  @moduledoc """
  Ledger tables, authorization, and two tenants' companies for module tests.

  The tables are temporary copies of the migration's, constraints and
  triggers included, so a test that makes PostgreSQL refuse proves the
  migration's rule. Keep them in step with
  `priv/repo/migrations/`; `test/schema_contract_test.exs` checks the real
  migration itself.
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
  alias Ecto.Adapters.SQL

  @doc """
  Tenant 41 with companies 73 and 74, and tenant 42 with company 75, the
  ledger and Authz tables, and an Authz snapshot that knows the ledger's
  capabilities. Returns the two tenants' system scopes.
  """
  def setup_ledger! do
    CompanyFixtures.create_company_identity_tables!()
    AuthzFixtures.create_authz_tables!()
    create_ledger_tables!()
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

  @doc "An Authz snapshot over the platform's and the ledger's capabilities."
  def install_authz! do
    entries =
      for {id, app, provider} <- [
            {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
            {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
            {"finance/ledger", :bilimbi_finance_ledger, Ledger.Contributions}
          ],
          do: %{descriptor: %{id: id, otp_app: app}, payload: provider.contributions().authz}

    ContributionRegistry.put_consumers_for_test!(
      %{authz: ContributionValidator.validate_contributions!(entries)},
      "finance-ledger-test"
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

  @doc "Denies one capability directly, which overrides any allow."
  def revoke!(%Scope{} = scope, company_id, user_id, capability) do
    {:ok, :stored} =
      Authz.put_principal_capability(scope, company_id, :user, user_id, capability, false)

    :ok
  end

  @doc "Makes PostgreSQL run the ledger's deferred balance check now."
  def check_deferred_constraints! do
    SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
  end

  def create_ledger_tables! do
    Enum.each(ledger_statements(), &SQL.query!(Repo, &1, []))
  end

  defp ledger_statements do
    [
      """
      CREATE TEMPORARY TABLE finance_ledger_books (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        currency_code varchar(3) NOT NULL, minor_units smallint NOT NULL,
        inserted_at timestamp(0) NOT NULL,
        CONSTRAINT finance_ledger_books_currency_code CHECK (currency_code ~ '^[A-Z]{3}$'),
        CONSTRAINT finance_ledger_books_minor_units CHECK (minor_units BETWEEN 0 AND 4)
      ) ON COMMIT PRESERVE ROWS
      """,
      "CREATE UNIQUE INDEX finance_ledger_books_company_unique ON finance_ledger_books (company_id)",
      """
      CREATE UNIQUE INDEX finance_ledger_books_company_currency_unique
        ON finance_ledger_books (company_id, currency_code)
      """,
      """
      CREATE TEMPORARY TABLE finance_ledger_accounts (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        code varchar(50) NOT NULL, name varchar(200) NOT NULL,
        account_type varchar(16) NOT NULL, parent_id bigint,
        active boolean NOT NULL DEFAULT true,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT finance_ledger_accounts_account_type
          CHECK (account_type IN ('asset', 'liability', 'equity', 'income', 'expense')),
        CONSTRAINT finance_ledger_accounts_not_own_parent
          CHECK (parent_id IS NULL OR parent_id <> id)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_accounts_id_company_unique
        ON finance_ledger_accounts (id, company_id)
      """,
      """
      ALTER TABLE finance_ledger_accounts ADD CONSTRAINT finance_ledger_accounts_parent_fkey
        FOREIGN KEY (parent_id, company_id) REFERENCES finance_ledger_accounts (id, company_id)
        ON DELETE RESTRICT
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_accounts_company_code_unique
        ON finance_ledger_accounts (company_id, code)
      """,
      """
      CREATE TEMPORARY TABLE finance_ledger_entries (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        entry_date date NOT NULL, description varchar(500) NOT NULL, reference varchar(100),
        currency_code varchar(3) NOT NULL, reverses_entry_id bigint,
        posted_by_user_id bigint NOT NULL, posted_by_impersonator_id bigint,
        posted_at timestamp(6) NOT NULL,
        CONSTRAINT finance_ledger_entries_book_fkey FOREIGN KEY (currency_code, company_id)
          REFERENCES finance_ledger_books (currency_code, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_entries_not_own_reversal
          CHECK (reverses_entry_id IS NULL OR reverses_entry_id <> id)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_entries_id_company_unique
        ON finance_ledger_entries (id, company_id)
      """,
      """
      ALTER TABLE finance_ledger_entries ADD CONSTRAINT finance_ledger_entries_reverses_entry_fkey
        FOREIGN KEY (reverses_entry_id, company_id) REFERENCES finance_ledger_entries (id, company_id)
        ON DELETE RESTRICT
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_entries_reversed_once
        ON finance_ledger_entries (reverses_entry_id) WHERE reverses_entry_id IS NOT NULL
      """,
      """
      CREATE TEMPORARY TABLE finance_ledger_entry_lines (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        entry_id bigint NOT NULL, line_number integer NOT NULL, account_id bigint NOT NULL,
        debit numeric(20, 4) NOT NULL, credit numeric(20, 4) NOT NULL,
        description varchar(500),
        CONSTRAINT finance_ledger_entry_lines_entry_fkey FOREIGN KEY (entry_id, company_id)
          REFERENCES finance_ledger_entries (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_entry_lines_account_fkey FOREIGN KEY (account_id, company_id)
          REFERENCES finance_ledger_accounts (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_entry_lines_line_number CHECK (line_number > 0),
        CONSTRAINT finance_ledger_entry_lines_one_side
          CHECK (debit >= 0 AND credit >= 0 AND (debit = 0) <> (credit = 0))
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_entry_lines_entry_line_unique
        ON finance_ledger_entry_lines (entry_id, line_number)
      """,
      """
      CREATE FUNCTION pg_temp.finance_ledger_refuse_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'the finance ledger keeps % rows: % is refused; post a reversing entry',
          TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_ledger_accounts_keep_identity() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.tenant_id <> OLD.tenant_id OR NEW.company_id <> OLD.company_id
          OR NEW.code <> OLD.code OR NEW.account_type <> OLD.account_type THEN
          RAISE EXCEPTION 'a ledger account keeps its company, code and type'
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_ledger_refuse_posted_line() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM finance_ledger_entries
          WHERE id = NEW.entry_id
            AND pg_xact_status(
                  ((pg_current_xact_id()::text::bigint >> 32 << 32) | xmin::text::bigint)::text::xid8
                ) <> 'in progress'
        ) THEN
          RAISE EXCEPTION 'journal entry % is already posted: a line cannot be added; post a reversing entry',
            NEW.entry_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_ledger_check_balance() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        checked_id bigint;
      BEGIN
        IF TG_TABLE_NAME = 'finance_ledger_entries' THEN
          checked_id := NEW.id;
        ELSE
          checked_id := NEW.entry_id;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM finance_ledger_entry_lines WHERE entry_id = checked_id) THEN
          RAISE EXCEPTION 'journal entry % has no lines', checked_id
            USING ERRCODE = 'check_violation';
        END IF;

        IF (SELECT sum(debit) - sum(credit) FROM finance_ledger_entry_lines
            WHERE entry_id = checked_id) <> 0 THEN
          RAISE EXCEPTION 'journal entry % does not balance', checked_id
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NULL;
      END
      $$
      """,
      """
      CREATE TRIGGER finance_ledger_entry_lines_posted_entry BEFORE INSERT ON finance_ledger_entry_lines
        FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_refuse_posted_line()
      """,
      """
      CREATE TRIGGER finance_ledger_accounts_kept BEFORE DELETE ON finance_ledger_accounts
        FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_refuse_change()
      """,
      """
      CREATE TRIGGER finance_ledger_accounts_identity BEFORE UPDATE ON finance_ledger_accounts
        FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_accounts_keep_identity()
      """
    ] ++
      for(
        table <- ["finance_ledger_books", "finance_ledger_entries", "finance_ledger_entry_lines"],
        do:
          "CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table} " <>
            "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_refuse_change()"
      ) ++
      for(
        table <- [
          "finance_ledger_books",
          "finance_ledger_accounts",
          "finance_ledger_entries",
          "finance_ledger_entry_lines"
        ],
        do:
          "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} " <>
            "FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.finance_ledger_refuse_change()"
      ) ++
      for table <- ["finance_ledger_entries", "finance_ledger_entry_lines"] do
        "CREATE CONSTRAINT TRIGGER #{table}_balanced AFTER INSERT ON #{table} " <>
          "DEFERRABLE INITIALLY DEFERRED " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_check_balance()"
      end
  end
end
