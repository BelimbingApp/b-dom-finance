defmodule Bilimbi.Finance.Ledger.TestFixtures do
  @moduledoc """
  Ledger tables, authorization, and two tenants' companies for module tests.

  The tables are temporary copies of the migrations', constraints and
  triggers included, so a test that makes PostgreSQL refuse proves the
  migration's rule. Keep them in step with
  `priv/repo/migrations/`; `test/schema_contract_test.exs` checks the real
  migrations themselves. The closing rules' functions are the closing
  migration's own, created in `pg_temp`, and the entry owner and duty separation
  migrations' statements run as they are (`statements(temporary: true)`).
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

  @closing_migration Path.expand(
                       "../../priv/repo/migrations/20261013101700_create_finance_ledger_closing.exs",
                       __DIR__
                     )

  @duty_separation_migration Path.expand(
                               "../../priv/repo/migrations/20261016100000_add_finance_ledger_duty_separation.exs",
                               __DIR__
                             )

  @owner_migration Path.expand(
                     "../../priv/repo/migrations/20261015150000_add_finance_ledger_entry_owner.exs",
                     __DIR__
                   )

  @migrations_path Path.expand("../../priv/repo/migrations", __DIR__)

  @migration_files [
    {20_261_012_170_100, Bilimbi.Finance.Ledger.Migrations.CreateLedger,
     "20261012170100_create_finance_ledger.exs"},
    {20_261_012_214_100, Bilimbi.Finance.Ledger.Migrations.NotifyPostings,
     "20261012214100_notify_finance_ledger_postings.exs"},
    {20_261_013_101_700, Bilimbi.Finance.Ledger.Migrations.CreateClosing,
     "20261013101700_create_finance_ledger_closing.exs"},
    {20_261_015_150_000, Bilimbi.Finance.Ledger.Migrations.AddEntryOwner,
     "20261015150000_add_finance_ledger_entry_owner.exs"},
    {20_261_016_100_000, Bilimbi.Finance.Ledger.Migrations.AddDutySeparation,
     "20261016100000_add_finance_ledger_duty_separation.exs"}
  ]

  @doc """
  The ledger's migrations as `{version, module}` in version order, each
  loaded once, for a sibling module's fresh-database contract test that
  runs them before its own (a module that claims its legacy entries needs
  the ledger's claim function).
  """
  def migrations do
    for {version, module, file} <- @migration_files do
      unless Code.ensure_loaded?(module),
        do: Code.require_file(Path.join(@migrations_path, file))

      {version, module}
    end
  end

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
    Enum.each(
      ledger_statements() ++
        closing_statements() ++ owner_statements() ++ duty_separation_statements(),
      &SQL.query!(Repo, &1, [])
    )
  end

  # The duty separation migration's own statements, over the copies above.
  defp duty_separation_statements do
    migration = Bilimbi.Finance.Ledger.Migrations.AddDutySeparation

    unless Code.ensure_loaded?(migration), do: Code.require_file(@duty_separation_migration)

    apply(migration, :statements, [[temporary: true]])
  end

  # The migrations are scripts, not compiled module code; load each once.
  defp closing_functions do
    migration = Bilimbi.Finance.Ledger.Migrations.CreateClosing

    unless Code.ensure_loaded?(migration), do: Code.require_file(@closing_migration)

    apply(migration, :functions, ["pg_temp."])
  end

  # The owner migration's own SQL, which alters the temporary entries table
  # and replaces its update trigger as the migration does.
  defp owner_statements do
    migration = Bilimbi.Finance.Ledger.Migrations.AddEntryOwner

    unless Code.ensure_loaded?(migration), do: Code.require_file(@owner_migration)

    apply(migration, :statements, [[temporary: true]])
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
        retained_earnings boolean NOT NULL DEFAULT false,
        CONSTRAINT finance_ledger_accounts_account_type
          CHECK (account_type IN ('asset', 'liability', 'equity', 'income', 'expense')),
        CONSTRAINT finance_ledger_accounts_not_own_parent
          CHECK (parent_id IS NULL OR parent_id <> id),
        CONSTRAINT finance_ledger_accounts_retained_earnings_equity
          CHECK (NOT retained_earnings OR account_type = 'equity')
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_accounts_one_retained_earnings
        ON finance_ledger_accounts (company_id) WHERE retained_earnings
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
        entry_number bigint NOT NULL, entry_date date NOT NULL, description varchar(500) NOT NULL, reference varchar(100),
        currency_code varchar(3) NOT NULL, reverses_entry_id bigint,
        posted_by_user_id bigint NOT NULL, posted_by_impersonator_id bigint,
        posted_at timestamp(6) NOT NULL,
        CONSTRAINT finance_ledger_entries_book_fkey FOREIGN KEY (currency_code, company_id)
          REFERENCES finance_ledger_books (currency_code, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_entries_not_own_reversal
          CHECK (reverses_entry_id IS NULL OR reverses_entry_id <> id),
        CONSTRAINT finance_ledger_entries_entry_number CHECK (entry_number > 0)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_entries_company_number_unique
        ON finance_ledger_entries (company_id, entry_number)
      """,
      """
      CREATE FUNCTION pg_temp.finance_ledger_number_entry() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        NEW.entry_number := COALESCE(
          (SELECT max(entry_number) FROM finance_ledger_entries
           WHERE company_id = NEW.company_id), 0) + 1;
        NEW.posted_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE TRIGGER finance_ledger_entries_number BEFORE INSERT ON finance_ledger_entries
        FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_number_entry()
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
                ) IS DISTINCT FROM 'in progress'
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

  defp closing_statements do
    [
      """
      CREATE TEMPORARY TABLE finance_ledger_fiscal_years (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL,
        company_id bigint NOT NULL
          CONSTRAINT finance_ledger_fiscal_years_book_fkey
          REFERENCES finance_ledger_books (company_id) ON DELETE RESTRICT,
        start_date date NOT NULL, end_date date NOT NULL,
        opened_by_user_id bigint NOT NULL, opened_by_impersonator_id bigint,
        opened_at timestamp(6) NOT NULL,
        CONSTRAINT finance_ledger_fiscal_years_months
          CHECK (extract(day FROM start_date) = 1 AND extract(day FROM end_date + 1) = 1
            AND end_date > start_date AND end_date < start_date + interval '2 years')
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_fiscal_years_id_company_unique
        ON finance_ledger_fiscal_years (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_fiscal_years_company_start_unique
        ON finance_ledger_fiscal_years (company_id, start_date)
      """,
      """
      CREATE TEMPORARY TABLE finance_ledger_periods (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        fiscal_year_id bigint NOT NULL, period_number smallint NOT NULL,
        start_date date NOT NULL, end_date date NOT NULL,
        CONSTRAINT finance_ledger_periods_fiscal_year_fkey FOREIGN KEY (fiscal_year_id, company_id)
          REFERENCES finance_ledger_fiscal_years (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_periods_period_number CHECK (period_number > 0),
        CONSTRAINT finance_ledger_periods_one_month
          CHECK (extract(day FROM start_date) = 1
            AND end_date = (start_date + interval '1 month' - interval '1 day')::date)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_periods_id_company_unique
        ON finance_ledger_periods (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_periods_id_fiscal_year_unique
        ON finance_ledger_periods (id, fiscal_year_id)
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_periods_fiscal_year_number_unique
        ON finance_ledger_periods (fiscal_year_id, period_number)
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_periods_company_start_unique
        ON finance_ledger_periods (company_id, start_date)
      """,
      """
      CREATE TEMPORARY TABLE finance_ledger_closing_events (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        event_number bigint NOT NULL, fiscal_year_id bigint NOT NULL, period_id bigint,
        action varchar(16) NOT NULL, reason varchar(500), entry_id bigint,
        retained_earnings_account_id bigint,
        recorded_by_user_id bigint NOT NULL, recorded_by_impersonator_id bigint,
        recorded_at timestamp(6) NOT NULL,
        CONSTRAINT finance_ledger_closing_events_fiscal_year_fkey
          FOREIGN KEY (fiscal_year_id, company_id)
          REFERENCES finance_ledger_fiscal_years (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_closing_events_period_fkey FOREIGN KEY (period_id, fiscal_year_id)
          REFERENCES finance_ledger_periods (id, fiscal_year_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_closing_events_entry_fkey FOREIGN KEY (entry_id, company_id)
          REFERENCES finance_ledger_entries (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_closing_events_retained_earnings_fkey
          FOREIGN KEY (retained_earnings_account_id, company_id)
          REFERENCES finance_ledger_accounts (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_closing_events_action
          CHECK (action IN ('close', 'reopen', 'lock')),
        CONSTRAINT finance_ledger_closing_events_event_number CHECK (event_number > 0),
        CONSTRAINT finance_ledger_closing_events_reopen_reason
          CHECK (action <> 'reopen' OR (reason IS NOT NULL AND btrim(reason) <> '')),
        CONSTRAINT finance_ledger_closing_events_year_fields
          CHECK ((period_id IS NOT NULL OR action <> 'lock') AND
            ((period_id IS NULL AND action = 'close') OR
             (entry_id IS NULL AND retained_earnings_account_id IS NULL)))
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_closing_events_company_number_unique
        ON finance_ledger_closing_events (company_id, event_number)
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_closing_events_entry_unique
        ON finance_ledger_closing_events (entry_id) WHERE entry_id IS NOT NULL
      """
    ] ++
      closing_functions() ++
      for(
        table <- [
          "finance_ledger_fiscal_years",
          "finance_ledger_periods",
          "finance_ledger_closing_events"
        ],
        statement <- [
          "CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table} " <>
            "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_refuse_closing_change()",
          "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} " <>
            "FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.finance_ledger_refuse_closing_change()"
        ],
        do: statement
      ) ++
      [
        """
        CREATE TRIGGER finance_ledger_fiscal_years_open BEFORE INSERT ON finance_ledger_fiscal_years
          FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_open_fiscal_year()
        """,
        """
        CREATE CONSTRAINT TRIGGER finance_ledger_fiscal_years_divided
          AFTER INSERT ON finance_ledger_fiscal_years DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_check_fiscal_year_periods()
        """,
        """
        CREATE TRIGGER finance_ledger_periods_place BEFORE INSERT ON finance_ledger_periods
          FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_place_period()
        """,
        """
        CREATE TRIGGER finance_ledger_closing_events_record
          BEFORE INSERT ON finance_ledger_closing_events
          FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_record_closing_event()
        """,
        """
        CREATE CONSTRAINT TRIGGER finance_ledger_closing_events_closed_year
          AFTER INSERT ON finance_ledger_closing_events DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_check_closed_year()
        """,
        """
        CREATE TRIGGER finance_ledger_entries_open_period BEFORE INSERT ON finance_ledger_entries
          FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_ledger_refuse_closed_period()
        """
      ]
  end
end
