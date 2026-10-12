defmodule Bilimbi.Finance.Einvoice.Migrations.CreateEinvoice do
  @moduledoc """
  Fiscal documents a company issues through a clearance authority, the
  signed submissions sent for them, the status events the authority's
  answers produce, and each company's overrides of the authority's code
  lists.

  Bilimbi-only. A document, its lines, a submission, and a status event are
  append-only: a trigger refuses UPDATE, DELETE, and TRUNCATE, so a
  cancellation or a rejection is a new status event, never an edit. The
  database stamps each record's `recorded_at`, numbers a document's status
  events 1, 2, 3, ..., refuses a line added to a document recorded in an
  earlier transaction, checks a submission's SHA-256 against its payload
  bytes, and refuses a commit in which a document has no lines or its
  totals differ from its lines'. Rows of one company reference each other
  through composite `(id, company_id)` foreign keys.

  The authority's code lists ship with the module as reference data; a
  company's overrides rename, retire, or add a code for that company only.
  An override is not a fiscal record, so it stays editable.
  """

  use Ecto.Migration

  @records [
    :finance_einvoice_documents,
    :finance_einvoice_document_lines,
    :finance_einvoice_submissions,
    :finance_einvoice_status_events
  ]

  def up do
    create table(:finance_einvoice_documents, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :authority, :string, size: 32, null: false
      add :environment, :string, size: 16, null: false
      add :document_type, :string, size: 8, null: false
      add :code_number, :string, size: 50, null: false
      add :issued_at, :utc_datetime, null: false
      add :currency_code, :string, size: 3, null: false
      add :exchange_rate, :decimal, precision: 20, scale: 6
      add :supplier, :map, null: false
      add :buyer, :map, null: false
      add :details, :map, null: false, default: %{}
      add :original_document_id, :bigint
      add :line_extension_amount, :decimal, precision: 20, scale: 2, null: false
      add :tax_exclusive_amount, :decimal, precision: 20, scale: 2, null: false
      add :tax_amount, :decimal, precision: 20, scale: 2, null: false
      add :tax_inclusive_amount, :decimal, precision: 20, scale: 2, null: false
      add :payable_amount, :decimal, precision: 20, scale: 2, null: false
      add :issued_by_user_id, :bigint, null: false
      add :issued_by_impersonator_id, :bigint
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create unique_index(:finance_einvoice_documents, [:id, :company_id],
             name: :finance_einvoice_documents_id_company_unique
           )

    execute("""
    ALTER TABLE finance_einvoice_documents ADD CONSTRAINT finance_einvoice_documents_original_fkey
      FOREIGN KEY (original_document_id, company_id)
      REFERENCES finance_einvoice_documents (id, company_id) ON DELETE RESTRICT
    """)

    # The authority requires a code number unique to its supplier; sandbox
    # documents are tests and never take a production number.
    create unique_index(:finance_einvoice_documents, [:company_id, :environment, :code_number],
             name: :finance_einvoice_documents_code_number_unique
           )

    create index(:finance_einvoice_documents, [:tenant_id, :company_id, :issued_at])

    create constraint(:finance_einvoice_documents, :finance_einvoice_documents_environment,
             check: "environment IN ('sandbox', 'production')"
           )

    create constraint(:finance_einvoice_documents, :finance_einvoice_documents_currency_code,
             check: "currency_code ~ '^[A-Z]{3}$'"
           )

    create constraint(:finance_einvoice_documents, :finance_einvoice_documents_exchange_rate,
             check: "exchange_rate IS NULL OR exchange_rate > 0"
           )

    create constraint(:finance_einvoice_documents, :finance_einvoice_documents_not_own_original,
             check: "original_document_id IS NULL OR original_document_id <> id"
           )

    # Every total is non-negative, and the document's totals add up: there
    # are no document-level allowances, charges, or rounding yet.
    create constraint(:finance_einvoice_documents, :finance_einvoice_documents_totals,
             check: """
             line_extension_amount >= 0 AND tax_amount >= 0
             AND tax_exclusive_amount = line_extension_amount
             AND tax_inclusive_amount = tax_exclusive_amount + tax_amount
             AND payable_amount = tax_inclusive_amount
             """
           )

    create table(:finance_einvoice_document_lines, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false

      add :document_id,
          references(:finance_einvoice_documents,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_einvoice_document_lines_document_fkey
          ),
          null: false

      add :line_number, :integer, null: false
      add :description, :string, size: 300, null: false
      add :classification_code, :string, size: 16, null: false
      add :tariff_code, :string, size: 32
      add :origin_country_code, :string, size: 3
      add :quantity, :decimal, precision: 20, scale: 6, null: false
      add :unit_code, :string, size: 16
      add :unit_price, :decimal, precision: 20, scale: 6, null: false
      add :subtotal, :decimal, precision: 20, scale: 2, null: false
      add :discount_amount, :decimal, precision: 20, scale: 2, null: false, default: 0
      add :charge_amount, :decimal, precision: 20, scale: 2, null: false, default: 0
      add :line_extension_amount, :decimal, precision: 20, scale: 2, null: false
      add :tax_type, :string, size: 8, null: false
      add :tax_rate, :decimal, precision: 9, scale: 4
      add :tax_amount, :decimal, precision: 20, scale: 2, null: false
      add :tax_exemption_reason, :string, size: 300
    end

    create unique_index(:finance_einvoice_document_lines, [:document_id, :line_number],
             name: :finance_einvoice_document_lines_document_line_unique
           )

    create index(:finance_einvoice_document_lines, [:company_id])

    create constraint(
             :finance_einvoice_document_lines,
             :finance_einvoice_document_lines_line_number,
             check: "line_number > 0"
           )

    create constraint(:finance_einvoice_document_lines, :finance_einvoice_document_lines_amounts,
             check: """
             quantity > 0 AND unit_price >= 0 AND subtotal >= 0
             AND discount_amount >= 0 AND charge_amount >= 0 AND tax_amount >= 0
             AND line_extension_amount >= 0
             AND line_extension_amount = subtotal - discount_amount + charge_amount
             """
           )

    create constraint(:finance_einvoice_document_lines, :finance_einvoice_document_lines_tax_rate,
             check: "tax_rate IS NULL OR (tax_rate >= 0 AND tax_rate <= 100)"
           )

    create table(:finance_einvoice_submissions, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false

      add :document_id,
          references(:finance_einvoice_documents,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_einvoice_submissions_document_fkey
          ),
          null: false

      add :environment, :string, size: 16, null: false
      add :format, :string, size: 8, null: false
      add :document_version, :string, size: 8, null: false
      add :payload, :binary, null: false
      add :payload_sha256, :string, size: 64, null: false
      add_actor_columns()
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create unique_index(:finance_einvoice_submissions, [:id, :company_id],
             name: :finance_einvoice_submissions_id_company_unique
           )

    create index(:finance_einvoice_submissions, [:company_id, :document_id])

    create constraint(:finance_einvoice_submissions, :finance_einvoice_submissions_environment,
             check: "environment IN ('sandbox', 'production')"
           )

    create constraint(:finance_einvoice_submissions, :finance_einvoice_submissions_format,
             check: "format IN ('JSON', 'XML')"
           )

    # The stored hash is the hash of the stored bytes, whoever wrote them.
    create constraint(:finance_einvoice_submissions, :finance_einvoice_submissions_payload_sha256,
             check:
               "octet_length(payload) > 0 AND payload_sha256 = encode(sha256(payload), 'hex')"
           )

    create constraint(:finance_einvoice_submissions, :finance_einvoice_submissions_actor,
             check: actor_check()
           )

    create table(:finance_einvoice_status_events, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false

      add :document_id,
          references(:finance_einvoice_documents,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_einvoice_status_events_document_fkey
          ),
          null: false

      add :sequence, :integer, null: false

      add :submission_id,
          references(:finance_einvoice_submissions,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_einvoice_status_events_submission_fkey
          )

      add :event, :string, size: 32, null: false
      add :authority_status, :string, size: 32
      add :submission_uid, :string, size: 64
      add :document_uuid, :string, size: 64
      add :long_id, :string, size: 128
      add :reason, :string, size: 300
      add :http_status, :integer
      add :response, :map
      add_actor_columns()
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create unique_index(:finance_einvoice_status_events, [:document_id, :sequence],
             name: :finance_einvoice_status_events_document_sequence_unique
           )

    create index(:finance_einvoice_status_events, [:company_id, :document_uuid],
             where: "document_uuid IS NOT NULL"
           )

    create constraint(:finance_einvoice_status_events, :finance_einvoice_status_events_event,
             check: "event ~ '^[a-z][a-z_]*$'"
           )

    create constraint(
             :finance_einvoice_status_events,
             :finance_einvoice_status_events_http_status,
             check: "http_status IS NULL OR (http_status >= 100 AND http_status <= 599)"
           )

    create constraint(:finance_einvoice_status_events, :finance_einvoice_status_events_actor,
             check: actor_check()
           )

    create table(:finance_einvoice_code_overrides, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :authority, :string, size: 32, null: false
      add :list, :string, size: 32, null: false
      add :code, :string, size: 16, null: false
      add :description, :string, size: 500
      add :active, :boolean, null: false, default: true
      timestamps(type: :naive_datetime)
    end

    create unique_index(:finance_einvoice_code_overrides, [:company_id, :authority, :list, :code],
             name: :finance_einvoice_code_overrides_unique
           )

    create index(:finance_einvoice_code_overrides, [:tenant_id, :company_id])

    execute("""
    CREATE FUNCTION finance_einvoice_refuse_change() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'finance e-invoicing keeps % rows: % is refused; record a new status event',
        TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
    END
    $$
    """)

    for table <- @records do
      execute("""
      CREATE TRIGGER #{table}_append_only
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION finance_einvoice_refuse_change()
      """)

      execute("""
      CREATE TRIGGER #{table}_no_truncate
        BEFORE TRUNCATE ON #{table}
        FOR EACH STATEMENT EXECUTE FUNCTION finance_einvoice_refuse_change()
      """)
    end

    # The database's clock, whatever the inserting writer sent.
    execute("""
    CREATE FUNCTION finance_einvoice_stamp_recorded_at() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      NEW.recorded_at := clock_timestamp() AT TIME ZONE 'UTC';
      RETURN NEW;
    END
    $$
    """)

    for table <- [
          :finance_einvoice_documents,
          :finance_einvoice_submissions,
          :finance_einvoice_status_events
        ] do
      execute("""
      CREATE TRIGGER #{table}_recorded_at
        BEFORE INSERT ON #{table}
        FOR EACH ROW EXECUTE FUNCTION finance_einvoice_stamp_recorded_at()
      """)
    end

    # A document's events are numbered 1, 2, 3, ... in recording order; with
    # no deletion a number is never skipped or reused, and a concurrent
    # writer that takes the same number fails on the unique index.
    execute("""
    CREATE FUNCTION finance_einvoice_number_status_event() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      NEW.sequence := COALESCE(
        (SELECT max(sequence) FROM finance_einvoice_status_events
         WHERE document_id = NEW.document_id), 0) + 1;
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER finance_einvoice_status_events_number
      BEFORE INSERT ON finance_einvoice_status_events
      FOR EACH ROW EXECUTE FUNCTION finance_einvoice_number_status_event()
    """)

    # A document is recorded once its inserting transaction is no longer in
    # progress. pg_xact_status is NULL for a transaction older than the
    # retained commit log, so IS DISTINCT FROM keeps old documents refused.
    execute("""
    CREATE FUNCTION finance_einvoice_refuse_recorded_line() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM finance_einvoice_documents
        WHERE id = NEW.document_id
          AND pg_xact_status(
                ((pg_current_xact_id()::text::bigint >> 32 << 32) | xmin::text::bigint)::text::xid8
              ) IS DISTINCT FROM 'in progress'
      ) THEN
        RAISE EXCEPTION 'document % is already recorded: a line cannot be added; issue a note',
          NEW.document_id
          USING ERRCODE = 'restrict_violation';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER finance_einvoice_document_lines_recorded_document
      BEFORE INSERT ON finance_einvoice_document_lines
      FOR EACH ROW EXECUTE FUNCTION finance_einvoice_refuse_recorded_line()
    """)

    execute("""
    CREATE FUNCTION finance_einvoice_check_totals() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      checked_id bigint;
      document finance_einvoice_documents%ROWTYPE;
    BEGIN
      IF TG_TABLE_NAME = 'finance_einvoice_documents' THEN
        checked_id := NEW.id;
      ELSE
        checked_id := NEW.document_id;
      END IF;

      SELECT * INTO document FROM finance_einvoice_documents WHERE id = checked_id;

      IF NOT EXISTS (
        SELECT 1 FROM finance_einvoice_document_lines WHERE document_id = checked_id
      ) THEN
        RAISE EXCEPTION 'document % has no lines', checked_id
          USING ERRCODE = 'check_violation';
      END IF;

      IF (SELECT sum(line_extension_amount) FROM finance_einvoice_document_lines
          WHERE document_id = checked_id) <> document.line_extension_amount
        OR (SELECT sum(tax_amount) FROM finance_einvoice_document_lines
            WHERE document_id = checked_id) <> document.tax_amount THEN
        RAISE EXCEPTION 'document % totals differ from its lines', checked_id
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NULL;
    END
    $$
    """)

    for table <- [:finance_einvoice_documents, :finance_einvoice_document_lines] do
      execute("""
      CREATE CONSTRAINT TRIGGER #{table}_match_lines
        AFTER INSERT ON #{table}
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION finance_einvoice_check_totals()
      """)
    end
  end

  def down do
    drop table(:finance_einvoice_code_overrides)
    drop table(:finance_einvoice_status_events)
    drop table(:finance_einvoice_submissions)
    drop table(:finance_einvoice_document_lines)
    drop table(:finance_einvoice_documents)
    execute("DROP FUNCTION finance_einvoice_check_totals()")
    execute("DROP FUNCTION finance_einvoice_refuse_recorded_line()")
    execute("DROP FUNCTION finance_einvoice_number_status_event()")
    execute("DROP FUNCTION finance_einvoice_stamp_recorded_at()")
    execute("DROP FUNCTION finance_einvoice_refuse_change()")
  end

  # Who recorded a row: a signed-in user (and any impersonator), or a named
  # system principal acting for the company.
  defp add_actor_columns do
    add :actor_type, :string, size: 16, null: false
    add :actor_user_id, :bigint
    add :actor_impersonator_id, :bigint
    add :system_principal, :string, size: 100
  end

  defp actor_check do
    """
    (actor_type = 'user' AND actor_user_id IS NOT NULL AND system_principal IS NULL)
    OR (actor_type = 'system' AND actor_user_id IS NULL AND actor_impersonator_id IS NULL
        AND system_principal IS NOT NULL)
    """
  end
end
