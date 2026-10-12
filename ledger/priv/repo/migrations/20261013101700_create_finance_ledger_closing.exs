defmodule Bilimbi.Finance.Ledger.Migrations.CreateClosing do
  @moduledoc """
  Period closing: each company's fiscal years, their monthly periods, and the
  closing log that opens, closes, and locks them; and the account a company
  designates for retained earnings.

  Bilimbi-only. A fiscal year and its periods are append-only. A year starts
  the day after the company's previous year ends, and its periods are
  inserted in the year's own transaction, one calendar month each in order; a
  deferred constraint trigger refuses a commit in which they do not reach the
  year's end.

  A period's status (open, closed, locked) and a year's status (open,
  closed) are never stored: they are the latest closing event's, and closing
  events are append-only, so the log is the whole history of who changed what
  and why. The database numbers each company's events without gaps, stamps
  their time, and refuses an event that breaks the closing rules: periods
  close and lock in date order and reopen in reverse, a reopen needs a
  reason, a locked period never reopens, a year's last period closes only
  with its year, and a closed year's periods stay closed. A journal entry
  dated in a closed or locked period, or before the company's first fiscal
  year, is refused.
  """

  use Ecto.Migration

  def up do
    alter table(:finance_ledger_accounts) do
      add :retained_earnings, :boolean, null: false, default: false
    end

    create constraint(:finance_ledger_accounts, :finance_ledger_accounts_retained_earnings_equity,
             check: "NOT retained_earnings OR account_type = 'equity'"
           )

    create unique_index(:finance_ledger_accounts, [:company_id],
             where: "retained_earnings",
             name: :finance_ledger_accounts_one_retained_earnings
           )

    create table(:finance_ledger_fiscal_years, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false

      add :company_id,
          references(:finance_ledger_books,
            column: :company_id,
            type: :bigint,
            on_delete: :restrict,
            name: :finance_ledger_fiscal_years_book_fkey
          ),
          null: false

      add :start_date, :date, null: false
      add :end_date, :date, null: false
      add :opened_by_user_id, :bigint, null: false
      add :opened_by_impersonator_id, :bigint
      add :opened_at, :utc_datetime_usec, null: false
    end

    create unique_index(:finance_ledger_fiscal_years, [:id, :company_id],
             name: :finance_ledger_fiscal_years_id_company_unique
           )

    create unique_index(:finance_ledger_fiscal_years, [:company_id, :start_date],
             name: :finance_ledger_fiscal_years_company_start_unique
           )

    create index(:finance_ledger_fiscal_years, [:tenant_id, :company_id])

    # Whole calendar months, from one month to two years.
    create constraint(:finance_ledger_fiscal_years, :finance_ledger_fiscal_years_months,
             check:
               "extract(day FROM start_date) = 1 AND extract(day FROM end_date + 1) = 1 " <>
                 "AND end_date > start_date AND end_date < start_date + interval '2 years'"
           )

    create table(:finance_ledger_periods, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false

      add :fiscal_year_id,
          references(:finance_ledger_fiscal_years,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_ledger_periods_fiscal_year_fkey
          ),
          null: false

      add :period_number, :smallint, null: false
      add :start_date, :date, null: false
      add :end_date, :date, null: false
    end

    create unique_index(:finance_ledger_periods, [:id, :company_id],
             name: :finance_ledger_periods_id_company_unique
           )

    create unique_index(:finance_ledger_periods, [:id, :fiscal_year_id],
             name: :finance_ledger_periods_id_fiscal_year_unique
           )

    create unique_index(:finance_ledger_periods, [:fiscal_year_id, :period_number],
             name: :finance_ledger_periods_fiscal_year_number_unique
           )

    create unique_index(:finance_ledger_periods, [:company_id, :start_date],
             name: :finance_ledger_periods_company_start_unique
           )

    create index(:finance_ledger_periods, [:tenant_id, :company_id])

    create constraint(:finance_ledger_periods, :finance_ledger_periods_period_number,
             check: "period_number > 0"
           )

    create constraint(:finance_ledger_periods, :finance_ledger_periods_one_month,
             check:
               "extract(day FROM start_date) = 1 " <>
                 "AND end_date = (start_date + interval '1 month' - interval '1 day')::date"
           )

    create table(:finance_ledger_closing_events, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :event_number, :bigint, null: false

      add :fiscal_year_id,
          references(:finance_ledger_fiscal_years,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_ledger_closing_events_fiscal_year_fkey
          ),
          null: false

      # NULL for an event on the fiscal year itself.
      add :period_id,
          references(:finance_ledger_periods,
            type: :bigint,
            with: [fiscal_year_id: :fiscal_year_id],
            on_delete: :restrict,
            name: :finance_ledger_closing_events_period_fkey
          )

      add :action, :string, size: 16, null: false
      add :reason, :string, size: 500

      add :entry_id,
          references(:finance_ledger_entries,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_ledger_closing_events_entry_fkey
          )

      add :retained_earnings_account_id,
          references(:finance_ledger_accounts,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_ledger_closing_events_retained_earnings_fkey
          )

      add :recorded_by_user_id, :bigint, null: false
      add :recorded_by_impersonator_id, :bigint
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create unique_index(:finance_ledger_closing_events, [:company_id, :event_number],
             name: :finance_ledger_closing_events_company_number_unique
           )

    create unique_index(:finance_ledger_closing_events, [:entry_id],
             where: "entry_id IS NOT NULL",
             name: :finance_ledger_closing_events_entry_unique
           )

    create index(:finance_ledger_closing_events, [:fiscal_year_id, :event_number])
    create index(:finance_ledger_closing_events, [:period_id, :event_number])
    create index(:finance_ledger_closing_events, [:tenant_id, :company_id])

    create constraint(:finance_ledger_closing_events, :finance_ledger_closing_events_action,
             check: "action IN ('close', 'reopen', 'lock')"
           )

    create constraint(:finance_ledger_closing_events, :finance_ledger_closing_events_event_number,
             check: "event_number > 0"
           )

    create constraint(
             :finance_ledger_closing_events,
             :finance_ledger_closing_events_reopen_reason,
             check: "action <> 'reopen' OR (reason IS NOT NULL AND btrim(reason) <> '')"
           )

    # A fiscal year is locked by locking its periods; only a year's own close
    # names the closing entry and the retained-earnings account.
    create constraint(:finance_ledger_closing_events, :finance_ledger_closing_events_year_fields,
             check:
               "(period_id IS NOT NULL OR action <> 'lock') AND " <>
                 "((period_id IS NULL AND action = 'close') OR " <>
                 "(entry_id IS NULL AND retained_earnings_account_id IS NULL))"
           )

    Enum.each(functions(""), &execute/1)

    for table <- [
          :finance_ledger_fiscal_years,
          :finance_ledger_periods,
          :finance_ledger_closing_events
        ] do
      execute("""
      CREATE TRIGGER #{table}_append_only
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION finance_ledger_refuse_closing_change()
      """)

      execute("""
      CREATE TRIGGER #{table}_no_truncate
        BEFORE TRUNCATE ON #{table}
        FOR EACH STATEMENT EXECUTE FUNCTION finance_ledger_refuse_closing_change()
      """)
    end

    execute("""
    CREATE TRIGGER finance_ledger_fiscal_years_open
      BEFORE INSERT ON finance_ledger_fiscal_years
      FOR EACH ROW EXECUTE FUNCTION finance_ledger_open_fiscal_year()
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER finance_ledger_fiscal_years_divided
      AFTER INSERT ON finance_ledger_fiscal_years
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION finance_ledger_check_fiscal_year_periods()
    """)

    execute("""
    CREATE TRIGGER finance_ledger_periods_place
      BEFORE INSERT ON finance_ledger_periods
      FOR EACH ROW EXECUTE FUNCTION finance_ledger_place_period()
    """)

    execute("""
    CREATE TRIGGER finance_ledger_closing_events_record
      BEFORE INSERT ON finance_ledger_closing_events
      FOR EACH ROW EXECUTE FUNCTION finance_ledger_record_closing_event()
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER finance_ledger_closing_events_closed_year
      AFTER INSERT ON finance_ledger_closing_events
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION finance_ledger_check_closed_year()
    """)

    execute("""
    CREATE TRIGGER finance_ledger_entries_open_period
      BEFORE INSERT ON finance_ledger_entries
      FOR EACH ROW EXECUTE FUNCTION finance_ledger_refuse_closed_period()
    """)
  end

  def down do
    execute("DROP TRIGGER finance_ledger_entries_open_period ON finance_ledger_entries")
    drop table(:finance_ledger_closing_events)
    drop table(:finance_ledger_periods)
    drop table(:finance_ledger_fiscal_years)

    for function <- [
          "finance_ledger_refuse_closed_period()",
          "finance_ledger_check_closed_year()",
          "finance_ledger_record_closing_event()",
          "finance_ledger_place_period()",
          "finance_ledger_check_fiscal_year_periods()",
          "finance_ledger_open_fiscal_year()",
          "finance_ledger_fiscal_year_status(bigint)",
          "finance_ledger_period_status(bigint)",
          "finance_ledger_refuse_closing_change()"
        ] do
      execute("DROP FUNCTION #{function}")
    end

    drop index(:finance_ledger_accounts, [:company_id],
           name: :finance_ledger_accounts_one_retained_earnings
         )

    drop constraint(:finance_ledger_accounts, :finance_ledger_accounts_retained_earnings_equity)

    alter table(:finance_ledger_accounts) do
      remove :retained_earnings
    end
  end

  @doc """
  The closing rules' functions. `schema` prefixes every function name, so the
  module's tests can create the same functions in `pg_temp.`, where
  PostgreSQL only finds a function by its qualified name.
  """
  def functions(schema) do
    [
      """
      CREATE FUNCTION #{schema}finance_ledger_refuse_closing_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'the finance ledger keeps % rows: % is refused',
          TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END
      $$
      """,
      # The latest event decides a status; a period or year with none is open.
      """
      CREATE FUNCTION #{schema}finance_ledger_period_status(target bigint) RETURNS text
      LANGUAGE sql AS $$
        SELECT COALESCE(
          (SELECT CASE action WHEN 'close' THEN 'closed' WHEN 'lock' THEN 'locked' ELSE 'open' END
           FROM finance_ledger_closing_events
           WHERE period_id = target
           ORDER BY event_number DESC LIMIT 1),
          'open')
      $$
      """,
      """
      CREATE FUNCTION #{schema}finance_ledger_fiscal_year_status(target bigint) RETURNS text
      LANGUAGE sql AS $$
        SELECT COALESCE(
          (SELECT CASE action WHEN 'close' THEN 'closed' ELSE 'open' END
           FROM finance_ledger_closing_events
           WHERE fiscal_year_id = target AND period_id IS NULL
           ORDER BY event_number DESC LIMIT 1),
          'open')
      $$
      """,
      # Locking the book serializes a company's years and closing events; it
      # does not conflict with the key-share lock a posting's foreign key takes.
      """
      CREATE FUNCTION #{schema}finance_ledger_open_fiscal_year() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        last_end date;
      BEGIN
        PERFORM 1 FROM finance_ledger_books WHERE company_id = NEW.company_id FOR NO KEY UPDATE;

        SELECT max(end_date) INTO last_end FROM finance_ledger_fiscal_years
        WHERE company_id = NEW.company_id;

        IF last_end IS NOT NULL AND NEW.start_date <> last_end + 1 THEN
          RAISE EXCEPTION 'a fiscal year starts on %, the day after the previous one ends',
            last_end + 1
            USING ERRCODE = 'check_violation';
        END IF;

        NEW.opened_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{schema}finance_ledger_check_fiscal_year_periods() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF (SELECT max(end_date) FROM finance_ledger_periods WHERE fiscal_year_id = NEW.id)
            IS DISTINCT FROM NEW.end_date THEN
          RAISE EXCEPTION 'fiscal year % is not divided into periods through its end', NEW.id
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NULL;
      END
      $$
      """,
      # A period is added only in the transaction that opens its year, as the
      # next month in order, so a year's periods are fixed once it is open.
      """
      CREATE FUNCTION #{schema}finance_ledger_place_period() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        year_start date;
        year_end date;
        year_xmin xid;
        last_number integer;
        last_end date;
      BEGIN
        SELECT start_date, end_date, xmin INTO year_start, year_end, year_xmin
        FROM finance_ledger_fiscal_years
        WHERE id = NEW.fiscal_year_id AND company_id = NEW.company_id;

        IF NOT FOUND THEN
          RETURN NEW;
        END IF;

        IF pg_xact_status(
             ((pg_current_xact_id()::text::bigint >> 32 << 32) | year_xmin::text::bigint)::text::xid8
           ) IS DISTINCT FROM 'in progress' THEN
          RAISE EXCEPTION 'fiscal year % is already open: a period cannot be added',
            NEW.fiscal_year_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        SELECT max(period_number), max(end_date) INTO last_number, last_end
        FROM finance_ledger_periods WHERE fiscal_year_id = NEW.fiscal_year_id;

        IF NEW.period_number <> COALESCE(last_number, 0) + 1
          OR NEW.start_date <> COALESCE(last_end, year_start - 1) + 1
          OR NEW.end_date > year_end THEN
          RAISE EXCEPTION 'periods divide fiscal year % one month at a time, in order',
            NEW.fiscal_year_id
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{schema}finance_ledger_record_closing_event() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        target finance_ledger_periods%ROWTYPE;
        year_end date;
        year_status text;
        period_status text;
        previous_status text;
        next_status text;
      BEGIN
        PERFORM 1 FROM finance_ledger_books WHERE company_id = NEW.company_id FOR NO KEY UPDATE;

        NEW.event_number := COALESCE(
          (SELECT max(event_number) FROM finance_ledger_closing_events
           WHERE company_id = NEW.company_id), 0) + 1;
        NEW.recorded_at := clock_timestamp() AT TIME ZONE 'UTC';

        SELECT end_date INTO year_end FROM finance_ledger_fiscal_years
        WHERE id = NEW.fiscal_year_id AND company_id = NEW.company_id;

        IF NOT FOUND THEN
          RETURN NEW;
        END IF;

        year_status := #{schema}finance_ledger_fiscal_year_status(NEW.fiscal_year_id);

        IF NEW.period_id IS NULL THEN
          IF NEW.action = 'close' AND year_status = 'closed' THEN
            RAISE EXCEPTION 'fiscal year % is already closed', NEW.fiscal_year_id
              USING ERRCODE = 'restrict_violation';
          ELSIF NEW.action = 'reopen' AND year_status <> 'closed' THEN
            RAISE EXCEPTION 'fiscal year % is not closed', NEW.fiscal_year_id
              USING ERRCODE = 'restrict_violation';
          ELSIF NEW.action = 'reopen' AND EXISTS (
            SELECT 1 FROM finance_ledger_periods
            WHERE fiscal_year_id = NEW.fiscal_year_id AND end_date = year_end
              AND #{schema}finance_ledger_period_status(id) = 'locked'
          ) THEN
            RAISE EXCEPTION 'fiscal year % ends in a locked period and never reopens',
              NEW.fiscal_year_id
              USING ERRCODE = 'restrict_violation';
          END IF;

          RETURN NEW;
        END IF;

        -- A posting into the period holds a share lock on it until it commits.
        SELECT * INTO target FROM finance_ledger_periods
        WHERE id = NEW.period_id AND fiscal_year_id = NEW.fiscal_year_id
        FOR UPDATE;

        IF NOT FOUND THEN
          RETURN NEW;
        END IF;

        period_status := #{schema}finance_ledger_period_status(target.id);

        SELECT #{schema}finance_ledger_period_status(id) INTO previous_status
        FROM finance_ledger_periods
        WHERE company_id = NEW.company_id AND end_date = target.start_date - 1;

        SELECT #{schema}finance_ledger_period_status(id) INTO next_status
        FROM finance_ledger_periods
        WHERE company_id = NEW.company_id AND start_date = target.end_date + 1;

        IF NEW.action = 'close' THEN
          IF period_status <> 'open' THEN
            RAISE EXCEPTION 'period % is not open', target.id
              USING ERRCODE = 'restrict_violation';
          ELSIF previous_status = 'open' THEN
            RAISE EXCEPTION 'period % cannot close before the period before it', target.id
              USING ERRCODE = 'restrict_violation';
          ELSIF target.end_date = year_end AND year_status <> 'closed' THEN
            RAISE EXCEPTION 'period % is its fiscal year''s last and closes with the year', target.id
              USING ERRCODE = 'restrict_violation';
          END IF;
        ELSIF NEW.action = 'reopen' THEN
          IF period_status <> 'closed' THEN
            RAISE EXCEPTION 'period % is %, not closed', target.id, period_status
              USING ERRCODE = 'restrict_violation';
          ELSIF year_status = 'closed' THEN
            RAISE EXCEPTION 'period % is in a closed fiscal year: reopen the year', target.id
              USING ERRCODE = 'restrict_violation';
          ELSIF next_status IS NOT NULL AND next_status <> 'open' THEN
            RAISE EXCEPTION 'period % cannot reopen while the period after it is %',
              target.id, next_status
              USING ERRCODE = 'restrict_violation';
          END IF;
        ELSIF NEW.action = 'lock' THEN
          IF period_status <> 'closed' THEN
            RAISE EXCEPTION 'period % is %, not closed', target.id, period_status
              USING ERRCODE = 'restrict_violation';
          ELSIF previous_status IS NOT NULL AND previous_status <> 'locked' THEN
            RAISE EXCEPTION 'period % cannot lock before the period before it', target.id
              USING ERRCODE = 'restrict_violation';
          END IF;
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{schema}finance_ledger_check_closed_year() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF #{schema}finance_ledger_fiscal_year_status(NEW.fiscal_year_id) = 'closed'
          AND EXISTS (
            SELECT 1 FROM finance_ledger_periods
            WHERE fiscal_year_id = NEW.fiscal_year_id
              AND #{schema}finance_ledger_period_status(id) = 'open'
          ) THEN
          RAISE EXCEPTION 'fiscal year % is closed but has an open period', NEW.fiscal_year_id
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NULL;
      END
      $$
      """,
      # The share lock holds the period's status until the posting commits.
      """
      CREATE FUNCTION #{schema}finance_ledger_refuse_closed_period() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        target bigint;
        status text;
      BEGIN
        SELECT id INTO target FROM finance_ledger_periods
        WHERE company_id = NEW.company_id
          AND NEW.entry_date BETWEEN start_date AND end_date
        FOR SHARE;

        IF FOUND THEN
          status := #{schema}finance_ledger_period_status(target);

          IF status <> 'open' THEN
            RAISE EXCEPTION 'journal entry dated % falls in a % period', NEW.entry_date, status
              USING ERRCODE = 'restrict_violation';
          END IF;
        ELSIF EXISTS (
          SELECT 1 FROM finance_ledger_periods
          WHERE company_id = NEW.company_id AND start_date > NEW.entry_date
        ) THEN
          RAISE EXCEPTION 'journal entry dated % is before the first fiscal year', NEW.entry_date
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """
    ]
  end
end
