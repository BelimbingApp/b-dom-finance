defmodule Bilimbi.Finance.Payables.Migrations.AddPaymentRequests do
  @moduledoc """
  Payment requests: a payment is submitted by one person and posted only
  when a second person approves it.

  Bilimbi-only. A request records what the payment will be (party, date,
  paid-from account, amount, reference, description) and its allocations to
  bills, with the submitter and the database's time, numbered per company
  without gaps. It is decided once by an append-only event: `posted`,
  naming the payment its approval posted, which must carry the request's
  party, date, paid-from account, and amount; or `rejected`, with a reason.
  An allocation is added only in the transaction that submits its request, a
  deferred constraint trigger refuses a commit in which a request's
  allocations differ from its amount, and every table here is append-only.

  The migration is self-contained, and `statements/1` is its one source:
  `test/support/test_fixtures.ex` runs it with `temporary: true` after the
  earlier migrations' statements.
  """

  use Ecto.Migration

  @tables ~w(
    finance_payables_payment_requests
    finance_payables_payment_request_allocations
    finance_payables_payment_request_events
  )

  @functions ~w(
    finance_payables_number_payment_request
    finance_payables_refuse_submitted_request_allocation
    finance_payables_check_payment_request
    finance_payables_payment_request_decided
  )

  def up, do: Enum.each(statements(), &execute/1)

  def down do
    for table <- Enum.reverse(@tables), do: execute("DROP TABLE #{table}")
    for function <- Enum.reverse(@functions), do: execute("DROP FUNCTION #{function}()")
  end

  @doc """
  The schema change's SQL in order. With `temporary: true` the tables are
  temporary and the functions live in `pg_temp`, over the temporary copies
  the earlier migrations' `statements(temporary: true)` created.
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
      """
      CREATE #{table} finance_payables_payment_requests (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        request_number bigint NOT NULL,
        payment_date date NOT NULL,
        party_key varchar(100) NOT NULL,
        party_name varchar(200) NOT NULL,
        paid_from_account_id bigint NOT NULL,
        amount numeric(20, 4) NOT NULL,
        currency_code varchar(3) NOT NULL,
        reference varchar(100),
        description varchar(500),
        submitted_by_user_id bigint NOT NULL,
        submitted_by_impersonator_id bigint,
        submitted_at timestamp(6) NOT NULL,
        CONSTRAINT finance_payables_payment_requests_amount CHECK (amount > 0),
        CONSTRAINT finance_payables_payment_requests_currency_code
          CHECK (currency_code ~ '^[A-Z]{3}$'),
        CONSTRAINT finance_payables_payment_requests_request_number CHECK (request_number > 0)
      )
      """,
      """
      CREATE UNIQUE INDEX finance_payables_payment_requests_id_company_unique
        ON finance_payables_payment_requests (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_payables_payment_requests_company_number_unique
        ON finance_payables_payment_requests (company_id, request_number)
      """,
      """
      CREATE INDEX finance_payables_payment_requests_tenant_id_company_id_index
        ON finance_payables_payment_requests (tenant_id, company_id)
      """,
      """
      CREATE #{table} finance_payables_payment_request_allocations (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        request_id bigint NOT NULL,
        line_number integer NOT NULL,
        document_id bigint NOT NULL,
        amount numeric(20, 4) NOT NULL,
        CONSTRAINT finance_payables_payment_request_allocations_request_fkey
          FOREIGN KEY (request_id, company_id)
          REFERENCES finance_payables_payment_requests (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_payables_payment_request_allocations_document_fkey
          FOREIGN KEY (document_id, company_id)
          REFERENCES finance_payables_documents (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_payables_payment_request_allocations_line_number
          CHECK (line_number > 0),
        CONSTRAINT finance_payables_payment_request_allocations_amount CHECK (amount > 0)
      )
      """,
      """
      CREATE UNIQUE INDEX finance_payables_payment_request_allocations_line_unique
        ON finance_payables_payment_request_allocations (request_id, line_number)
      """,
      """
      CREATE UNIQUE INDEX finance_payables_payment_request_allocations_document_unique
        ON finance_payables_payment_request_allocations (request_id, document_id)
      """,
      """
      CREATE INDEX finance_payables_request_allocations_tenant_company_index
        ON finance_payables_payment_request_allocations (tenant_id, company_id)
      """,
      """
      CREATE #{table} finance_payables_payment_request_events (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        request_id bigint NOT NULL,
        event varchar(16) NOT NULL,
        reason varchar(500),
        payment_id bigint,
        actor_user_id bigint NOT NULL,
        actor_impersonator_id bigint,
        occurred_at timestamp(6) NOT NULL,
        CONSTRAINT finance_payables_payment_request_events_request_fkey
          FOREIGN KEY (request_id, company_id)
          REFERENCES finance_payables_payment_requests (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_payables_payment_request_events_payment_fkey
          FOREIGN KEY (payment_id, company_id)
          REFERENCES finance_payables_payments (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_payables_payment_request_events_event
          CHECK (event IN ('posted', 'rejected')),
        CONSTRAINT finance_payables_payment_request_events_payment
          CHECK ((event = 'posted') = (payment_id IS NOT NULL)),
        CONSTRAINT finance_payables_payment_request_events_reason
          CHECK (event <> 'rejected' OR (reason IS NOT NULL AND btrim(reason) <> ''))
      )
      """,
      # A request is decided once, and a payment answers one request.
      """
      CREATE UNIQUE INDEX finance_payables_payment_request_events_request_unique
        ON finance_payables_payment_request_events (request_id)
      """,
      """
      CREATE UNIQUE INDEX finance_payables_payment_request_events_payment_unique
        ON finance_payables_payment_request_events (payment_id) WHERE payment_id IS NOT NULL
      """,
      """
      CREATE INDEX finance_payables_payment_request_events_tenant_company_index
        ON finance_payables_payment_request_events (tenant_id, company_id)
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
      CREATE FUNCTION #{prefix}finance_payables_number_payment_request() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        NEW.request_number := COALESCE(
          (SELECT max(request_number) FROM finance_payables_payment_requests
           WHERE company_id = NEW.company_id), 0) + 1;
        NEW.submitted_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_payables_refuse_submitted_request_allocation()
      RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM finance_payables_payment_requests
          WHERE id = NEW.request_id AND NOT (#{@written_by_this_transaction})
        ) THEN
          RAISE EXCEPTION 'payment request % is already submitted: an allocation cannot be added',
            NEW.request_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_payables_check_payment_request() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        checked_id bigint;
      BEGIN
        IF TG_TABLE_NAME = 'finance_payables_payment_requests' THEN
          checked_id := NEW.id;
        ELSE
          checked_id := NEW.request_id;
        END IF;

        IF (SELECT amount FROM finance_payables_payment_requests WHERE id = checked_id)
           IS DISTINCT FROM
           (SELECT sum(amount) FROM finance_payables_payment_request_allocations
            WHERE request_id = checked_id) THEN
          RAISE EXCEPTION 'payment request % allocations differ from its amount', checked_id
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NULL;
      END
      $$
      """,
      # A posting names the payment it posted, which pays what was requested.
      """
      CREATE FUNCTION #{prefix}finance_payables_payment_request_decided() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.event = 'posted' AND NOT EXISTS (
          SELECT 1
          FROM finance_payables_payment_requests r
          JOIN finance_payables_payments p ON p.id = NEW.payment_id AND p.company_id = r.company_id
          WHERE r.id = NEW.request_id AND r.company_id = NEW.company_id
            AND p.reverses_payment_id IS NULL
            AND p.party_key = r.party_key AND p.payment_date = r.payment_date
            AND p.paid_from_account_id = r.paid_from_account_id AND p.amount = r.amount
        ) THEN
          RAISE EXCEPTION 'payment request % is posted only by a payment of what it requested',
            NEW.request_id
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
    refuse = "EXECUTE FUNCTION #{prefix}finance_payables_refuse_change()"

    Enum.flat_map(@tables, fn table ->
      [
        "CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table} " <>
          "FOR EACH ROW #{refuse}",
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} " <>
          "FOR EACH STATEMENT #{refuse}"
      ]
    end) ++
      [
        """
        CREATE TRIGGER finance_payables_payment_requests_number
          BEFORE INSERT ON finance_payables_payment_requests
          FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_payables_number_payment_request()
        """,
        """
        CREATE TRIGGER finance_payables_payment_request_allocations_open_request
          BEFORE INSERT ON finance_payables_payment_request_allocations
          FOR EACH ROW EXECUTE FUNCTION
            #{prefix}finance_payables_refuse_submitted_request_allocation()
        """,
        """
        CREATE TRIGGER finance_payables_payment_request_events_decided
          BEFORE INSERT ON finance_payables_payment_request_events
          FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_payables_payment_request_decided()
        """
      ] ++
      for table <-
            ~w(finance_payables_payment_requests finance_payables_payment_request_allocations) do
        "CREATE CONSTRAINT TRIGGER #{table}_allocated AFTER INSERT ON #{table} " <>
          "DEFERRABLE INITIALLY DEFERRED " <>
          "FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_payables_check_payment_request()"
      end
  end
end
