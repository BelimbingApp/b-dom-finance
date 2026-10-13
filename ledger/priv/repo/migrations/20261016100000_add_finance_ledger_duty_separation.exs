defmodule Bilimbi.Finance.Ledger.Migrations.AddDutySeparation do
  @moduledoc """
  Separation of duties: each company's setting that the person who approves
  a record is not the person who prepared it, the approval exceptions an
  independent reviewer reads, and manual journals that post only once a
  second person approves them.

  Bilimbi-only. The setting is never stored as a column: it is the latest of
  the company's append-only duty separation changes, each with the actor,
  any impersonator, a reason, and the database's time; a company with none
  requires separation. Turning it off needs a reason, and a change that
  changes nothing is refused.

  An approval exception records an approval an independent reviewer should
  read: a same-person approval (the approver, or whoever impersonated them,
  prepared the record, or impersonated whoever did), allowed only while the
  company's latest change turns separation off and naming that change; or an
  override of a control, such as an approved match exception or a reopened
  period, whoever made it. The database numbers each company's exceptions
  without gaps, stamps their time, refuses a same-person exception unless
  the change it names is the company's latest and turns separation off, and
  checks that `same_person` says whether the approver and preparer overlap.
  A review of an exception is appended once, by someone who neither
  approved nor prepared it.

  A manual journal is submitted with its lines, numbered, and stamped by the
  database, and is decided once: approved, naming the entry it posted, or
  rejected with a reason. A line is added only in the transaction that
  submits its journal, a deferred constraint trigger refuses a commit in
  which a journal has no lines or does not balance, and an approval by its
  submitter is refused unless the same transaction recorded the same-person
  exception for it. Every table here is append-only.

  The migration is self-contained, and `statements/1` is its one source:
  with `temporary: true` the tables are temporary and the functions live in
  `pg_temp`, for the module tests' fixtures.
  """

  use Ecto.Migration

  @tables ~w(
    finance_ledger_duty_separation_changes
    finance_ledger_approval_exceptions
    finance_ledger_approval_exception_reviews
    finance_ledger_journals
    finance_ledger_journal_lines
    finance_ledger_journal_events
  )

  @functions ~w(
    finance_ledger_refuse_record_change
    finance_ledger_record_duty_separation_change
    finance_ledger_record_approval_exception
    finance_ledger_record_approval_exception_review
    finance_ledger_record_journal
    finance_ledger_refuse_submitted_journal_line
    finance_ledger_check_journal_balance
    finance_ledger_record_journal_event
  )

  def up, do: Enum.each(statements(), &execute/1)

  def down do
    for table <- Enum.reverse(@tables), do: execute("DROP TABLE #{table}")
    for function <- Enum.reverse(@functions), do: execute("DROP FUNCTION #{function}()")
  end

  @doc """
  The schema change's SQL in order. With `temporary: true` the tables are
  temporary and the functions live in `pg_temp`, over the temporary copies
  of the ledger's earlier tables.
  """
  def statements(options \\ []) do
    {table, function} =
      if Keyword.get(options, :temporary, false),
        do: {"TEMPORARY TABLE", "pg_temp."},
        else: {"TABLE", ""}

    tables(table) ++ functions(function) ++ triggers(function)
  end

  # Whether two people overlap: either one's user or impersonator is the
  # other's user or impersonator. A missing impersonator overlaps nobody.
  defp same_person(user, impersonator, other_user, other_impersonator) do
    "(COALESCE(#{user} IN (#{other_user}, #{other_impersonator}), false) " <>
      "OR COALESCE(#{impersonator} IN (#{other_user}, #{other_impersonator}), false))"
  end

  defp tables(table) do
    [
      """
      CREATE #{table} finance_ledger_duty_separation_changes (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        change_number bigint NOT NULL,
        required boolean NOT NULL,
        reason varchar(500),
        changed_by_user_id bigint NOT NULL,
        changed_by_impersonator_id bigint,
        changed_at timestamp(6) NOT NULL,
        CONSTRAINT finance_ledger_duty_separation_changes_change_number
          CHECK (change_number > 0),
        CONSTRAINT finance_ledger_duty_separation_changes_reason
          CHECK (required OR (reason IS NOT NULL AND btrim(reason) <> ''))
      )
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_duty_separation_changes_id_company_unique
        ON finance_ledger_duty_separation_changes (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_duty_separation_changes_company_number_unique
        ON finance_ledger_duty_separation_changes (company_id, change_number)
      """,
      """
      CREATE INDEX finance_ledger_duty_separation_changes_tenant_company_index
        ON finance_ledger_duty_separation_changes (tenant_id, company_id)
      """,
      # The record an exception is about belongs to the module that names
      # it in `source`; its ID and label are kept as plain values.
      """
      CREATE #{table} finance_ledger_approval_exceptions (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        exception_number bigint NOT NULL,
        source varchar(64) NOT NULL,
        action varchar(40) NOT NULL,
        subject_type varchar(40) NOT NULL,
        subject_id bigint NOT NULL,
        subject varchar(200) NOT NULL,
        same_person boolean NOT NULL,
        override boolean NOT NULL,
        prepared_by_user_id bigint,
        prepared_by_impersonator_id bigint,
        approved_by_user_id bigint NOT NULL,
        approved_by_impersonator_id bigint,
        reason varchar(500) NOT NULL,
        separation_change_id bigint,
        recorded_at timestamp(6) NOT NULL,
        CONSTRAINT finance_ledger_approval_exceptions_separation_change_fkey
          FOREIGN KEY (separation_change_id, company_id)
          REFERENCES finance_ledger_duty_separation_changes (id, company_id)
          ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_approval_exceptions_exception_number
          CHECK (exception_number > 0),
        CONSTRAINT finance_ledger_approval_exceptions_codes
          CHECK (source ~ '^[a-z][a-z0-9_/-]*$' AND action ~ '^[a-z][a-z0-9_]*$'
            AND subject_type ~ '^[a-z][a-z0-9_]*$' AND subject_id > 0
            AND btrim(subject) <> '' AND btrim(reason) <> ''),
        CONSTRAINT finance_ledger_approval_exceptions_kind
          CHECK (same_person OR override),
        CONSTRAINT finance_ledger_approval_exceptions_same_person
          CHECK (same_person = #{same_person("approved_by_user_id", "approved_by_impersonator_id", "prepared_by_user_id", "prepared_by_impersonator_id")}
            AND same_person = (separation_change_id IS NOT NULL)),
        CONSTRAINT finance_ledger_approval_exceptions_preparer
          CHECK (prepared_by_user_id IS NOT NULL OR prepared_by_impersonator_id IS NULL)
      )
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_approval_exceptions_id_company_unique
        ON finance_ledger_approval_exceptions (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_approval_exceptions_company_number_unique
        ON finance_ledger_approval_exceptions (company_id, exception_number)
      """,
      """
      CREATE INDEX finance_ledger_approval_exceptions_subject_index
        ON finance_ledger_approval_exceptions (company_id, source, subject_type, subject_id)
      """,
      """
      CREATE INDEX finance_ledger_approval_exceptions_recorded_index
        ON finance_ledger_approval_exceptions (company_id, recorded_at)
      """,
      """
      CREATE INDEX finance_ledger_approval_exceptions_tenant_id_company_id_index
        ON finance_ledger_approval_exceptions (tenant_id, company_id)
      """,
      """
      CREATE #{table} finance_ledger_approval_exception_reviews (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        exception_id bigint NOT NULL,
        note varchar(500),
        reviewed_by_user_id bigint NOT NULL,
        reviewed_by_impersonator_id bigint,
        reviewed_at timestamp(6) NOT NULL,
        CONSTRAINT finance_ledger_approval_exception_reviews_exception_fkey
          FOREIGN KEY (exception_id, company_id)
          REFERENCES finance_ledger_approval_exceptions (id, company_id) ON DELETE RESTRICT
      )
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_approval_exception_reviews_exception_unique
        ON finance_ledger_approval_exception_reviews (exception_id)
      """,
      """
      CREATE INDEX finance_ledger_approval_exception_reviews_tenant_company_index
        ON finance_ledger_approval_exception_reviews (tenant_id, company_id)
      """,
      """
      CREATE #{table} finance_ledger_journals (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        journal_number bigint NOT NULL,
        entry_date date NOT NULL,
        description varchar(500) NOT NULL,
        reference varchar(100),
        currency_code varchar(3) NOT NULL,
        submitted_by_user_id bigint NOT NULL,
        submitted_by_impersonator_id bigint,
        submitted_at timestamp(6) NOT NULL,
        CONSTRAINT finance_ledger_journals_book_fkey
          FOREIGN KEY (company_id, currency_code)
          REFERENCES finance_ledger_books (company_id, currency_code) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_journals_journal_number CHECK (journal_number > 0)
      )
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_journals_id_company_unique
        ON finance_ledger_journals (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_journals_company_number_unique
        ON finance_ledger_journals (company_id, journal_number)
      """,
      """
      CREATE INDEX finance_ledger_journals_tenant_id_company_id_index
        ON finance_ledger_journals (tenant_id, company_id)
      """,
      """
      CREATE #{table} finance_ledger_journal_lines (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        journal_id bigint NOT NULL,
        line_number integer NOT NULL,
        account_id bigint NOT NULL,
        debit numeric(20, 4) NOT NULL,
        credit numeric(20, 4) NOT NULL,
        description varchar(500),
        CONSTRAINT finance_ledger_journal_lines_journal_fkey
          FOREIGN KEY (journal_id, company_id)
          REFERENCES finance_ledger_journals (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_journal_lines_account_fkey
          FOREIGN KEY (account_id, company_id)
          REFERENCES finance_ledger_accounts (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_journal_lines_line_number CHECK (line_number > 0),
        CONSTRAINT finance_ledger_journal_lines_one_side
          CHECK (debit >= 0 AND credit >= 0 AND (debit = 0) <> (credit = 0))
      )
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_journal_lines_journal_line_unique
        ON finance_ledger_journal_lines (journal_id, line_number)
      """,
      """
      CREATE INDEX finance_ledger_journal_lines_tenant_id_company_id_index
        ON finance_ledger_journal_lines (tenant_id, company_id)
      """,
      """
      CREATE #{table} finance_ledger_journal_events (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        journal_id bigint NOT NULL,
        event varchar(16) NOT NULL,
        reason varchar(500),
        entry_id bigint,
        actor_user_id bigint NOT NULL,
        actor_impersonator_id bigint,
        occurred_at timestamp(6) NOT NULL,
        CONSTRAINT finance_ledger_journal_events_journal_fkey
          FOREIGN KEY (journal_id, company_id)
          REFERENCES finance_ledger_journals (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_journal_events_entry_fkey
          FOREIGN KEY (entry_id, company_id)
          REFERENCES finance_ledger_entries (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_ledger_journal_events_event
          CHECK (event IN ('approved', 'rejected')),
        CONSTRAINT finance_ledger_journal_events_entry
          CHECK ((event = 'approved') = (entry_id IS NOT NULL)),
        CONSTRAINT finance_ledger_journal_events_reason
          CHECK (event <> 'rejected' OR (reason IS NOT NULL AND btrim(reason) <> ''))
      )
      """,
      # A journal is decided once, and an entry posts one journal.
      """
      CREATE UNIQUE INDEX finance_ledger_journal_events_journal_unique
        ON finance_ledger_journal_events (journal_id)
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_journal_events_entry_unique
        ON finance_ledger_journal_events (entry_id) WHERE entry_id IS NOT NULL
      """,
      """
      CREATE INDEX finance_ledger_journal_events_tenant_id_company_id_index
        ON finance_ledger_journal_events (tenant_id, company_id)
      """
    ]
  end

  # See the first migration: whether the transaction that last wrote a row is
  # still in progress.
  @written_by_this_transaction """
  pg_xact_status(
    ((pg_current_xact_id()::text::bigint >> 32 << 32) | xmin::text::bigint)::text::xid8
  ) = 'in progress'
  """

  defp functions(prefix) do
    [
      """
      CREATE FUNCTION #{prefix}finance_ledger_refuse_record_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'the finance ledger keeps % rows: % is refused', TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END
      $$
      """,
      # The latest change decides the setting; with none, separation is
      # required. A change must change it.
      """
      CREATE FUNCTION #{prefix}finance_ledger_record_duty_separation_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        current boolean;
      BEGIN
        SELECT required INTO current FROM finance_ledger_duty_separation_changes
        WHERE company_id = NEW.company_id ORDER BY change_number DESC LIMIT 1;

        IF COALESCE(current, true) = NEW.required THEN
          RAISE EXCEPTION 'duty separation of company % is already %', NEW.company_id,
            CASE WHEN NEW.required THEN 'required' ELSE 'not required' END
            USING ERRCODE = 'restrict_violation';
        END IF;

        NEW.change_number := COALESCE(
          (SELECT max(change_number) FROM finance_ledger_duty_separation_changes
           WHERE company_id = NEW.company_id), 0) + 1;
        NEW.changed_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_ledger_record_approval_exception() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        latest finance_ledger_duty_separation_changes%ROWTYPE;
      BEGIN
        IF NEW.same_person THEN
          SELECT * INTO latest FROM finance_ledger_duty_separation_changes
          WHERE company_id = NEW.company_id ORDER BY change_number DESC LIMIT 1;

          IF latest.id IS DISTINCT FROM NEW.separation_change_id OR latest.required THEN
            RAISE EXCEPTION 'company % requires separation of duties: the person who prepared % % cannot approve it',
              NEW.company_id, NEW.subject_type, NEW.subject_id
              USING ERRCODE = 'restrict_violation';
          END IF;
        END IF;

        NEW.exception_number := COALESCE(
          (SELECT max(exception_number) FROM finance_ledger_approval_exceptions
           WHERE company_id = NEW.company_id), 0) + 1;
        NEW.recorded_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_ledger_record_approval_exception_review() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        reviewed finance_ledger_approval_exceptions%ROWTYPE;
      BEGIN
        SELECT * INTO reviewed FROM finance_ledger_approval_exceptions
        WHERE id = NEW.exception_id AND company_id = NEW.company_id;

        IF FOUND AND (
          #{same_person("NEW.reviewed_by_user_id", "NEW.reviewed_by_impersonator_id", "reviewed.approved_by_user_id", "reviewed.approved_by_impersonator_id")}
          OR #{same_person("NEW.reviewed_by_user_id", "NEW.reviewed_by_impersonator_id", "reviewed.prepared_by_user_id", "reviewed.prepared_by_impersonator_id")}
        ) THEN
          RAISE EXCEPTION 'approval exception % is reviewed by someone who neither approved nor prepared it',
            NEW.exception_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        NEW.reviewed_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_ledger_record_journal() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        NEW.journal_number := COALESCE(
          (SELECT max(journal_number) FROM finance_ledger_journals
           WHERE company_id = NEW.company_id), 0) + 1;
        NEW.submitted_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_ledger_refuse_submitted_journal_line() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM finance_ledger_journals
          WHERE id = NEW.journal_id AND NOT (#{@written_by_this_transaction})
        ) THEN
          RAISE EXCEPTION 'journal % is already submitted: a line cannot be added', NEW.journal_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_ledger_check_journal_balance() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        checked_id bigint;
      BEGIN
        IF TG_TABLE_NAME = 'finance_ledger_journals' THEN
          checked_id := NEW.id;
        ELSE
          checked_id := NEW.journal_id;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM finance_ledger_journal_lines WHERE journal_id = checked_id) THEN
          RAISE EXCEPTION 'journal % has no lines', checked_id
            USING ERRCODE = 'check_violation';
        END IF;

        IF (SELECT sum(debit) - sum(credit) FROM finance_ledger_journal_lines
            WHERE journal_id = checked_id) <> 0 THEN
          RAISE EXCEPTION 'journal % does not balance', checked_id
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NULL;
      END
      $$
      """,
      # Its submitter approves a journal only with the same-person exception
      # recorded in the same transaction, which the exception's own trigger
      # allows only while separation is off.
      """
      CREATE FUNCTION #{prefix}finance_ledger_record_journal_event() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        journal finance_ledger_journals%ROWTYPE;
      BEGIN
        SELECT * INTO journal FROM finance_ledger_journals
        WHERE id = NEW.journal_id AND company_id = NEW.company_id;

        IF NEW.event = 'approved' AND FOUND
          AND #{same_person("NEW.actor_user_id", "NEW.actor_impersonator_id", "journal.submitted_by_user_id", "journal.submitted_by_impersonator_id")}
          AND NOT EXISTS (
            SELECT 1 FROM finance_ledger_approval_exceptions
            WHERE company_id = NEW.company_id AND source = 'finance/ledger'
              AND subject_type = 'journal' AND subject_id = NEW.journal_id AND same_person
              AND (#{@written_by_this_transaction})
          ) THEN
          RAISE EXCEPTION 'journal % is approved by someone other than whoever submitted it',
            NEW.journal_id
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
    refuse = "EXECUTE FUNCTION #{prefix}finance_ledger_refuse_record_change()"

    record = fn table, function ->
      "CREATE TRIGGER #{table}_record BEFORE INSERT ON #{table} " <>
        "FOR EACH ROW EXECUTE FUNCTION #{prefix}#{function}()"
    end

    Enum.flat_map(@tables, fn table ->
      [
        "CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table} " <>
          "FOR EACH ROW #{refuse}",
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} " <>
          "FOR EACH STATEMENT #{refuse}"
      ]
    end) ++
      [
        record.(
          "finance_ledger_duty_separation_changes",
          "finance_ledger_record_duty_separation_change"
        ),
        record.("finance_ledger_approval_exceptions", "finance_ledger_record_approval_exception"),
        record.(
          "finance_ledger_approval_exception_reviews",
          "finance_ledger_record_approval_exception_review"
        ),
        record.("finance_ledger_journals", "finance_ledger_record_journal"),
        record.("finance_ledger_journal_events", "finance_ledger_record_journal_event"),
        """
        CREATE TRIGGER finance_ledger_journal_lines_submitted_journal
          BEFORE INSERT ON finance_ledger_journal_lines
          FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_ledger_refuse_submitted_journal_line()
        """
      ] ++
      for table <- ~w(finance_ledger_journals finance_ledger_journal_lines) do
        "CREATE CONSTRAINT TRIGGER #{table}_balanced AFTER INSERT ON #{table} " <>
          "DEFERRABLE INITIALLY DEFERRED " <>
          "FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_ledger_check_journal_balance()"
      end
  end
end
