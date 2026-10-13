defmodule Bilimbi.Finance.Attachments.Migrations.CreateAttachments do
  @moduledoc """
  Source documents kept with the records they support: each company's
  retention setting, every attachment captured, and the events that end or
  change one.

  Bilimbi-only. The file's bytes live in Base Artifacts as a records-grade
  document; an attachment row is the link from a Finance record (a bill, a
  payment, an invoice, a manual journal, a bank statement) to that artifact,
  with the file's name, type, size, and SHA-256, the retain-until the
  company's setting gave it, and who captured it when. The database numbers
  a company's attachments without gaps and stamps the capture time.

  The retention setting is never a column: it is the latest of the company's
  append-only retention changes (years kept after the end of a document's
  financial year), each with the actor, any impersonator, a reason, and the
  database's time; a company with none keeps documents for seven years. A
  change only ever lengthens it.

  An attachment's standing is its latest event: none while it stands, one
  `replaced` naming the attachment that took its place, or one `removed`;
  the database keeps at most one of those two per attachment. A retention
  extension, a legal hold placed, and a hold released are events too, each
  with its reason, and so is `retention_change_failed`, naming (once) the
  extension or hold that Base Artifacts then refused, which no longer counts.
  Every table here is append-only.

  The migration is self-contained, and `statements/1` is its one source:
  with `temporary: true` the tables are temporary and the functions live in
  `pg_temp`, for the module tests' fixtures.
  """

  use Ecto.Migration

  # The years a company keeps source documents until it sets its own. The
  # facade's `Bilimbi.Finance.Attachments.Retention.default_years/0` is the
  # same number; the module's tests check they agree.
  @default_years 7

  @tables ~w(
    finance_attachments_retention_changes
    finance_attachments
    finance_attachment_events
  )

  @functions ~w(
    finance_attachments_refuse_record_change
    finance_attachments_record_retention_change
    finance_attachments_record_attachment
    finance_attachments_record_event
  )

  @events ~w(replaced removed retention_extended hold_placed hold_released retention_change_failed)

  def up, do: Enum.each(statements(), &execute/1)

  def down do
    for table <- Enum.reverse(@tables), do: execute("DROP TABLE #{table}")
    for function <- Enum.reverse(@functions), do: execute("DROP FUNCTION #{function}()")
  end

  @doc "The years a company keeps source documents until it sets its own."
  def default_years, do: @default_years

  @doc """
  The schema change's SQL in order. With `temporary: true` the tables are
  temporary and the functions live in `pg_temp`.
  """
  def statements(options \\ []) do
    {table, function} =
      if Keyword.get(options, :temporary, false),
        do: {"TEMPORARY TABLE", "pg_temp."},
        else: {"TABLE", ""}

    tables(table) ++ functions(function) ++ triggers(function)
  end

  defp tables(table) do
    events = Enum.map_join(@events, ", ", &"'#{&1}'")

    [
      """
      CREATE #{table} finance_attachments_retention_changes (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        change_number bigint NOT NULL,
        years integer NOT NULL,
        reason varchar(500) NOT NULL,
        changed_by_user_id bigint NOT NULL,
        changed_by_impersonator_id bigint,
        changed_at timestamp(6) NOT NULL,
        CONSTRAINT finance_attachments_retention_changes_change_number
          CHECK (change_number > 0),
        CONSTRAINT finance_attachments_retention_changes_years CHECK (years > 0),
        CONSTRAINT finance_attachments_retention_changes_reason CHECK (btrim(reason) <> '')
      )
      """,
      """
      CREATE UNIQUE INDEX finance_attachments_retention_changes_id_company_unique
        ON finance_attachments_retention_changes (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_attachments_retention_changes_company_number_unique
        ON finance_attachments_retention_changes (company_id, change_number)
      """,
      """
      CREATE INDEX finance_attachments_retention_changes_tenant_company_index
        ON finance_attachments_retention_changes (tenant_id, company_id)
      """,
      # The record an attachment supports belongs to the module that names
      # it (`source`), so the link is a module-owned identifier rather than a
      # foreign key; `source_module` is the adapter that reads the record
      # back and decides whether it is final.
      """
      CREATE #{table} finance_attachments (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        attachment_number bigint NOT NULL,
        source varchar(100) NOT NULL,
        source_module varchar(255) NOT NULL,
        document_id bigint NOT NULL,
        document_label varchar(100) NOT NULL,
        document_date date NOT NULL,
        artifact_id uuid NOT NULL,
        file_name varchar(255) NOT NULL,
        content_type varchar(255) NOT NULL,
        byte_size bigint NOT NULL,
        sha256 varchar(64) NOT NULL,
        retention_years integer NOT NULL,
        retain_until timestamp(6) NOT NULL,
        captured_by_user_id bigint NOT NULL,
        captured_by_impersonator_id bigint,
        captured_at timestamp(6) NOT NULL,
        CONSTRAINT finance_attachments_attachment_number CHECK (attachment_number > 0),
        CONSTRAINT finance_attachments_source CHECK (btrim(source) <> ''),
        CONSTRAINT finance_attachments_document_id CHECK (document_id > 0),
        CONSTRAINT finance_attachments_document_label CHECK (btrim(document_label) <> ''),
        CONSTRAINT finance_attachments_file_name CHECK (btrim(file_name) <> ''),
        CONSTRAINT finance_attachments_byte_size CHECK (byte_size > 0),
        CONSTRAINT finance_attachments_sha256 CHECK (sha256 ~ '^[0-9a-f]{64}$'),
        CONSTRAINT finance_attachments_retention_years CHECK (retention_years > 0),
        CONSTRAINT finance_attachments_retain_until CHECK (retain_until > document_date)
      )
      """,
      """
      CREATE UNIQUE INDEX finance_attachments_id_company_unique
        ON finance_attachments (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_attachments_company_number_unique
        ON finance_attachments (company_id, attachment_number)
      """,
      """
      CREATE UNIQUE INDEX finance_attachments_artifact_unique
        ON finance_attachments (artifact_id)
      """,
      """
      CREATE INDEX finance_attachments_document_index
        ON finance_attachments (company_id, source, document_id, id)
      """,
      """
      CREATE INDEX finance_attachments_tenant_company_index
        ON finance_attachments (tenant_id, company_id)
      """,
      """
      CREATE #{table} finance_attachment_events (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        attachment_id bigint NOT NULL,
        event varchar(30) NOT NULL,
        replacement_id bigint,
        failed_event_id bigint,
        retain_until timestamp(6),
        reason varchar(500),
        actor_user_id bigint NOT NULL,
        actor_impersonator_id bigint,
        occurred_at timestamp(6) NOT NULL,
        CONSTRAINT finance_attachment_events_id_company_unique UNIQUE (id, company_id),
        CONSTRAINT finance_attachment_events_attachment_fkey
          FOREIGN KEY (attachment_id, company_id)
          REFERENCES finance_attachments (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_attachment_events_replacement_fkey
          FOREIGN KEY (replacement_id, company_id)
          REFERENCES finance_attachments (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_attachment_events_failed_fkey
          FOREIGN KEY (failed_event_id, company_id)
          REFERENCES finance_attachment_events (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_attachment_events_event CHECK (event IN (#{events})),
        CONSTRAINT finance_attachment_events_failed
          CHECK ((event = 'retention_change_failed') = (failed_event_id IS NOT NULL)),
        CONSTRAINT finance_attachment_events_replacement
          CHECK ((event = 'replaced') = (replacement_id IS NOT NULL)),
        CONSTRAINT finance_attachment_events_not_self
          CHECK (replacement_id IS NULL OR replacement_id <> attachment_id),
        CONSTRAINT finance_attachment_events_retain_until
          CHECK ((event = 'retention_extended') = (retain_until IS NOT NULL)),
        CONSTRAINT finance_attachment_events_reason
          CHECK (event IN ('replaced', 'retention_extended')
            OR (reason IS NOT NULL AND btrim(reason) <> ''))
      )
      """,
      """
      CREATE UNIQUE INDEX finance_attachment_events_standing_unique
        ON finance_attachment_events (attachment_id)
        WHERE event IN ('replaced', 'removed')
      """,
      """
      CREATE UNIQUE INDEX finance_attachment_events_failed_unique
        ON finance_attachment_events (failed_event_id)
        WHERE failed_event_id IS NOT NULL
      """,
      """
      CREATE INDEX finance_attachment_events_attachment_index
        ON finance_attachment_events (company_id, attachment_id, id)
      """,
      """
      CREATE INDEX finance_attachment_events_tenant_company_index
        ON finance_attachment_events (tenant_id, company_id)
      """
    ]
  end

  defp functions(prefix) do
    [
      """
      CREATE FUNCTION #{prefix}finance_attachments_refuse_record_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'finance attachments keep % rows: % is refused', TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END
      $$
      """,
      # The latest change decides the setting; with none, the default
      # applies. A change only ever lengthens the retention.
      """
      CREATE FUNCTION #{prefix}finance_attachments_record_retention_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        current integer;
      BEGIN
        SELECT years INTO current FROM finance_attachments_retention_changes
        WHERE company_id = NEW.company_id ORDER BY change_number DESC LIMIT 1;

        IF NEW.years <= COALESCE(current, #{@default_years}) THEN
          RAISE EXCEPTION 'retention of company % is % years and is only ever lengthened',
            NEW.company_id, COALESCE(current, #{@default_years})
            USING ERRCODE = 'restrict_violation';
        END IF;

        NEW.change_number := COALESCE(
          (SELECT max(change_number) FROM finance_attachments_retention_changes
           WHERE company_id = NEW.company_id), 0) + 1;
        NEW.changed_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_attachments_record_attachment() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        NEW.attachment_number := COALESCE(
          (SELECT max(attachment_number) FROM finance_attachments
           WHERE company_id = NEW.company_id), 0) + 1;
        NEW.captured_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      # A replacement is a later attachment of the same record.
      """
      CREATE FUNCTION #{prefix}finance_attachments_record_event() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        attachment finance_attachments%ROWTYPE;
        replacement finance_attachments%ROWTYPE;
      BEGIN
        SELECT * INTO attachment FROM finance_attachments
        WHERE id = NEW.attachment_id AND company_id = NEW.company_id;

        IF NEW.event = 'replaced' AND FOUND THEN
          SELECT * INTO replacement FROM finance_attachments
          WHERE id = NEW.replacement_id AND company_id = NEW.company_id;

          IF FOUND AND (replacement.source <> attachment.source
            OR replacement.document_id <> attachment.document_id
            OR replacement.id <= attachment.id) THEN
            RAISE EXCEPTION 'attachment % is replaced only by a later attachment of the same record',
              NEW.attachment_id
              USING ERRCODE = 'restrict_violation';
          END IF;
        END IF;

        NEW.occurred_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """
    ]
  end

  defp triggers(prefix) do
    refuse = "EXECUTE FUNCTION #{prefix}finance_attachments_refuse_record_change()"

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
          "finance_attachments_retention_changes",
          "finance_attachments_record_retention_change"
        ),
        record.("finance_attachments", "finance_attachments_record_attachment"),
        record.("finance_attachment_events", "finance_attachments_record_event")
      ]
  end
end
