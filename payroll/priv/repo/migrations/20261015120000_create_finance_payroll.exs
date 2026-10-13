defmodule Bilimbi.Finance.Payroll.Migrations.CreatePayroll do
  @moduledoc """
  The bridge from payroll runs and staff claims to the ledger: each
  company's payroll posting settings (the accounts net pay and approved
  claims are owed on), its mappings of payroll components and claim
  categories to ledger accounts, the history of changes to both, and the
  append-only events of every posting, reversal, and failed attempt.

  Bilimbi-only. Ledger account IDs are plain columns: the ledger's tables
  belong to `finance/ledger`, which validates every account when the facade
  posts. Source IDs (a payroll run, a claim) are plain columns too: they
  belong to the optional source Domain, which may not be mounted.

  Settings and mappings change in place, keeping their company and key; a
  trigger refuses a change of identity and any delete, and each change is
  recorded in the same transaction with who made it, why, and the values
  before and after, never altered. A posting event is never updated or
  deleted; the database stamps its time, refuses a second `posted` or a
  second `reversed` event for one source, refuses a reversal of a source
  that was never posted, and refuses one ledger entry on two events, so a
  run or claim posts once and its history is whole.

  `statements/1` is the one source of this schema: the migration runs it, and
  module tests run it with `temporary: true` to build temporary copies.
  """

  use Ecto.Migration

  @tables ~w(
    finance_payroll_settings
    finance_payroll_settings_changes
    finance_payroll_mappings
    finance_payroll_mapping_changes
    finance_payroll_posting_events
  )

  @functions ~w(
    finance_payroll_refuse_change
    finance_payroll_keep_identity
    finance_payroll_stamp_change
    finance_payroll_record_event
  )

  def up, do: Enum.each(statements(), &execute/1)

  def down do
    for table <- Enum.reverse(@tables), do: execute("DROP TABLE #{table}")
    for function <- @functions, do: execute("DROP FUNCTION #{function}()")
  end

  @doc """
  The schema's SQL in order. With `temporary: true` the tables are temporary
  and the functions live in `pg_temp`, for module tests.
  """
  def statements(options \\ []) do
    {table, function} =
      if Keyword.get(options, :temporary, false),
        do: {"TEMPORARY TABLE", "pg_temp."},
        else: {"TABLE", ""}

    tables(table) ++ functions(function) ++ triggers(function)
  end

  defp tables(table) do
    [
      # The liability accounts a run's net pay and an approved claim are
      # credited to: what is owed to staff until it is paid.
      """
      CREATE #{table} finance_payroll_settings (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        net_pay_account_id bigint NOT NULL,
        claims_payable_account_id bigint NOT NULL,
        inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL
      )
      """,
      """
      CREATE UNIQUE INDEX finance_payroll_settings_company_unique
        ON finance_payroll_settings (company_id)
      """,
      """
      CREATE INDEX finance_payroll_settings_tenant_id_company_id_index
        ON finance_payroll_settings (tenant_id, company_id)
      """,
      """
      CREATE #{table} finance_payroll_settings_changes (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        old_net_pay_account_id bigint,
        new_net_pay_account_id bigint NOT NULL,
        old_claims_payable_account_id bigint,
        new_claims_payable_account_id bigint NOT NULL,
        reason varchar(500),
        changed_by_user_id bigint NOT NULL,
        changed_by_impersonator_id bigint,
        changed_at timestamp(6) NOT NULL,
        CONSTRAINT finance_payroll_settings_changes_before
          CHECK ((old_net_pay_account_id IS NULL) = (old_claims_payable_account_id IS NULL))
      )
      """,
      """
      CREATE INDEX finance_payroll_settings_changes_tenant_id_company_id_index
        ON finance_payroll_settings_changes (tenant_id, company_id)
      """,
      # A payroll component is the source's pay item code with the direction
      # its lines carry: an earning debits an expense, a deduction credits a
      # liability, and an employer contribution does both. A claim category
      # debits an expense; the credit is the settings' claims payable account.
      """
      CREATE #{table} finance_payroll_mappings (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        kind varchar(20) NOT NULL,
        code varchar(60) NOT NULL,
        direction varchar(20) NOT NULL,
        expense_account_id bigint,
        liability_account_id bigint,
        inserted_at timestamp(0) NOT NULL,
        updated_at timestamp(0) NOT NULL,
        CONSTRAINT finance_payroll_mappings_kind
          CHECK (kind IN ('component', 'claim_category')),
        CONSTRAINT finance_payroll_mappings_direction
          CHECK (direction IN ('earning', 'deduction', 'employer', 'claim')),
        CONSTRAINT finance_payroll_mappings_code CHECK (code <> ''),
        CONSTRAINT finance_payroll_mappings_claim_direction
          CHECK ((kind = 'claim_category') = (direction = 'claim')),
        CONSTRAINT finance_payroll_mappings_accounts
          CHECK ((direction IN ('earning', 'claim')
                  AND expense_account_id IS NOT NULL AND liability_account_id IS NULL)
            OR (direction = 'deduction'
                  AND expense_account_id IS NULL AND liability_account_id IS NOT NULL)
            OR (direction = 'employer'
                  AND expense_account_id IS NOT NULL AND liability_account_id IS NOT NULL))
      )
      """,
      """
      CREATE UNIQUE INDEX finance_payroll_mappings_id_company_unique
        ON finance_payroll_mappings (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_payroll_mappings_company_key_unique
        ON finance_payroll_mappings (company_id, kind, code, direction)
      """,
      """
      CREATE INDEX finance_payroll_mappings_tenant_id_company_id_index
        ON finance_payroll_mappings (tenant_id, company_id)
      """,
      """
      CREATE #{table} finance_payroll_mapping_changes (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        mapping_id bigint NOT NULL,
        old_expense_account_id bigint,
        new_expense_account_id bigint,
        old_liability_account_id bigint,
        new_liability_account_id bigint,
        reason varchar(500),
        changed_by_user_id bigint NOT NULL,
        changed_by_impersonator_id bigint,
        changed_at timestamp(6) NOT NULL,
        CONSTRAINT finance_payroll_mapping_changes_mapping_fkey
          FOREIGN KEY (mapping_id, company_id)
          REFERENCES finance_payroll_mappings (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_payroll_mapping_changes_after
          CHECK (new_expense_account_id IS NOT NULL OR new_liability_account_id IS NOT NULL)
      )
      """,
      """
      CREATE INDEX finance_payroll_mapping_changes_tenant_id_company_id_index
        ON finance_payroll_mapping_changes (tenant_id, company_id)
      """,
      """
      CREATE INDEX finance_payroll_mapping_changes_mapping_id_index
        ON finance_payroll_mapping_changes (mapping_id)
      """,
      # One row per attempt: `posted` and `reversed` name the ledger entry,
      # a failure names its reason. The source is the optional Domain's run
      # or claim, by ID, with the reference it was known by when it posted.
      """
      CREATE #{table} finance_payroll_posting_events (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        source_kind varchar(20) NOT NULL,
        source_id bigint NOT NULL,
        source_reference varchar(100) NOT NULL,
        event varchar(20) NOT NULL,
        entry_id bigint,
        entry_number bigint,
        entry_date date,
        total numeric(20, 4),
        currency_code varchar(3),
        reason varchar(500),
        actor_user_id bigint NOT NULL,
        actor_impersonator_id bigint,
        occurred_at timestamp(6) NOT NULL,
        CONSTRAINT finance_payroll_posting_events_source_kind
          CHECK (source_kind IN ('payroll_run', 'claim')),
        CONSTRAINT finance_payroll_posting_events_event
          CHECK (event IN ('posted', 'posting_failed', 'reversed', 'reversal_failed')),
        CONSTRAINT finance_payroll_posting_events_entry
          CHECK ((event IN ('posted', 'reversed')) = (entry_id IS NOT NULL)
            AND (event IN ('posted', 'reversed')) = (entry_number IS NOT NULL)
            AND (event IN ('posted', 'reversed')) = (entry_date IS NOT NULL)
            AND (event IN ('posted', 'reversed')) = (total IS NOT NULL)
            AND (event IN ('posted', 'reversed')) = (currency_code IS NOT NULL)),
        CONSTRAINT finance_payroll_posting_events_reason
          CHECK (event = 'posted' OR reason IS NOT NULL),
        CONSTRAINT finance_payroll_posting_events_total CHECK (total IS NULL OR total > 0),
        CONSTRAINT finance_payroll_posting_events_currency_code
          CHECK (currency_code IS NULL OR currency_code ~ '^[A-Z]{3}$')
      )
      """,
      # A source posts once and is reversed once.
      """
      CREATE UNIQUE INDEX finance_payroll_posting_events_posted_unique
        ON finance_payroll_posting_events (company_id, source_kind, source_id)
        WHERE event = 'posted'
      """,
      """
      CREATE UNIQUE INDEX finance_payroll_posting_events_reversed_unique
        ON finance_payroll_posting_events (company_id, source_kind, source_id)
        WHERE event = 'reversed'
      """,
      """
      CREATE UNIQUE INDEX finance_payroll_posting_events_entry_unique
        ON finance_payroll_posting_events (company_id, entry_id)
        WHERE entry_id IS NOT NULL
      """,
      """
      CREATE INDEX finance_payroll_posting_events_source_index
        ON finance_payroll_posting_events (company_id, source_kind, source_id)
      """,
      """
      CREATE INDEX finance_payroll_posting_events_tenant_id_company_id_index
        ON finance_payroll_posting_events (tenant_id, company_id)
      """
    ]
  end

  @doc """
  The trigger functions, each prefixed (`pg_temp.` for module tests, which
  create them beside their temporary tables).
  """
  def functions(prefix) do
    [
      """
      CREATE FUNCTION #{prefix}finance_payroll_refuse_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'finance payroll keeps % rows: % is refused', TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END
      $$
      """,
      # Settings keep their company; a mapping keeps its company and key.
      """
      CREATE FUNCTION #{prefix}finance_payroll_keep_identity() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.tenant_id <> OLD.tenant_id OR NEW.company_id <> OLD.company_id
          OR (TG_TABLE_NAME = 'finance_payroll_mappings'
              AND (to_jsonb(NEW) ->> 'kind' <> to_jsonb(OLD) ->> 'kind'
                OR to_jsonb(NEW) ->> 'code' <> to_jsonb(OLD) ->> 'code'
                OR to_jsonb(NEW) ->> 'direction' <> to_jsonb(OLD) ->> 'direction')) THEN
          RAISE EXCEPTION 'finance payroll keeps % rows in their company and key', TG_TABLE_NAME
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_payroll_stamp_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        NEW.changed_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      # The database's time, and a reversal only of a source that posted.
      """
      CREATE FUNCTION #{prefix}finance_payroll_record_event() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.event IN ('reversed', 'reversal_failed') AND NOT EXISTS (
          SELECT 1 FROM finance_payroll_posting_events
          WHERE company_id = NEW.company_id AND source_kind = NEW.source_kind
            AND source_id = NEW.source_id AND event = 'posted') THEN
          RAISE EXCEPTION 'finance payroll reverses only a posted source'
            USING ERRCODE = 'restrict_violation';
        END IF;

        NEW.occurred_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """
    ]
  end

  defp triggers(prefix) do
    refuse = "EXECUTE FUNCTION #{prefix}finance_payroll_refuse_change()"

    append_only =
      for table <- ~w(
            finance_payroll_settings_changes
            finance_payroll_mapping_changes
            finance_payroll_posting_events
          ) do
        "CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table} " <>
          "FOR EACH ROW #{refuse}"
      end

    kept =
      for table <- ~w(finance_payroll_settings finance_payroll_mappings) do
        "CREATE TRIGGER #{table}_kept BEFORE DELETE ON #{table} FOR EACH ROW #{refuse}"
      end

    identity =
      for table <- ~w(finance_payroll_settings finance_payroll_mappings) do
        "CREATE TRIGGER #{table}_identity BEFORE UPDATE ON #{table} " <>
          "FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_payroll_keep_identity()"
      end

    stamped =
      for table <- ~w(finance_payroll_settings_changes finance_payroll_mapping_changes) do
        "CREATE TRIGGER #{table}_stamp BEFORE INSERT ON #{table} " <>
          "FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_payroll_stamp_change()"
      end

    recorded = [
      "CREATE TRIGGER finance_payroll_posting_events_record BEFORE INSERT " <>
        "ON finance_payroll_posting_events FOR EACH ROW " <>
        "EXECUTE FUNCTION #{prefix}finance_payroll_record_event()"
    ]

    append_only ++ kept ++ identity ++ stamped ++ recorded
  end
end
