defmodule Bilimbi.Finance.Receivables.Migrations.CreateReceivables do
  @moduledoc """
  Receivables: each company's receivables setup and its change history,
  document series, tax codes, customers, invoices and credit notes with their
  lines and tax lines, and payments received with their allocations and
  reversals.

  Bilimbi-only. Rows of one company reference each other through composite
  `(id, company_id)` foreign keys. Ledger accounts and entries are named by
  ID only: the ledger's tables belong to `finance/ledger`, which this module
  reaches through its facade.

  A document is a draft until it is issued. A trigger refuses any change to
  an issued or discarded document, and any change to the lines and tax lines
  of a document that is no longer a draft, so an issued invoice is corrected
  by a credit note. Issuing checks that the header totals equal the lines,
  that the document number is the next in its series, and, for a credit
  note, that it credits an issued invoice of the same customer by no more
  than the invoice still owes. Payments, allocations, and payment reversals
  are append-only; a deferred constraint trigger refuses a commit in which
  a payment's allocations do not add up to its amount or settle an invoice
  beyond what it owes. An issued document records the receivable account it
  posted to, and what settles it posts there, so changing the setup's account
  never splits the subledger from the ledger; the setup's changes are kept in
  an append-only log. Nothing here is deleted: setups, series, tax codes,
  and customers are deactivated, and a draft is discarded and kept.
  """

  use Ecto.Migration

  def up do
    create table(:finance_receivables_setups, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :receivable_account_id, :bigint, null: false
      add :income_account_id, :bigint, null: false
      timestamps(type: :naive_datetime)
    end

    create unique_index(:finance_receivables_setups, [:company_id],
             name: :finance_receivables_setups_company_unique
           )

    create index(:finance_receivables_setups, [:tenant_id, :company_id])

    create table(:finance_receivables_setup_changes, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :field, :string, size: 32, null: false
      add :old_value, :bigint
      add :new_value, :bigint, null: false
      add :changed_by_user_id, :bigint, null: false
      add :changed_by_impersonator_id, :bigint
      add :changed_at, :utc_datetime_usec, null: false
    end

    create index(:finance_receivables_setup_changes, [:tenant_id, :company_id])

    create constraint(
             :finance_receivables_setup_changes,
             :finance_receivables_setup_changes_field,
             check: "field IN ('receivable_account_id', 'income_account_id')"
           )

    create table(:finance_receivables_series, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :code, :string, size: 50, null: false
      add :name, :string, size: 200, null: false
      add :kind, :string, size: 16, null: false
      add :prefix, :string, size: 20, null: false
      add :number_width, :smallint, null: false
      add :active, :boolean, null: false, default: true
      timestamps(type: :naive_datetime)
    end

    create unique_index(:finance_receivables_series, [:id, :company_id],
             name: :finance_receivables_series_id_company_unique
           )

    create unique_index(:finance_receivables_series, [:id, :company_id, :kind],
             name: :finance_receivables_series_id_company_kind_unique
           )

    create unique_index(:finance_receivables_series, [:company_id, :code],
             name: :finance_receivables_series_company_code_unique
           )

    create unique_index(:finance_receivables_series, [:company_id, :prefix],
             name: :finance_receivables_series_company_prefix_unique
           )

    create index(:finance_receivables_series, [:tenant_id, :company_id])

    create constraint(:finance_receivables_series, :finance_receivables_series_kind,
             check: "kind IN ('invoice', 'credit_note', 'payment')"
           )

    create constraint(:finance_receivables_series, :finance_receivables_series_number_width,
             check: "number_width BETWEEN 1 AND 12"
           )

    create table(:finance_receivables_tax_codes, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :code, :string, size: 50, null: false
      add :name, :string, size: 200, null: false
      add :rate, :decimal, precision: 9, scale: 4, null: false
      add :account_id, :bigint, null: false
      add :active, :boolean, null: false, default: true
      timestamps(type: :naive_datetime)
    end

    create unique_index(:finance_receivables_tax_codes, [:id, :company_id],
             name: :finance_receivables_tax_codes_id_company_unique
           )

    create unique_index(:finance_receivables_tax_codes, [:company_id, :code],
             name: :finance_receivables_tax_codes_company_code_unique
           )

    create index(:finance_receivables_tax_codes, [:tenant_id, :company_id])

    create constraint(:finance_receivables_tax_codes, :finance_receivables_tax_codes_rate,
             check: "rate >= 0 AND rate < 1000"
           )

    create table(:finance_receivables_customers, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :code, :string, size: 50, null: false
      add :name, :string, size: 200, null: false
      add :tax_identifier, :string, size: 50
      add :registration_identifier, :string, size: 50
      add :email, :string, size: 255
      add :phone, :string, size: 50
      add :line1, :string, size: 255
      add :line2, :string, size: 255
      add :line3, :string, size: 255
      add :locality, :string, size: 100
      add :postcode, :string, size: 20
      add :admin1_code, :string, size: 20
      add :country_iso, :string, size: 2
      add :payment_terms_days, :integer, null: false, default: 0
      add :active, :boolean, null: false, default: true
      timestamps(type: :naive_datetime)
    end

    create unique_index(:finance_receivables_customers, [:id, :company_id],
             name: :finance_receivables_customers_id_company_unique
           )

    create unique_index(:finance_receivables_customers, [:company_id, :code],
             name: :finance_receivables_customers_company_code_unique
           )

    create index(:finance_receivables_customers, [:tenant_id, :company_id])

    create constraint(:finance_receivables_customers, :finance_receivables_customers_country_iso,
             check: "country_iso ~ '^[A-Z]{2}$'"
           )

    create constraint(
             :finance_receivables_customers,
             :finance_receivables_customers_payment_terms_days,
             check: "payment_terms_days BETWEEN 0 AND 3650"
           )

    create table(:finance_receivables_documents, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :kind, :string, size: 16, null: false
      add :status, :string, size: 16, null: false

      add :series_id,
          references(:finance_receivables_series,
            type: :bigint,
            with: [company_id: :company_id, kind: :kind],
            on_delete: :restrict,
            name: :finance_receivables_documents_series_fkey
          ),
          null: false

      add :customer_id,
          references(:finance_receivables_customers,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_receivables_documents_customer_fkey
          ),
          null: false

      add :credited_document_id, :bigint
      add :receivable_account_id, :bigint
      add :currency_code, :string, size: 3, null: false
      add :issue_date, :date
      add :due_date, :date
      add :description, :string, size: 500
      add :subtotal, :decimal, precision: 20, scale: 4, null: false
      add :tax_total, :decimal, precision: 20, scale: 4, null: false
      add :total, :decimal, precision: 20, scale: 4, null: false
      add :document_number, :bigint
      add :document_reference, :string, size: 50
      add :party_name, :string, size: 200
      add :party_tax_identifier, :string, size: 50
      add :party_registration_identifier, :string, size: 50
      add :party_email, :string, size: 255
      add :party_phone, :string, size: 50
      add :party_line1, :string, size: 255
      add :party_line2, :string, size: 255
      add :party_line3, :string, size: 255
      add :party_locality, :string, size: 100
      add :party_postcode, :string, size: 20
      add :party_admin1_code, :string, size: 20
      add :party_country_iso, :string, size: 2
      add :ledger_entry_id, :bigint
      add :ledger_entry_number, :bigint
      add :issued_by_user_id, :bigint
      add :issued_by_impersonator_id, :bigint
      add :issued_at, :utc_datetime_usec
      add :discarded_by_user_id, :bigint
      add :discarded_at, :utc_datetime_usec
      timestamps(type: :naive_datetime)
    end

    create unique_index(:finance_receivables_documents, [:id, :company_id],
             name: :finance_receivables_documents_id_company_unique
           )

    execute("""
    ALTER TABLE finance_receivables_documents
      ADD CONSTRAINT finance_receivables_documents_credited_fkey
      FOREIGN KEY (credited_document_id, company_id)
      REFERENCES finance_receivables_documents (id, company_id)
      ON DELETE RESTRICT
    """)

    create unique_index(:finance_receivables_documents, [:series_id, :document_number],
             where: "document_number IS NOT NULL",
             name: :finance_receivables_documents_series_number_unique
           )

    create unique_index(:finance_receivables_documents, [:company_id, :document_reference],
             where: "document_reference IS NOT NULL",
             name: :finance_receivables_documents_company_reference_unique
           )

    create index(:finance_receivables_documents, [:tenant_id, :company_id, :customer_id],
             name: :finance_receivables_documents_customer_index
           )

    create index(:finance_receivables_documents, [:credited_document_id])

    create index(:finance_receivables_documents, [:company_id, :ledger_entry_number],
             where: "ledger_entry_number IS NOT NULL",
             name: :finance_receivables_documents_company_entry_number_index
           )

    create constraint(:finance_receivables_documents, :finance_receivables_documents_kind,
             check: "kind IN ('invoice', 'credit_note')"
           )

    create constraint(:finance_receivables_documents, :finance_receivables_documents_status,
             check: "status IN ('draft', 'issued', 'discarded')"
           )

    # A credit note, and only a credit note, names the invoice it credits.
    create constraint(:finance_receivables_documents, :finance_receivables_documents_credited,
             check: "(kind = 'credit_note') = (credited_document_id IS NOT NULL)"
           )

    create constraint(:finance_receivables_documents, :finance_receivables_documents_amounts,
             check: "subtotal >= 0 AND tax_total >= 0 AND total = subtotal + tax_total"
           )

    create constraint(:finance_receivables_documents, :finance_receivables_documents_due_date,
             check: "due_date IS NULL OR due_date >= issue_date"
           )

    # Only an issued document has a number, and it has everything issuing
    # records: the party snapshot, the posting, and who issued it when.
    create constraint(:finance_receivables_documents, :finance_receivables_documents_issued,
             check: """
             (status = 'issued') = (document_number IS NOT NULL)
             AND (status <> 'issued' OR (
               document_number > 0 AND document_reference IS NOT NULL
               AND issue_date IS NOT NULL AND (kind <> 'invoice' OR due_date IS NOT NULL)
               AND total > 0 AND party_name IS NOT NULL AND receivable_account_id IS NOT NULL
               AND ledger_entry_id IS NOT NULL AND ledger_entry_number IS NOT NULL
               AND issued_by_user_id IS NOT NULL AND issued_at IS NOT NULL))
             """
           )

    create constraint(:finance_receivables_documents, :finance_receivables_documents_discarded,
             check:
               "(status = 'discarded') = (discarded_at IS NOT NULL) " <>
                 "AND (status <> 'discarded' OR discarded_by_user_id IS NOT NULL)"
           )

    create table(:finance_receivables_document_lines, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false

      add :document_id,
          references(:finance_receivables_documents,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_receivables_document_lines_document_fkey
          ),
          null: false

      add :line_number, :integer, null: false
      add :description, :string, size: 500, null: false
      add :quantity, :decimal, precision: 20, scale: 4, null: false
      add :unit_price, :decimal, precision: 20, scale: 4, null: false
      add :amount, :decimal, precision: 20, scale: 4, null: false
      add :account_id, :bigint, null: false

      add :tax_code_id,
          references(:finance_receivables_tax_codes,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_receivables_document_lines_tax_code_fkey
          )

      add :tax_rate, :decimal, precision: 9, scale: 4
      add :tax_amount, :decimal, precision: 20, scale: 4, null: false
    end

    create unique_index(:finance_receivables_document_lines, [:document_id, :line_number],
             name: :finance_receivables_document_lines_document_line_unique
           )

    create constraint(
             :finance_receivables_document_lines,
             :finance_receivables_document_lines_line_number,
             check: "line_number > 0"
           )

    create constraint(
             :finance_receivables_document_lines,
             :finance_receivables_document_lines_amounts,
             check: "quantity > 0 AND unit_price >= 0 AND amount >= 0 AND tax_amount >= 0"
           )

    create constraint(
             :finance_receivables_document_lines,
             :finance_receivables_document_lines_tax,
             check:
               "(tax_code_id IS NULL) = (tax_rate IS NULL) " <>
                 "AND (tax_code_id IS NOT NULL OR tax_amount = 0)"
           )

    create table(:finance_receivables_document_tax_lines, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false

      add :document_id,
          references(:finance_receivables_documents,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_receivables_document_tax_lines_document_fkey
          ),
          null: false

      add :tax_code_id,
          references(:finance_receivables_tax_codes,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_receivables_document_tax_lines_tax_code_fkey
          ),
          null: false

      add :tax_code, :string, size: 50, null: false
      add :tax_rate, :decimal, precision: 9, scale: 4, null: false
      add :taxable_amount, :decimal, precision: 20, scale: 4, null: false
      add :tax_amount, :decimal, precision: 20, scale: 4, null: false
      add :account_id, :bigint, null: false
    end

    create unique_index(:finance_receivables_document_tax_lines, [:document_id, :tax_code_id],
             name: :finance_receivables_document_tax_lines_document_tax_code_unique
           )

    create constraint(
             :finance_receivables_document_tax_lines,
             :finance_receivables_document_tax_lines_amounts,
             check: "taxable_amount >= 0 AND tax_amount >= 0"
           )

    create table(:finance_receivables_payments, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false

      add :series_id,
          references(:finance_receivables_series,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_receivables_payments_series_fkey
          ),
          null: false

      add :customer_id,
          references(:finance_receivables_customers,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_receivables_payments_customer_fkey
          ),
          null: false

      add :payment_number, :bigint, null: false
      add :payment_reference, :string, size: 50, null: false
      add :payment_date, :date, null: false
      add :amount, :decimal, precision: 20, scale: 4, null: false
      add :currency_code, :string, size: 3, null: false
      add :deposit_account_id, :bigint, null: false
      add :reference, :string, size: 100
      add :description, :string, size: 500
      add :ledger_entry_id, :bigint, null: false
      add :ledger_entry_number, :bigint, null: false
      add :recorded_by_user_id, :bigint, null: false
      add :recorded_by_impersonator_id, :bigint
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create unique_index(:finance_receivables_payments, [:id, :company_id],
             name: :finance_receivables_payments_id_company_unique
           )

    create unique_index(:finance_receivables_payments, [:series_id, :payment_number],
             name: :finance_receivables_payments_series_number_unique
           )

    create unique_index(:finance_receivables_payments, [:company_id, :payment_reference],
             name: :finance_receivables_payments_company_reference_unique
           )

    create index(:finance_receivables_payments, [:tenant_id, :company_id, :customer_id],
             name: :finance_receivables_payments_customer_index
           )

    create constraint(:finance_receivables_payments, :finance_receivables_payments_amount,
             check: "amount > 0 AND payment_number > 0"
           )

    create table(:finance_receivables_allocations, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false

      add :payment_id,
          references(:finance_receivables_payments,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_receivables_allocations_payment_fkey
          ),
          null: false

      add :document_id,
          references(:finance_receivables_documents,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_receivables_allocations_document_fkey
          ),
          null: false

      add :amount, :decimal, precision: 20, scale: 4, null: false
    end

    create unique_index(:finance_receivables_allocations, [:payment_id, :document_id],
             name: :finance_receivables_allocations_payment_document_unique
           )

    create index(:finance_receivables_allocations, [:document_id])

    create constraint(:finance_receivables_allocations, :finance_receivables_allocations_amount,
             check: "amount > 0"
           )

    create table(:finance_receivables_payment_reversals, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false

      add :payment_id,
          references(:finance_receivables_payments,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_receivables_payment_reversals_payment_fkey
          ),
          null: false

      add :reversal_date, :date, null: false
      add :reason, :string, size: 500, null: false
      add :ledger_entry_id, :bigint, null: false
      add :ledger_entry_number, :bigint, null: false
      add :reversed_by_user_id, :bigint, null: false
      add :reversed_by_impersonator_id, :bigint
      add :reversed_at, :utc_datetime_usec, null: false
    end

    create unique_index(:finance_receivables_payment_reversals, [:payment_id],
             name: :finance_receivables_payment_reversals_payment_unique
           )

    create index(:finance_receivables_payment_reversals, [:tenant_id, :company_id],
             name: :finance_receivables_payment_reversals_company_index
           )

    execute("""
    CREATE FUNCTION finance_receivables_refuse_change() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'finance receivables keeps % rows: % is refused',
        TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
    END
    $$
    """)

    # The trigger's arguments name the columns that are a row's identity.
    execute("""
    CREATE FUNCTION finance_receivables_keep_identity() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      kept text;
    BEGIN
      FOREACH kept IN ARRAY TG_ARGV LOOP
        IF to_jsonb(NEW) -> kept IS DISTINCT FROM to_jsonb(OLD) -> kept THEN
          RAISE EXCEPTION 'finance receivables keeps % of % rows', kept, TG_TABLE_NAME
            USING ERRCODE = 'restrict_violation';
        END IF;
      END LOOP;

      RETURN NEW;
    END
    $$
    """)

    for {table, kept} <- [
          finance_receivables_setups: ~w(tenant_id company_id),
          finance_receivables_series: ~w(tenant_id company_id code kind prefix number_width),
          finance_receivables_tax_codes: ~w(tenant_id company_id code rate),
          finance_receivables_customers: ~w(tenant_id company_id code)
        ] do
      arguments = Enum.map_join(kept, ", ", &"'#{&1}'")

      execute("""
      CREATE TRIGGER #{table}_identity
        BEFORE UPDATE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION finance_receivables_keep_identity(#{arguments})
      """)

      execute("""
      CREATE TRIGGER #{table}_kept
        BEFORE DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION finance_receivables_refuse_change()
      """)
    end

    for table <- [
          :finance_receivables_setup_changes,
          :finance_receivables_payments,
          :finance_receivables_allocations,
          :finance_receivables_payment_reversals
        ] do
      execute("""
      CREATE TRIGGER #{table}_append_only
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION finance_receivables_refuse_change()
      """)
    end

    execute("""
    CREATE TRIGGER finance_receivables_documents_kept
      BEFORE DELETE ON finance_receivables_documents
      FOR EACH ROW EXECUTE FUNCTION finance_receivables_refuse_change()
    """)

    for table <- tables() do
      execute("""
      CREATE TRIGGER #{table}_no_truncate
        BEFORE TRUNCATE ON #{table}
        FOR EACH STATEMENT EXECUTE FUNCTION finance_receivables_refuse_change()
      """)
    end

    # What an issued invoice still owes: its total less its issued credit
    # notes and its allocations from payments that were not reversed.
    execute("""
    CREATE FUNCTION finance_receivables_outstanding(invoice_id bigint) RETURNS numeric
    LANGUAGE sql STABLE AS $$
      SELECT d.total
        - COALESCE((SELECT sum(c.total) FROM finance_receivables_documents c
                    WHERE c.credited_document_id = d.id AND c.status = 'issued'), 0)
        - COALESCE((SELECT sum(a.amount) FROM finance_receivables_allocations a
                    WHERE a.document_id = d.id
                      AND NOT EXISTS (SELECT 1 FROM finance_receivables_payment_reversals r
                                      WHERE r.payment_id = a.payment_id)), 0)
      FROM finance_receivables_documents d
      WHERE d.id = invoice_id
    $$
    """)

    execute("""
    CREATE FUNCTION finance_receivables_guard_document() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      credited finance_receivables_documents%ROWTYPE;
    BEGIN
      IF OLD.status <> 'draft' THEN
        RAISE EXCEPTION 'finance receivables document % is %: it is never changed; issue a credit note',
          OLD.id, OLD.status
          USING ERRCODE = 'restrict_violation';
      END IF;

      IF NEW.tenant_id <> OLD.tenant_id OR NEW.company_id <> OLD.company_id
        OR NEW.kind <> OLD.kind THEN
        RAISE EXCEPTION 'a finance receivables document keeps its company and kind'
          USING ERRCODE = 'restrict_violation';
      END IF;

      IF NEW.status = 'discarded' THEN
        NEW.discarded_at := clock_timestamp() AT TIME ZONE 'UTC';
      ELSIF NEW.status = 'issued' THEN
        IF NEW.document_number IS DISTINCT FROM COALESCE(
          (SELECT max(document_number) FROM finance_receivables_documents
           WHERE series_id = NEW.series_id), 0) + 1 THEN
          RAISE EXCEPTION 'document % is not the next number in series %',
            NEW.document_number, NEW.series_id
            USING ERRCODE = 'check_violation';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM finance_receivables_document_lines WHERE document_id = NEW.id)
          OR NEW.subtotal <> (SELECT sum(amount) FROM finance_receivables_document_lines
                              WHERE document_id = NEW.id)
          OR NEW.tax_total <> (SELECT sum(tax_amount) FROM finance_receivables_document_lines
                               WHERE document_id = NEW.id)
          OR NEW.tax_total <> COALESCE((SELECT sum(tax_amount)
                                        FROM finance_receivables_document_tax_lines
                                        WHERE document_id = NEW.id), 0) THEN
          RAISE EXCEPTION 'document % totals do not equal its lines', NEW.id
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.kind = 'credit_note' THEN
          SELECT * INTO credited FROM finance_receivables_documents
          WHERE id = NEW.credited_document_id;

          IF credited.kind <> 'invoice' OR credited.status <> 'issued'
            OR credited.customer_id <> NEW.customer_id THEN
            RAISE EXCEPTION 'a credit note credits an issued invoice of the same customer'
              USING ERRCODE = 'check_violation';
          END IF;

          IF NEW.receivable_account_id IS DISTINCT FROM credited.receivable_account_id THEN
            RAISE EXCEPTION 'a credit note posts to the receivable account of its invoice'
              USING ERRCODE = 'check_violation';
          END IF;

          IF finance_receivables_outstanding(credited.id) < NEW.total THEN
            RAISE EXCEPTION 'credit note % exceeds what invoice % still owes', NEW.id, credited.id
              USING ERRCODE = 'check_violation';
          END IF;
        END IF;

        NEW.issued_at := clock_timestamp() AT TIME ZONE 'UTC';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER finance_receivables_documents_guard
      BEFORE UPDATE ON finance_receivables_documents
      FOR EACH ROW EXECUTE FUNCTION finance_receivables_guard_document()
    """)

    # A document is inserted as a draft; only issuing gives it a number.
    execute("""
    CREATE FUNCTION finance_receivables_insert_draft() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status <> 'draft' THEN
        RAISE EXCEPTION 'a finance receivables document is created as a draft'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER finance_receivables_documents_draft
      BEFORE INSERT ON finance_receivables_documents
      FOR EACH ROW EXECUTE FUNCTION finance_receivables_insert_draft()
    """)

    execute("""
    CREATE FUNCTION finance_receivables_guard_draft_line() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      parent_id bigint;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        parent_id := OLD.document_id;
      ELSE
        parent_id := NEW.document_id;
      END IF;

      IF TG_OP = 'UPDATE' AND NEW.document_id <> OLD.document_id THEN
        RAISE EXCEPTION 'a line keeps its document'
          USING ERRCODE = 'restrict_violation';
      END IF;

      IF (SELECT status FROM finance_receivables_documents WHERE id = parent_id) <> 'draft' THEN
        RAISE EXCEPTION 'finance receivables document % is no longer a draft: its lines are kept',
          parent_id
          USING ERRCODE = 'restrict_violation';
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      RETURN NEW;
    END
    $$
    """)

    for table <- [:finance_receivables_document_lines, :finance_receivables_document_tax_lines] do
      execute("""
      CREATE TRIGGER #{table}_draft_only
        BEFORE INSERT OR UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION finance_receivables_guard_draft_line()
      """)
    end

    # A payment's number is the next in its payment series, and the database
    # stamps when it was recorded, whatever the inserting writer sent.
    execute("""
    CREATE FUNCTION finance_receivables_number_payment() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF (SELECT kind FROM finance_receivables_series WHERE id = NEW.series_id) <> 'payment' THEN
        RAISE EXCEPTION 'a payment is numbered by a payment series'
          USING ERRCODE = 'check_violation';
      END IF;

      IF NEW.payment_number IS DISTINCT FROM COALESCE(
        (SELECT max(payment_number) FROM finance_receivables_payments
         WHERE series_id = NEW.series_id), 0) + 1 THEN
        RAISE EXCEPTION 'payment % is not the next number in series %',
          NEW.payment_number, NEW.series_id
          USING ERRCODE = 'check_violation';
      END IF;

      NEW.recorded_at := clock_timestamp() AT TIME ZONE 'UTC';
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER finance_receivables_payments_number
      BEFORE INSERT ON finance_receivables_payments
      FOR EACH ROW EXECUTE FUNCTION finance_receivables_number_payment()
    """)

    execute("""
    CREATE FUNCTION finance_receivables_check_allocation() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM finance_receivables_documents d
        JOIN finance_receivables_payments p ON p.id = NEW.payment_id
        WHERE d.id = NEW.document_id AND d.kind = 'invoice' AND d.status = 'issued'
          AND d.customer_id = p.customer_id
      ) THEN
        RAISE EXCEPTION 'a payment is allocated to an issued invoice of its customer'
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER finance_receivables_allocations_invoice
      BEFORE INSERT ON finance_receivables_allocations
      FOR EACH ROW EXECUTE FUNCTION finance_receivables_check_allocation()
    """)

    execute("""
    CREATE FUNCTION finance_receivables_setup_change_stamp() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      NEW.changed_at := clock_timestamp() AT TIME ZONE 'UTC';
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER finance_receivables_setup_changes_stamp
      BEFORE INSERT ON finance_receivables_setup_changes
      FOR EACH ROW EXECUTE FUNCTION finance_receivables_setup_change_stamp()
    """)

    execute("""
    CREATE FUNCTION finance_receivables_reversal_stamp() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      NEW.reversed_at := clock_timestamp() AT TIME ZONE 'UTC';
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER finance_receivables_payment_reversals_stamp
      BEFORE INSERT ON finance_receivables_payment_reversals
      FOR EACH ROW EXECUTE FUNCTION finance_receivables_reversal_stamp()
    """)

    # At commit, a payment's allocations add up to its amount, and no
    # invoice it settles owes less than nothing.
    execute("""
    CREATE FUNCTION finance_receivables_check_payment() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      checked_id bigint;
    BEGIN
      IF TG_TABLE_NAME = 'finance_receivables_payments' THEN
        checked_id := NEW.id;
      ELSE
        checked_id := NEW.payment_id;
      END IF;

      IF (SELECT p.amount - COALESCE(sum(a.amount), 0)
          FROM finance_receivables_payments p
          LEFT JOIN finance_receivables_allocations a ON a.payment_id = p.id
          WHERE p.id = checked_id GROUP BY p.amount) <> 0 THEN
        RAISE EXCEPTION 'payment % allocations do not equal its amount', checked_id
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1 FROM finance_receivables_allocations a
        WHERE a.payment_id = checked_id AND finance_receivables_outstanding(a.document_id) < 0
      ) THEN
        RAISE EXCEPTION 'payment % settles an invoice beyond what it owes', checked_id
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NULL;
    END
    $$
    """)

    for table <- [:finance_receivables_payments, :finance_receivables_allocations] do
      execute("""
      CREATE CONSTRAINT TRIGGER #{table}_settled
        AFTER INSERT ON #{table}
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION finance_receivables_check_payment()
      """)
    end
  end

  def down do
    for table <- Enum.reverse(tables()), do: drop(table(table))

    for function <- [
          "finance_receivables_check_payment()",
          "finance_receivables_reversal_stamp()",
          "finance_receivables_setup_change_stamp()",
          "finance_receivables_check_allocation()",
          "finance_receivables_number_payment()",
          "finance_receivables_guard_draft_line()",
          "finance_receivables_insert_draft()",
          "finance_receivables_guard_document()",
          "finance_receivables_outstanding(bigint)",
          "finance_receivables_keep_identity()",
          "finance_receivables_refuse_change()"
        ] do
      execute("DROP FUNCTION #{function}")
    end
  end

  defp tables do
    [
      :finance_receivables_setups,
      :finance_receivables_setup_changes,
      :finance_receivables_series,
      :finance_receivables_tax_codes,
      :finance_receivables_customers,
      :finance_receivables_documents,
      :finance_receivables_document_lines,
      :finance_receivables_document_tax_lines,
      :finance_receivables_payments,
      :finance_receivables_allocations,
      :finance_receivables_payment_reversals
    ]
  end
end
