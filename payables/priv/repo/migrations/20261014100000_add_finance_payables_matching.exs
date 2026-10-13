defmodule Bilimbi.Finance.Payables.Migrations.AddMatching do
  @moduledoc """
  Three-way matching: a bill line may name a purchase order line, and
  posting the bill compares what was billed with what was ordered and
  received.

  Bilimbi-only. The settings take the company's quantity and price
  tolerances, each a percentage or an amount, and the settings history
  records their changes. A document line takes `order_line_id`, the order
  line in the installed order source, with the `quantity` billed against it;
  the two come together. A document gains the status `held`: an approved bill
  whose lines fall outside tolerance is held instead of posted, and moves on
  only to `posted` or `voided`.

  Every posting attempt of a bill that names order lines is recorded as a
  match event with the figures it compared, line by line, and the exceptions
  it found: `held` when a line fell outside tolerance, `posted` when the bill
  posted, and `exception_approved` when a user approved the recorded
  exceptions with a reason, naming the `held` event it approved
  (`held_event_id`). Events, their lines, and their exceptions are
  append-only, name the actor, and are stamped by the database. The
  document's transition trigger is replaced so that a held bill posts only
  after an approval later than its last hold, unless the posting match found
  no exception, and so that a bill naming order lines never posts without
  its `posted` match record in the same transaction.

  The migration is self-contained: a database that ran the first migration
  loads only this file, so the replaced trigger function is spelled out here
  and `down/0` restores the original. `statements/1` mirrors the first
  migration's contract so `test/support/test_fixtures.ex` runs both against
  temporary tables.
  """

  use Ecto.Migration

  @tables ~w(
    finance_payables_match_events
    finance_payables_match_lines
    finance_payables_match_exceptions
  )

  @functions ~w(
    finance_payables_match_event_recorded
    finance_payables_refuse_closed_match
  )

  @exception_codes ~w(
    order_source_unavailable
    order_line_not_found
    order_line_superseded
    order_not_open
    currency_mismatch
    quantity_exceeds_ordered
    quantity_exceeds_received
    price_differs
  )

  @doc "The codes a match exception carries; `Bilimbi.Finance.Payables` explains each."
  def exception_codes, do: @exception_codes

  def up, do: Enum.each(statements(), &execute/1)

  def down do
    for table <- Enum.reverse(@tables), do: execute("DROP TABLE #{table}")
    for function <- @functions, do: execute("DROP FUNCTION #{function}()")
    execute(original_transition(""))

    execute(
      "ALTER TABLE finance_payables_documents DROP CONSTRAINT finance_payables_documents_status"
    )

    execute("""
    ALTER TABLE finance_payables_documents ADD CONSTRAINT finance_payables_documents_status
      CHECK (status IN ('draft', 'approved', 'posted', 'voided'))
    """)

    execute(
      "ALTER TABLE finance_payables_documents DROP CONSTRAINT finance_payables_documents_approval"
    )

    execute("""
    ALTER TABLE finance_payables_documents ADD CONSTRAINT finance_payables_documents_approval
      CHECK ((approved_at IS NULL) = (approved_by_user_id IS NULL)
        AND (status NOT IN ('approved', 'posted') OR approved_at IS NOT NULL)
        AND (status <> 'draft' OR approved_at IS NULL))
    """)

    execute("DROP INDEX finance_payables_document_lines_order_line_index")

    execute("""
    ALTER TABLE finance_payables_document_lines
      DROP CONSTRAINT finance_payables_document_lines_order_line,
      DROP COLUMN order_line_id,
      DROP COLUMN quantity
    """)

    execute("""
    ALTER TABLE finance_payables_settings_changes
      DROP COLUMN old_quantity_tolerance_kind,
      DROP COLUMN new_quantity_tolerance_kind,
      DROP COLUMN old_quantity_tolerance,
      DROP COLUMN new_quantity_tolerance,
      DROP COLUMN old_price_tolerance_kind,
      DROP COLUMN new_price_tolerance_kind,
      DROP COLUMN old_price_tolerance,
      DROP COLUMN new_price_tolerance
    """)

    execute("""
    ALTER TABLE finance_payables_settings
      DROP CONSTRAINT finance_payables_settings_quantity_tolerance,
      DROP CONSTRAINT finance_payables_settings_price_tolerance,
      DROP COLUMN quantity_tolerance_kind,
      DROP COLUMN quantity_tolerance,
      DROP COLUMN price_tolerance_kind,
      DROP COLUMN price_tolerance
    """)
  end

  @doc """
  The schema change's SQL in order. With `temporary: true` the new tables
  are temporary and the functions live in `pg_temp`, over the temporary
  copies the first migration's `statements(temporary: true)` created.
  """
  def statements(options \\ []) do
    {table, function} =
      if Keyword.get(options, :temporary, false),
        do: {"TEMPORARY TABLE", "pg_temp."},
        else: {"TABLE", ""}

    alterations() ++ tables(table) ++ functions(function) ++ triggers(function)
  end

  defp alterations do
    [
      # A tolerance is a percentage of the ordered figure or an amount in its
      # unit (units of quantity, or currency per unit); none means exact.
      """
      ALTER TABLE finance_payables_settings
        ADD COLUMN quantity_tolerance_kind varchar(8),
        ADD COLUMN quantity_tolerance numeric(20, 4),
        ADD COLUMN price_tolerance_kind varchar(8),
        ADD COLUMN price_tolerance numeric(20, 4),
        ADD CONSTRAINT finance_payables_settings_quantity_tolerance
          CHECK ((quantity_tolerance_kind IS NULL) = (quantity_tolerance IS NULL)
            AND (quantity_tolerance_kind IS NULL OR quantity_tolerance_kind IN ('percent', 'amount'))
            AND (quantity_tolerance IS NULL OR quantity_tolerance >= 0)),
        ADD CONSTRAINT finance_payables_settings_price_tolerance
          CHECK ((price_tolerance_kind IS NULL) = (price_tolerance IS NULL)
            AND (price_tolerance_kind IS NULL OR price_tolerance_kind IN ('percent', 'amount'))
            AND (price_tolerance IS NULL OR price_tolerance >= 0))
      """,
      """
      ALTER TABLE finance_payables_settings_changes
        ADD COLUMN old_quantity_tolerance_kind varchar(8),
        ADD COLUMN new_quantity_tolerance_kind varchar(8),
        ADD COLUMN old_quantity_tolerance numeric(20, 4),
        ADD COLUMN new_quantity_tolerance numeric(20, 4),
        ADD COLUMN old_price_tolerance_kind varchar(8),
        ADD COLUMN new_price_tolerance_kind varchar(8),
        ADD COLUMN old_price_tolerance numeric(20, 4),
        ADD COLUMN new_price_tolerance numeric(20, 4)
      """,
      # The order line is the installed order source's; the quantity billed
      # against it is this module's own record.
      """
      ALTER TABLE finance_payables_document_lines
        ADD COLUMN order_line_id bigint,
        ADD COLUMN quantity numeric(20, 4),
        ADD CONSTRAINT finance_payables_document_lines_order_line
          CHECK ((order_line_id IS NULL) = (quantity IS NULL)
            AND (order_line_id IS NULL OR order_line_id > 0)
            AND (quantity IS NULL OR quantity > 0))
      """,
      """
      CREATE INDEX finance_payables_document_lines_order_line_index
        ON finance_payables_document_lines (company_id, order_line_id)
        WHERE order_line_id IS NOT NULL
      """,
      "ALTER TABLE finance_payables_documents DROP CONSTRAINT finance_payables_documents_status",
      """
      ALTER TABLE finance_payables_documents ADD CONSTRAINT finance_payables_documents_status
        CHECK (status IN ('draft', 'approved', 'held', 'posted', 'voided'))
      """,
      "ALTER TABLE finance_payables_documents DROP CONSTRAINT finance_payables_documents_approval",
      """
      ALTER TABLE finance_payables_documents ADD CONSTRAINT finance_payables_documents_approval
        CHECK ((approved_at IS NULL) = (approved_by_user_id IS NULL)
          AND (status NOT IN ('approved', 'held', 'posted') OR approved_at IS NOT NULL)
          AND (status <> 'draft' OR approved_at IS NULL))
      """
    ]
  end

  defp tables(table) do
    [
      """
      CREATE #{table} finance_payables_match_events (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        document_id bigint NOT NULL,
        event varchar(20) NOT NULL,
        reason varchar(500),
        held_event_id bigint,
        actor_user_id bigint NOT NULL,
        actor_impersonator_id bigint,
        occurred_at timestamp(6) NOT NULL,
        CONSTRAINT finance_payables_match_events_document_fkey
          FOREIGN KEY (document_id, company_id)
          REFERENCES finance_payables_documents (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_payables_match_events_event
          CHECK (event IN ('held', 'exception_approved', 'posted')),
        CONSTRAINT finance_payables_match_events_reason
          CHECK (event <> 'exception_approved' OR reason IS NOT NULL),
        CONSTRAINT finance_payables_match_events_held_event
          CHECK (held_event_id IS NULL OR event = 'exception_approved')
      )
      """,
      """
      CREATE UNIQUE INDEX finance_payables_match_events_id_company_unique
        ON finance_payables_match_events (id, company_id)
      """,
      """
      ALTER TABLE finance_payables_match_events
        ADD CONSTRAINT finance_payables_match_events_held_event_fkey
          FOREIGN KEY (held_event_id, company_id)
          REFERENCES finance_payables_match_events (id, company_id) ON DELETE RESTRICT
      """,
      """
      CREATE INDEX finance_payables_match_events_document_index
        ON finance_payables_match_events (company_id, document_id)
      """,
      """
      CREATE INDEX finance_payables_match_events_tenant_id_company_id_index
        ON finance_payables_match_events (tenant_id, company_id)
      """,
      # The figures one posting attempt compared for one bill line: what the
      # order source said then, what this module had billed before, and the
      # tolerances in force. Ordered and received figures are absent when the
      # source could not answer.
      """
      CREATE #{table} finance_payables_match_lines (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        event_id bigint NOT NULL,
        document_id bigint NOT NULL,
        line_number integer NOT NULL,
        order_line_id bigint NOT NULL,
        order_number bigint,
        billed_quantity numeric(20, 4) NOT NULL,
        billed_unit_price numeric(20, 4) NOT NULL,
        previously_billed_quantity numeric(20, 4) NOT NULL,
        ordered_quantity numeric(20, 4),
        ordered_unit_price numeric(20, 4),
        received_quantity numeric(20, 4),
        quantity_tolerance_kind varchar(8),
        quantity_tolerance numeric(20, 4),
        price_tolerance_kind varchar(8),
        price_tolerance numeric(20, 4),
        CONSTRAINT finance_payables_match_lines_event_fkey
          FOREIGN KEY (event_id, company_id)
          REFERENCES finance_payables_match_events (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_payables_match_lines_document_fkey
          FOREIGN KEY (document_id, company_id)
          REFERENCES finance_payables_documents (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_payables_match_lines_line_number CHECK (line_number > 0),
        CONSTRAINT finance_payables_match_lines_order_line_id CHECK (order_line_id > 0),
        CONSTRAINT finance_payables_match_lines_quantities
          CHECK (billed_quantity > 0 AND billed_unit_price >= 0
            AND previously_billed_quantity >= 0
            AND (ordered_quantity IS NULL OR ordered_quantity > 0)
            AND (ordered_unit_price IS NULL OR ordered_unit_price >= 0)
            AND (received_quantity IS NULL OR received_quantity >= 0)),
        CONSTRAINT finance_payables_match_lines_tolerances
          CHECK ((quantity_tolerance_kind IS NULL) = (quantity_tolerance IS NULL)
            AND (price_tolerance_kind IS NULL) = (price_tolerance IS NULL))
      )
      """,
      """
      CREATE UNIQUE INDEX finance_payables_match_lines_id_company_unique
        ON finance_payables_match_lines (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_payables_match_lines_event_line_unique
        ON finance_payables_match_lines (event_id, line_number)
      """,
      """
      CREATE INDEX finance_payables_match_lines_tenant_id_company_id_index
        ON finance_payables_match_lines (tenant_id, company_id)
      """,
      """
      CREATE #{table} finance_payables_match_exceptions (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        match_line_id bigint NOT NULL,
        code varchar(40) NOT NULL,
        detail varchar(500) NOT NULL,
        CONSTRAINT finance_payables_match_exceptions_match_line_fkey
          FOREIGN KEY (match_line_id, company_id)
          REFERENCES finance_payables_match_lines (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_payables_match_exceptions_code
          CHECK (code IN (#{Enum.map_join(@exception_codes, ", ", &"'#{&1}'")}))
      )
      """,
      """
      CREATE UNIQUE INDEX finance_payables_match_exceptions_line_code_unique
        ON finance_payables_match_exceptions (match_line_id, code)
      """,
      """
      CREATE INDEX finance_payables_match_exceptions_tenant_id_company_id_index
        ON finance_payables_match_exceptions (tenant_id, company_id)
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
      # A match event is recorded for a bill in the status its kind expects,
      # and the database stamps its time. An approval needs a hold to
      # approve, names that hold, and approves it once; a posting of a held bill needs that
      # approval unless it found no exception (the transition trigger reads
      # the exceptions, which land after the event).
      """
      CREATE FUNCTION #{prefix}finance_payables_match_event_recorded() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        document record;
        latest text;
        latest_id bigint;
      BEGIN
        SELECT document_type, status INTO document
        FROM finance_payables_documents WHERE id = NEW.document_id;

        SELECT event, id INTO latest, latest_id FROM finance_payables_match_events
        WHERE document_id = NEW.document_id ORDER BY id DESC LIMIT 1;

        IF document.document_type <> 'bill' THEN
          RAISE EXCEPTION 'payables document % is not a bill: only a bill is matched',
            NEW.document_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF NEW.event IN ('held', 'posted') AND document.status NOT IN ('approved', 'held') THEN
          RAISE EXCEPTION 'payables document % is %: only an approved or held bill is matched',
            NEW.document_id, document.status
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF NEW.event = 'exception_approved'
           AND (document.status <> 'held' OR latest IS DISTINCT FROM 'held') THEN
          RAISE EXCEPTION 'payables document % has no held match exception to approve',
            NEW.document_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF NEW.event = 'exception_approved' AND NEW.held_event_id IS DISTINCT FROM latest_id THEN
          RAISE EXCEPTION 'payables document % approval must name its latest hold',
            NEW.document_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        NEW.occurred_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      # Match lines are inserted only with their event, and exceptions only
      # with their line, in the transaction that records them.
      """
      CREATE FUNCTION #{prefix}finance_payables_refuse_closed_match() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        closed boolean;
      BEGIN
        IF TG_TABLE_NAME = 'finance_payables_match_lines' THEN
          SELECT EXISTS (
            SELECT 1 FROM finance_payables_match_events
            WHERE id = NEW.event_id AND NOT (#{@written_by_this_transaction})
          ) INTO closed;
        ELSE
          SELECT EXISTS (
            SELECT 1 FROM finance_payables_match_lines
            WHERE id = NEW.match_line_id AND NOT (#{@written_by_this_transaction})
          ) INTO closed;
        END IF;

        IF closed THEN
          RAISE EXCEPTION 'a payables match record is complete when recorded: % refused on %',
            TG_OP, TG_TABLE_NAME
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      transition(prefix)
    ]
  end

  # The first migration's transition rule with the held status: approved ->
  # held, held -> posted or voided; a held bill posts only after an approval
  # later than its last hold unless the posting match found no exception;
  # and a bill naming order lines posts only with its posted match record,
  # written in the same transaction.
  defp transition(prefix) do
    """
    CREATE OR REPLACE FUNCTION #{prefix}finance_payables_document_transition() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      stamp timestamp := clock_timestamp() AT TIME ZONE 'UTC';
      last_hold bigint;
      posting bigint;
    BEGIN
      IF NOT ((OLD.status = 'draft' AND NEW.status IN ('approved', 'voided'))
              OR (OLD.status = 'approved' AND NEW.status IN ('posted', 'held', 'voided'))
              OR (OLD.status = 'held' AND NEW.status IN ('posted', 'voided'))) THEN
        RAISE EXCEPTION 'payables document % cannot go from % to %; post a debit note',
          OLD.id, OLD.status, NEW.status
          USING ERRCODE = 'restrict_violation';
      END IF;

      #{recorded_columns_rule()}

      NEW.approved_at := OLD.approved_at;
      NEW.posted_at := OLD.posted_at;
      NEW.document_number := OLD.document_number;
      NEW.voided_at := OLD.voided_at;

      IF NEW.status = 'approved' THEN
        NEW.approved_at := stamp;
      ELSIF NEW.status = 'posted' THEN
        IF OLD.document_type = 'bill' AND EXISTS (
          SELECT 1 FROM finance_payables_document_lines
          WHERE document_id = OLD.id AND order_line_id IS NOT NULL
        ) THEN
          SELECT id INTO posting FROM finance_payables_match_events
          WHERE document_id = OLD.id AND event = 'posted' AND (#{@written_by_this_transaction})
          ORDER BY id DESC LIMIT 1;

          IF posting IS NULL THEN
            RAISE EXCEPTION 'payables document % names order lines: it posts with its match record',
              OLD.id
              USING ERRCODE = 'restrict_violation';
          END IF;

          IF OLD.status = 'held' THEN
            SELECT max(id) INTO last_hold FROM finance_payables_match_events
            WHERE document_id = OLD.id AND event = 'held';

            IF NOT EXISTS (
              SELECT 1 FROM finance_payables_match_events
              WHERE document_id = OLD.id AND event = 'exception_approved' AND id > last_hold
            ) AND EXISTS (
              SELECT 1 FROM finance_payables_match_exceptions x
              JOIN finance_payables_match_lines l ON l.id = x.match_line_id
              WHERE l.event_id = posting
            ) THEN
              RAISE EXCEPTION 'payables document % is held: its match exceptions are not approved',
                OLD.id
                USING ERRCODE = 'restrict_violation';
            END IF;
          END IF;
        END IF;

        NEW.posted_at := stamp;
        NEW.document_number := COALESCE(
          (SELECT max(document_number) FROM finance_payables_documents
           WHERE company_id = NEW.company_id AND document_type = NEW.document_type), 0) + 1;
      ELSIF NEW.status = 'voided' THEN
        NEW.voided_at := stamp;
      END IF;

      RETURN NEW;
    END
    $$
    """
  end

  # The first migration's rule as it was, for `down/0`.
  defp original_transition(prefix) do
    """
    CREATE OR REPLACE FUNCTION #{prefix}finance_payables_document_transition() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      stamp timestamp := clock_timestamp() AT TIME ZONE 'UTC';
    BEGIN
      IF NOT ((OLD.status = 'draft' AND NEW.status IN ('approved', 'voided'))
              OR (OLD.status = 'approved' AND NEW.status IN ('posted', 'voided'))) THEN
        RAISE EXCEPTION 'payables document % cannot go from % to %; post a debit note',
          OLD.id, OLD.status, NEW.status
          USING ERRCODE = 'restrict_violation';
      END IF;

      #{recorded_columns_rule()}

      NEW.approved_at := OLD.approved_at;
      NEW.posted_at := OLD.posted_at;
      NEW.document_number := OLD.document_number;
      NEW.voided_at := OLD.voided_at;

      IF NEW.status = 'approved' THEN
        NEW.approved_at := stamp;
      ELSIF NEW.status = 'posted' THEN
        NEW.posted_at := stamp;
        NEW.document_number := COALESCE(
          (SELECT max(document_number) FROM finance_payables_documents
           WHERE company_id = NEW.company_id AND document_type = NEW.document_type), 0) + 1;
      ELSE
        NEW.voided_at := stamp;
      END IF;

      RETURN NEW;
    END
    $$
    """
  end

  # What a document recorded never changes; each step sets only its own
  # columns. Verbatim from the first migration.
  defp recorded_columns_rule do
    """
    IF ROW(NEW.tenant_id, NEW.company_id, NEW.document_type, NEW.corrects_document_id,
             NEW.party_key, NEW.party_name, NEW.party_tax_id, NEW.party_registration_id,
             NEW.party_address, NEW.party_document_number, NEW.document_date, NEW.due_date,
             NEW.currency_code, NEW.description, NEW.total_net, NEW.total_tax, NEW.total,
             NEW.created_by_user_id, NEW.created_by_impersonator_id, NEW.created_at)
           IS DISTINCT FROM
         ROW(OLD.tenant_id, OLD.company_id, OLD.document_type, OLD.corrects_document_id,
             OLD.party_key, OLD.party_name, OLD.party_tax_id, OLD.party_registration_id,
             OLD.party_address, OLD.party_document_number, OLD.document_date, OLD.due_date,
             OLD.currency_code, OLD.description, OLD.total_net, OLD.total_tax, OLD.total,
             OLD.created_by_user_id, OLD.created_by_impersonator_id, OLD.created_at)
        OR (NEW.status <> 'approved'
            AND ROW(NEW.approved_by_user_id, NEW.approved_by_impersonator_id)
                IS DISTINCT FROM ROW(OLD.approved_by_user_id, OLD.approved_by_impersonator_id))
        OR (NEW.status <> 'posted'
            AND ROW(NEW.posted_by_user_id, NEW.posted_by_impersonator_id,
                    NEW.payable_account_id, NEW.entry_id, NEW.entry_number)
                IS DISTINCT FROM
                ROW(OLD.posted_by_user_id, OLD.posted_by_impersonator_id,
                    OLD.payable_account_id, OLD.entry_id, OLD.entry_number))
        OR (NEW.status <> 'voided'
            AND ROW(NEW.voided_by_user_id, NEW.voided_by_impersonator_id, NEW.void_reason)
                IS DISTINCT FROM
                ROW(OLD.voided_by_user_id, OLD.voided_by_impersonator_id, OLD.void_reason)) THEN
        RAISE EXCEPTION 'payables document % keeps what was recorded; only its status moves',
          OLD.id
          USING ERRCODE = 'restrict_violation';
      END IF;
    """
  end

  defp triggers(prefix) do
    refuse = "EXECUTE FUNCTION #{prefix}finance_payables_refuse_change()"

    append_only =
      for table <- @tables do
        "CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table} " <>
          "FOR EACH ROW #{refuse}"
      end

    no_truncate =
      for table <- @tables do
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} " <>
          "FOR EACH STATEMENT #{refuse}"
      end

    closed =
      for table <- ~w(finance_payables_match_lines finance_payables_match_exceptions) do
        "CREATE TRIGGER #{table}_open_event BEFORE INSERT ON #{table} " <>
          "FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_payables_refuse_closed_match()"
      end

    append_only ++
      no_truncate ++
      closed ++
      [
        """
        CREATE TRIGGER finance_payables_match_events_recorded
          BEFORE INSERT ON finance_payables_match_events
          FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_payables_match_event_recorded()
        """
      ]
  end
end
