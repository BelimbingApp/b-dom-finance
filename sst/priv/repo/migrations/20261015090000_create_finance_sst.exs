defmodule Bilimbi.Finance.Sst.Migrations.CreateSst do
  @moduledoc """
  Sales and Service Tax returns: each company's SST registration, kept as
  numbered versions; which return box each tax code of receivables and
  payables reports in, kept the same way; the returns prepared for each
  taxable period, with the events that open, finalise, or discard them;
  the adjustments a preparer adds to an open return; and the snapshot of
  box figures, source rows, and ledger reconciliation a finalised return
  keeps.

  Bilimbi-only. Rows of one company reference each other through composite
  `(id, company_id)` foreign keys. Ledger account and tax code IDs are plain
  columns: those tables belong to `finance/ledger`, `finance/receivables`,
  and `finance/payables`, read only through their facades.

  Every table is append-only. A registration or a mapping is changed by
  recording its next version, a return is opened, then finalised or
  discarded, each an event, an adjustment is withdrawn by a row that names
  it, and a finalised return is amended by a new return for the same period
  that names it. The database numbers each company's registrations,
  mappings, returns, return events, and adjustments without gaps and stamps
  their times. A return's snapshot rows are inserted only in the
  transaction that finalises it. Nothing is ever deleted or truncated.

  `statements/1` is the one source of this schema: the migration runs it, and
  module tests run it with `temporary: true` to build temporary copies.
  """

  use Ecto.Migration

  @tables ~w(
    finance_sst_registrations
    finance_sst_mappings
    finance_sst_returns
    finance_sst_return_events
    finance_sst_return_adjustments
    finance_sst_return_boxes
    finance_sst_return_sources
    finance_sst_return_accounts
  )

  @functions ~w(
    finance_sst_refuse_change
    finance_sst_number
    finance_sst_check_registration
    finance_sst_open_return
    finance_sst_record_return_event
    finance_sst_check_return
    finance_sst_check_finalised
    finance_sst_record_adjustment
    finance_sst_refuse_late_snapshot
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
      # A company's SST registration as of each version: its registration
      # numbers, the cycle its taxable periods follow (the first from
      # `period_start` to the end of the month `period_months` months on
      # counting its own, each later one `period_months` whole months), and
      # whether service tax is due when payment is received or when the
      # invoice is issued. The latest version is the registration.
      """
      CREATE #{table} finance_sst_registrations (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        version bigint NOT NULL,
        sales_tax_number varchar(30),
        service_tax_number varchar(30),
        period_months smallint NOT NULL,
        period_start date NOT NULL,
        service_tax_basis varchar(16) NOT NULL,
        reason varchar(500),
        recorded_by_user_id bigint NOT NULL,
        recorded_by_impersonator_id bigint,
        recorded_at timestamp(6) NOT NULL,
        CONSTRAINT finance_sst_registrations_version CHECK (version > 0),
        CONSTRAINT finance_sst_registrations_number
          CHECK (sales_tax_number IS NOT NULL OR service_tax_number IS NOT NULL),
        CONSTRAINT finance_sst_registrations_period_months CHECK (period_months BETWEEN 1 AND 12),
        CONSTRAINT finance_sst_registrations_service_tax_basis
          CHECK (service_tax_basis IN ('payment', 'invoice'))
      )
      """,
      """
      CREATE UNIQUE INDEX finance_sst_registrations_id_company_unique
        ON finance_sst_registrations (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_sst_registrations_company_version_unique
        ON finance_sst_registrations (company_id, version)
      """,
      """
      CREATE INDEX finance_sst_registrations_tenant_id_company_id_index
        ON finance_sst_registrations (tenant_id, company_id)
      """,
      # Which return box a tax code reports in; a NULL box records that the
      # code is deliberately not reported. The latest mapping of a code
      # applies, and a return records the mapping number it read through.
      """
      CREATE #{table} finance_sst_mappings (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        mapping_number bigint NOT NULL,
        source varchar(16) NOT NULL,
        tax_code_id bigint NOT NULL,
        tax_code varchar(50) NOT NULL,
        box varchar(32),
        reason varchar(500),
        recorded_by_user_id bigint NOT NULL,
        recorded_by_impersonator_id bigint,
        recorded_at timestamp(6) NOT NULL,
        CONSTRAINT finance_sst_mappings_mapping_number CHECK (mapping_number > 0),
        CONSTRAINT finance_sst_mappings_source CHECK (source IN ('receivables', 'payables')),
        CONSTRAINT finance_sst_mappings_box CHECK (box ~ '^[a-z0-9_]+$')
      )
      """,
      """
      CREATE UNIQUE INDEX finance_sst_mappings_company_number_unique
        ON finance_sst_mappings (company_id, mapping_number)
      """,
      """
      CREATE INDEX finance_sst_mappings_tax_code_index
        ON finance_sst_mappings (company_id, source, tax_code_id, mapping_number)
      """,
      """
      CREATE INDEX finance_sst_mappings_tenant_id_company_id_index
        ON finance_sst_mappings (tenant_id, company_id)
      """,
      # A return of one tax (sales tax or service tax, each filed on its own
      # form) for one taxable period under one registration version. A
      # period's first return of a tax names nothing; each later one amends
      # the latest finalised return of that tax and period and says why.
      """
      CREATE #{table} finance_sst_returns (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        return_number bigint NOT NULL,
        tax_type varchar(16) NOT NULL,
        registration_id bigint NOT NULL,
        period_start date NOT NULL,
        period_end date NOT NULL,
        due_date date NOT NULL,
        amends_return_id bigint,
        reason varchar(500),
        opened_by_user_id bigint NOT NULL,
        opened_by_impersonator_id bigint,
        opened_at timestamp(6) NOT NULL,
        CONSTRAINT finance_sst_returns_registration_fkey
          FOREIGN KEY (registration_id, company_id)
          REFERENCES finance_sst_registrations (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_sst_returns_return_number CHECK (return_number > 0),
        CONSTRAINT finance_sst_returns_tax_type CHECK (tax_type IN ('sales_tax', 'service_tax')),
        CONSTRAINT finance_sst_returns_period CHECK (period_end >= period_start),
        CONSTRAINT finance_sst_returns_due_date CHECK (due_date > period_end),
        CONSTRAINT finance_sst_returns_amendment_reason
          CHECK (amends_return_id IS NULL OR (reason IS NOT NULL AND btrim(reason) <> ''))
      )
      """,
      """
      CREATE UNIQUE INDEX finance_sst_returns_id_company_unique
        ON finance_sst_returns (id, company_id)
      """,
      # A self-reference needs the unique index above first.
      """
      ALTER TABLE finance_sst_returns
        ADD CONSTRAINT finance_sst_returns_amends_fkey
          FOREIGN KEY (amends_return_id, company_id)
          REFERENCES finance_sst_returns (id, company_id) ON DELETE RESTRICT
      """,
      """
      CREATE UNIQUE INDEX finance_sst_returns_company_number_unique
        ON finance_sst_returns (company_id, return_number)
      """,
      """
      CREATE INDEX finance_sst_returns_period_index
        ON finance_sst_returns (company_id, tax_type, period_start)
      """,
      """
      CREATE INDEX finance_sst_returns_tenant_id_company_id_index
        ON finance_sst_returns (tenant_id, company_id)
      """,
      # `opened` is recorded with its return; `finalised` carries the
      # return's version for its period, the numbers its figures were read
      # at, the currency, and the tax payable; `discarded` needs a reason.
      # A return has at most one of each.
      """
      CREATE #{table} finance_sst_return_events (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        event_number bigint NOT NULL,
        return_id bigint NOT NULL,
        action varchar(16) NOT NULL,
        reason varchar(500),
        version integer,
        through_entry_number bigint,
        through_mapping_number bigint,
        through_adjustment_number bigint,
        currency_code varchar(3),
        minor_units smallint,
        tax_payable numeric(20, 4),
        recorded_by_user_id bigint NOT NULL,
        recorded_by_impersonator_id bigint,
        recorded_at timestamp(6) NOT NULL,
        CONSTRAINT finance_sst_return_events_return_fkey
          FOREIGN KEY (return_id, company_id)
          REFERENCES finance_sst_returns (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_sst_return_events_action
          CHECK (action IN ('opened', 'finalised', 'discarded')),
        CONSTRAINT finance_sst_return_events_event_number CHECK (event_number > 0),
        CONSTRAINT finance_sst_return_events_discard_reason
          CHECK (action <> 'discarded' OR (reason IS NOT NULL AND btrim(reason) <> '')),
        CONSTRAINT finance_sst_return_events_figures
          CHECK ((action = 'finalised') = (version IS NOT NULL)
            AND (action = 'finalised') = (through_entry_number IS NOT NULL)
            AND (action = 'finalised') = (through_mapping_number IS NOT NULL)
            AND (action = 'finalised') = (through_adjustment_number IS NOT NULL)
            AND (action = 'finalised') = (currency_code IS NOT NULL)
            AND (action = 'finalised') = (minor_units IS NOT NULL)
            AND (action = 'finalised') = (tax_payable IS NOT NULL))
      )
      """,
      """
      CREATE UNIQUE INDEX finance_sst_return_events_company_number_unique
        ON finance_sst_return_events (company_id, event_number)
      """,
      """
      CREATE UNIQUE INDEX finance_sst_return_events_return_action_unique
        ON finance_sst_return_events (return_id, action)
      """,
      # An adjustment a preparer adds to an open return (a bad debt relief,
      # a recovered bad debt, an amount the documents cannot show), with its
      # box, amounts, and description; `withdrawn` names the adjustment it
      # takes back and says why. An amendment copies the standing
      # adjustments of the return it amends, naming each one copied.
      """
      CREATE #{table} finance_sst_return_adjustments (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        adjustment_number bigint NOT NULL,
        return_id bigint NOT NULL,
        action varchar(16) NOT NULL,
        withdraws_adjustment_id bigint,
        copied_from_adjustment_id bigint,
        box varchar(32),
        taxable_amount numeric(20, 4),
        tax_amount numeric(20, 4),
        description varchar(500) NOT NULL,
        reference varchar(100),
        recorded_by_user_id bigint NOT NULL,
        recorded_by_impersonator_id bigint,
        recorded_at timestamp(6) NOT NULL,
        CONSTRAINT finance_sst_return_adjustments_return_fkey
          FOREIGN KEY (return_id, company_id)
          REFERENCES finance_sst_returns (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_sst_return_adjustments_adjustment_number
          CHECK (adjustment_number > 0),
        CONSTRAINT finance_sst_return_adjustments_action
          CHECK (action IN ('added', 'withdrawn')),
        CONSTRAINT finance_sst_return_adjustments_shape
          CHECK ((action = 'added') = (box IS NOT NULL)
            AND (action = 'added') = (taxable_amount IS NOT NULL)
            AND (action = 'added') = (tax_amount IS NOT NULL)
            AND (action = 'withdrawn') = (withdraws_adjustment_id IS NOT NULL)
            AND (action = 'added' OR copied_from_adjustment_id IS NULL)),
        CONSTRAINT finance_sst_return_adjustments_box CHECK (box ~ '^[a-z0-9_]+$'),
        CONSTRAINT finance_sst_return_adjustments_description CHECK (btrim(description) <> ''),
        CONSTRAINT finance_sst_return_adjustments_amounts
          CHECK (taxable_amount IS NULL OR taxable_amount >= 0 AND tax_amount >= 0
            AND (taxable_amount > 0 OR tax_amount > 0))
      )
      """,
      """
      CREATE UNIQUE INDEX finance_sst_return_adjustments_id_company_unique
        ON finance_sst_return_adjustments (id, company_id)
      """,
      """
      ALTER TABLE finance_sst_return_adjustments
        ADD CONSTRAINT finance_sst_return_adjustments_withdraws_fkey
          FOREIGN KEY (withdraws_adjustment_id, company_id)
          REFERENCES finance_sst_return_adjustments (id, company_id) ON DELETE RESTRICT,
        ADD CONSTRAINT finance_sst_return_adjustments_copied_fkey
          FOREIGN KEY (copied_from_adjustment_id, company_id)
          REFERENCES finance_sst_return_adjustments (id, company_id) ON DELETE RESTRICT
      """,
      """
      CREATE UNIQUE INDEX finance_sst_return_adjustments_company_number_unique
        ON finance_sst_return_adjustments (company_id, adjustment_number)
      """,
      # An adjustment is withdrawn once.
      """
      CREATE UNIQUE INDEX finance_sst_return_adjustments_withdraws_unique
        ON finance_sst_return_adjustments (withdraws_adjustment_id)
      """,
      """
      CREATE INDEX finance_sst_return_adjustments_return_index
        ON finance_sst_return_adjustments (company_id, return_id)
      """,
      # A finalised return's figures in its form's box order.
      """
      CREATE #{table} finance_sst_return_boxes (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        return_id bigint NOT NULL,
        line_number integer NOT NULL,
        box varchar(32) NOT NULL,
        taxable_amount numeric(20, 4),
        tax_amount numeric(20, 4),
        CONSTRAINT finance_sst_return_boxes_return_fkey
          FOREIGN KEY (return_id, company_id)
          REFERENCES finance_sst_returns (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_sst_return_boxes_line_number CHECK (line_number > 0),
        CONSTRAINT finance_sst_return_boxes_box CHECK (box ~ '^[a-z0-9_]+$')
      )
      """,
      """
      CREATE UNIQUE INDEX finance_sst_return_boxes_return_box_unique
        ON finance_sst_return_boxes (return_id, box)
      """,
      """
      CREATE UNIQUE INDEX finance_sst_return_boxes_return_line_unique
        ON finance_sst_return_boxes (return_id, line_number)
      """,
      # What a finalised return counted, per source, document kind, measure,
      # tax code, rate, and tax account: the box it went to (NULL when the
      # code is mapped as not reported) and its signed contribution to that
      # box. `measure` is `documents` (by document date), `received` (the
      # tax share of payments received, net of reversals), `unpaid` (the tax
      # share an invoice still owed when the unpaid-period rule made it
      # due), or `credited_after_due` (credit notes on tax already due);
      # `prior_period` marks a credit note on an invoice of an earlier
      # period.
      """
      CREATE #{table} finance_sst_return_sources (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        return_id bigint NOT NULL,
        line_number integer NOT NULL,
        source varchar(16) NOT NULL,
        document_kind varchar(32) NOT NULL,
        measure varchar(32) NOT NULL,
        prior_period boolean NOT NULL,
        tax_code_id bigint NOT NULL,
        tax_code varchar(50) NOT NULL,
        rate numeric(9, 4) NOT NULL,
        account_id bigint NOT NULL,
        box varchar(32),
        mapping_number bigint NOT NULL,
        document_count integer NOT NULL,
        taxable_amount numeric(20, 4) NOT NULL,
        tax_amount numeric(20, 4) NOT NULL,
        CONSTRAINT finance_sst_return_sources_return_fkey
          FOREIGN KEY (return_id, company_id)
          REFERENCES finance_sst_returns (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_sst_return_sources_line_number CHECK (line_number > 0),
        CONSTRAINT finance_sst_return_sources_source
          CHECK (source IN ('receivables', 'payables')),
        CONSTRAINT finance_sst_return_sources_measure
          CHECK (measure IN ('documents', 'received', 'unpaid', 'credited_after_due')),
        CONSTRAINT finance_sst_return_sources_box CHECK (box ~ '^[a-z0-9_]+$'),
        CONSTRAINT finance_sst_return_sources_document_count CHECK (document_count > 0)
      )
      """,
      """
      CREATE UNIQUE INDEX finance_sst_return_sources_return_line_unique
        ON finance_sst_return_sources (return_id, line_number)
      """,
      # How a finalised return's document tax compared with each tax
      # account's ledger postings over the period; the difference is kept,
      # never hidden.
      """
      CREATE #{table} finance_sst_return_accounts (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        return_id bigint NOT NULL,
        line_number integer NOT NULL,
        account_id bigint NOT NULL,
        account_code varchar(50) NOT NULL,
        account_name varchar(200) NOT NULL,
        ledger_debits numeric(20, 4) NOT NULL,
        ledger_credits numeric(20, 4) NOT NULL,
        document_debits numeric(20, 4) NOT NULL,
        document_credits numeric(20, 4) NOT NULL,
        difference numeric(20, 4) NOT NULL,
        CONSTRAINT finance_sst_return_accounts_return_fkey
          FOREIGN KEY (return_id, company_id)
          REFERENCES finance_sst_returns (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_sst_return_accounts_line_number CHECK (line_number > 0),
        CONSTRAINT finance_sst_return_accounts_difference
          CHECK (difference = (ledger_credits - ledger_debits) - (document_credits - document_debits))
      )
      """,
      """
      CREATE UNIQUE INDEX finance_sst_return_accounts_return_line_unique
        ON finance_sst_return_accounts (return_id, line_number)
      """,
      """
      CREATE UNIQUE INDEX finance_sst_return_accounts_return_account_unique
        ON finance_sst_return_accounts (return_id, account_id)
      """
    ]
  end

  # pg_xact_status reads whether the transaction that last wrote a row is
  # still in progress; it is NULL for one older than the retained commit log,
  # so IS DISTINCT FROM keeps old rows closed.
  @written_by_this_transaction """
  pg_xact_status(
    ((pg_current_xact_id()::text::bigint >> 32 << 32) | xmin::text::bigint)::text::xid8
  ) = 'in progress'
  """

  defp functions(prefix) do
    [
      """
      CREATE FUNCTION #{prefix}finance_sst_refuse_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'finance sst keeps % rows: % is refused', TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END
      $$
      """,
      # Numbers a company's rows of each kind 1, 2, 3, ... in insertion order
      # and stamps the row's time, whatever the writer sent. With no sequence
      # and no deletion a number is never skipped or reused, and a concurrent
      # writer that takes the same number fails on the unique index. A
      # `finalised` event's version is the period's count of finalised
      # returns, this one included.
      """
      CREATE FUNCTION #{prefix}finance_sst_number() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        stamp timestamp := clock_timestamp() AT TIME ZONE 'UTC';
      BEGIN
        IF TG_TABLE_NAME = 'finance_sst_registrations' THEN
          NEW.version := COALESCE(
            (SELECT max(version) FROM finance_sst_registrations
             WHERE company_id = NEW.company_id), 0) + 1;
          NEW.recorded_at := stamp;
        ELSIF TG_TABLE_NAME = 'finance_sst_mappings' THEN
          NEW.mapping_number := COALESCE(
            (SELECT max(mapping_number) FROM finance_sst_mappings
             WHERE company_id = NEW.company_id), 0) + 1;
          NEW.recorded_at := stamp;
        ELSIF TG_TABLE_NAME = 'finance_sst_returns' THEN
          NEW.return_number := COALESCE(
            (SELECT max(return_number) FROM finance_sst_returns
             WHERE company_id = NEW.company_id), 0) + 1;
          NEW.opened_at := stamp;
        ELSIF TG_TABLE_NAME = 'finance_sst_return_events' THEN
          NEW.event_number := COALESCE(
            (SELECT max(event_number) FROM finance_sst_return_events
             WHERE company_id = NEW.company_id), 0) + 1;
          NEW.recorded_at := stamp;

          IF NEW.action = 'finalised' THEN
            NEW.version := (
              SELECT count(*) + 1 FROM finance_sst_return_events e
              JOIN finance_sst_returns r ON r.id = e.return_id
              JOIN finance_sst_returns this ON this.id = NEW.return_id
              WHERE e.company_id = NEW.company_id AND e.action = 'finalised'
                AND r.tax_type = this.tax_type AND r.period_start = this.period_start);
          END IF;
        ELSIF TG_TABLE_NAME = 'finance_sst_return_adjustments' THEN
          NEW.adjustment_number := COALESCE(
            (SELECT max(adjustment_number) FROM finance_sst_return_adjustments
             WHERE company_id = NEW.company_id), 0) + 1;
          NEW.recorded_at := stamp;
        END IF;

        RETURN NEW;
      END
      $$
      """,
      # A registration may change its numbers at any time, but its period
      # cycle and service tax basis only from a date after every finalised
      # return's period, so a period already reported stays the period it
      # was and nothing is counted under two bases.
      """
      CREATE FUNCTION #{prefix}finance_sst_check_registration() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        latest record;
        reported_through date;
      BEGIN
        SELECT * INTO latest FROM finance_sst_registrations
        WHERE company_id = NEW.company_id AND id <> NEW.id ORDER BY version DESC LIMIT 1;

        IF NOT FOUND OR (latest.period_months = NEW.period_months
                         AND latest.period_start = NEW.period_start
                         AND latest.service_tax_basis = NEW.service_tax_basis) THEN
          RETURN NEW;
        END IF;

        SELECT max(r.period_end) INTO reported_through
        FROM finance_sst_returns r
        JOIN finance_sst_return_events e ON e.return_id = r.id AND e.action = 'finalised'
        WHERE r.company_id = NEW.company_id;

        IF reported_through IS NOT NULL AND NEW.period_start <= reported_through THEN
          RAISE EXCEPTION 'taxable periods are reported through %: a new cycle starts after it',
            reported_through
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      # Per tax, one return of a period is open at a time, no return's period
      # overlaps another period's, a period's first return amends nothing,
      # and each later one amends the period's latest finalised return.
      """
      CREATE FUNCTION #{prefix}finance_sst_open_return() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        latest_finalised bigint;
      BEGIN
        IF EXISTS (
          SELECT 1 FROM finance_sst_returns r
          WHERE r.company_id = NEW.company_id AND r.id <> NEW.id
            AND r.tax_type = NEW.tax_type AND r.period_start = NEW.period_start
            AND NOT EXISTS (SELECT 1 FROM finance_sst_return_events e
                            WHERE e.return_id = r.id AND e.action IN ('finalised', 'discarded'))
        ) THEN
          RAISE EXCEPTION 'the % period from % already has an open return',
            NEW.tax_type, NEW.period_start
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF EXISTS (
          SELECT 1 FROM finance_sst_returns r
          WHERE r.company_id = NEW.company_id AND r.tax_type = NEW.tax_type
            AND (r.period_start <> NEW.period_start OR r.period_end <> NEW.period_end)
            AND r.period_start <= NEW.period_end AND r.period_end >= NEW.period_start
            AND NOT EXISTS (SELECT 1 FROM finance_sst_return_events e
                            WHERE e.return_id = r.id AND e.action = 'discarded')
        ) THEN
          RAISE EXCEPTION 'the period % to % overlaps another period''s return',
            NEW.period_start, NEW.period_end
            USING ERRCODE = 'restrict_violation';
        END IF;

        SELECT r.id INTO latest_finalised
        FROM finance_sst_returns r
        JOIN finance_sst_return_events e ON e.return_id = r.id AND e.action = 'finalised'
        WHERE r.company_id = NEW.company_id AND r.tax_type = NEW.tax_type
          AND r.period_start = NEW.period_start
        ORDER BY e.event_number DESC LIMIT 1;

        IF NEW.amends_return_id IS DISTINCT FROM latest_finalised THEN
          IF latest_finalised IS NULL THEN
            RAISE EXCEPTION 'the period from % has no finalised return to amend', NEW.period_start
              USING ERRCODE = 'restrict_violation';
          ELSE
            RAISE EXCEPTION 'the period from % is finalised: a new return amends return %',
              NEW.period_start, latest_finalised
              USING ERRCODE = 'restrict_violation';
          END IF;
        END IF;

        RETURN NEW;
      END
      $$
      """,
      # `opened` is recorded with its return; `finalised` and `discarded`
      # need an open one.
      """
      CREATE FUNCTION #{prefix}finance_sst_record_return_event() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.action = 'opened' AND NOT COALESCE((
          SELECT #{@written_by_this_transaction} FROM finance_sst_returns
          WHERE id = NEW.return_id
        ), false) THEN
          RAISE EXCEPTION 'return % is already recorded: it is not opened again', NEW.return_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF NEW.action <> 'opened' AND EXISTS (
          SELECT 1 FROM finance_sst_return_events
          WHERE return_id = NEW.return_id AND action IN ('finalised', 'discarded')
        ) THEN
          RAISE EXCEPTION 'return % is already closed', NEW.return_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      # At commit, every return has its `opened` event.
      """
      CREATE FUNCTION #{prefix}finance_sst_check_return() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM finance_sst_return_events
                       WHERE return_id = NEW.id AND action = 'opened') THEN
          RAISE EXCEPTION 'return % has no opened event', NEW.id
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NULL;
      END
      $$
      """,
      # At commit, a finalised return holds its box figures.
      """
      CREATE FUNCTION #{prefix}finance_sst_check_finalised() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.action = 'finalised' AND NOT EXISTS (
          SELECT 1 FROM finance_sst_return_boxes WHERE return_id = NEW.return_id
        ) THEN
          RAISE EXCEPTION 'return % is finalised without its box figures', NEW.return_id
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NULL;
      END
      $$
      """,
      # An adjustment is recorded only on an open return; a withdrawal names
      # an adjustment added to the same return.
      """
      CREATE FUNCTION #{prefix}finance_sst_record_adjustment() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM finance_sst_return_events
          WHERE return_id = NEW.return_id AND action IN ('finalised', 'discarded')
        ) THEN
          RAISE EXCEPTION 'return % is closed: its adjustments are kept as they are',
            NEW.return_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF NEW.action = 'withdrawn' AND NOT EXISTS (
          SELECT 1 FROM finance_sst_return_adjustments
          WHERE id = NEW.withdraws_adjustment_id AND return_id = NEW.return_id
            AND action = 'added'
        ) THEN
          RAISE EXCEPTION 'adjustment % is not an adjustment added to return %',
            NEW.withdraws_adjustment_id, NEW.return_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      # A finalised return's snapshot rows are inserted in the transaction
      # that finalises it, and never afterwards.
      """
      CREATE FUNCTION #{prefix}finance_sst_refuse_late_snapshot() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM finance_sst_return_events
          WHERE return_id = NEW.return_id AND action = 'finalised'
            AND #{@written_by_this_transaction}
        ) THEN
          RAISE EXCEPTION 'return % is not being finalised: a % row cannot be added',
            NEW.return_id, TG_TABLE_NAME
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """
    ]
  end

  defp triggers(prefix) do
    refuse = "EXECUTE FUNCTION #{prefix}finance_sst_refuse_change()"

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

    numbered =
      for table <- ~w(
            finance_sst_registrations
            finance_sst_mappings
            finance_sst_returns
            finance_sst_return_events
            finance_sst_return_adjustments
          ) do
        "CREATE TRIGGER #{table}_number BEFORE INSERT ON #{table} " <>
          "FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_sst_number()"
      end

    snapshots =
      for table <- ~w(
            finance_sst_return_boxes
            finance_sst_return_sources
            finance_sst_return_accounts
          ) do
        "CREATE TRIGGER #{table}_finalising BEFORE INSERT ON #{table} " <>
          "FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_sst_refuse_late_snapshot()"
      end

    append_only ++
      no_truncate ++
      numbered ++
      snapshots ++
      [
        # Runs after the numbering trigger (triggers fire in name order).
        """
        CREATE TRIGGER finance_sst_registrations_period_cycle
          BEFORE INSERT ON finance_sst_registrations
          FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_sst_check_registration()
        """,
        """
        CREATE TRIGGER finance_sst_returns_open
          BEFORE INSERT ON finance_sst_returns
          FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_sst_open_return()
        """,
        """
        CREATE CONSTRAINT TRIGGER finance_sst_returns_opened
          AFTER INSERT ON finance_sst_returns DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_sst_check_return()
        """,
        """
        CREATE TRIGGER finance_sst_return_events_record
          BEFORE INSERT ON finance_sst_return_events
          FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_sst_record_return_event()
        """,
        """
        CREATE CONSTRAINT TRIGGER finance_sst_return_events_figures_kept
          AFTER INSERT ON finance_sst_return_events DEFERRABLE INITIALLY DEFERRED
          FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_sst_check_finalised()
        """,
        """
        CREATE TRIGGER finance_sst_return_adjustments_record
          BEFORE INSERT ON finance_sst_return_adjustments
          FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_sst_record_adjustment()
        """
      ]
  end
end
