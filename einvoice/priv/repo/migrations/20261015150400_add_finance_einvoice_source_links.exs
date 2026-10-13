defmodule Bilimbi.Finance.Einvoice.Migrations.AddSourceLinks do
  @moduledoc """
  The source transaction a fiscal document is the tax document of.

  Bilimbi-only. A document issued for a transaction another module already
  recognised in the ledger (a receivables invoice, a payables self-billed
  bill) carries one link per source: the source module (its descriptor ID),
  the record in that module's terms, and the ledger entry that record
  posted, as the ledger names that entry's owner. A linked document never
  posts to the ledger itself: its accounting lives with its source, and so
  does its correction. A consolidated document carries its sources' links.

  PostgreSQL enforces what the facade checks:

  - a link is written only in the transaction that records its document,
    and a document links each source once;
  - a source has one standing fiscal document: a second link to it is
    refused while another document that links it stands (its latest status
    is `submitted`, `valid`, `rejected`, or `consolidated`), unless the new
    document is a consolidated document covering that one;
  - a document is not submitted while another standing document links one
    of its sources, by the same rule;
  - links are append-only.
  """

  use Ecto.Migration

  @functions ~w(
    finance_einvoice_standing_source_link
    finance_einvoice_refuse_second_source_link
    finance_einvoice_refuse_linked_submission
  )

  def up, do: Enum.each(statements(), &execute/1)

  def down do
    execute("DROP TRIGGER finance_einvoice_submissions_linked ON finance_einvoice_submissions")
    execute("DROP TABLE finance_einvoice_source_links")
    for function <- Enum.reverse(@functions), do: execute("DROP FUNCTION #{function}")
  end

  @doc """
  The schema's SQL in order. With `temporary: true` the table is temporary
  and the functions live in `pg_temp`, for module tests, which create the
  first migration's functions there too.
  """
  def statements(options \\ []) do
    {table, prefix} =
      if Keyword.get(options, :temporary, false),
        do: {"TEMPORARY TABLE", "pg_temp."},
        else: {"TABLE", ""}

    tables(table) ++ functions(prefix) ++ triggers(prefix)
  end

  defp tables(table) do
    persistence = if table == "TABLE", do: "", else: " ON COMMIT PRESERVE ROWS"

    [
      """
      CREATE #{table} finance_einvoice_source_links (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        document_id bigint NOT NULL,
        source_module varchar(100) NOT NULL,
        source_record varchar(100) NOT NULL,
        ledger_entry_id bigint NOT NULL,
        CONSTRAINT finance_einvoice_source_links_document_fkey
          FOREIGN KEY (document_id, company_id)
          REFERENCES finance_einvoice_documents (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_einvoice_source_links_source_module
          CHECK (source_module ~ '^[a-z][a-z0-9_]*/[a-z][a-z0-9_]*$'),
        CONSTRAINT finance_einvoice_source_links_source_record
          CHECK (source_record ~ '^[a-z][a-z0-9_]*:[1-9][0-9]*$'),
        CONSTRAINT finance_einvoice_source_links_ledger_entry_id CHECK (ledger_entry_id > 0)
      )#{persistence}
      """,
      """
      CREATE UNIQUE INDEX finance_einvoice_source_links_unique
        ON finance_einvoice_source_links (document_id, source_module, source_record)
      """,
      """
      CREATE INDEX finance_einvoice_source_links_source_index
        ON finance_einvoice_source_links (company_id, source_module, source_record)
      """
    ]
  end

  # A document stands for its source while its latest status is one the
  # authority holds or will: submitted, valid, rejected, or consolidated.
  @standing "('submitted', 'valid', 'rejected', 'consolidated')"
  @statuses "('issued', 'submitted', 'refused', 'valid', 'invalid', 'cancelled', 'rejected', " <>
              "'consolidated', 'released')"

  @doc """
  The trigger functions, created under `prefix` (`""`, or `"pg_temp."` for
  module tests).
  """
  def functions(prefix) do
    [
      # Another standing document linking the same source as `link`, other
      # than `document` itself and the documents it covers, or NULL.
      """
      CREATE FUNCTION #{prefix}finance_einvoice_standing_source_link(
        link finance_einvoice_source_links, document bigint
      ) RETURNS bigint
      LANGUAGE sql STABLE AS $$
        SELECT other.document_id
        FROM finance_einvoice_source_links other
        WHERE other.company_id = link.company_id
          AND other.source_module = link.source_module
          AND other.source_record = link.source_record
          AND other.document_id <> document
          AND (SELECT e.event FROM finance_einvoice_status_events e
               WHERE e.document_id = other.document_id AND e.event IN #{@statuses}
               ORDER BY e.sequence DESC LIMIT 1) IN #{@standing}
          AND NOT EXISTS (
            SELECT 1 FROM finance_einvoice_consolidated_sources c
            WHERE c.document_id = document AND c.source_document_id = other.document_id)
        ORDER BY other.document_id
        LIMIT 1
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_einvoice_refuse_second_source_link() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        standing bigint;
      BEGIN
        standing := #{prefix}finance_einvoice_standing_source_link(NEW, NEW.document_id);

        IF standing IS NOT NULL THEN
          RAISE EXCEPTION '% % is the source of document %, which stands',
            NEW.source_module, NEW.source_record, standing
            USING ERRCODE = 'unique_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_einvoice_refuse_linked_submission() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        link finance_einvoice_source_links%ROWTYPE;
        standing bigint;
      BEGIN
        FOR link IN
          SELECT * FROM finance_einvoice_source_links WHERE document_id = NEW.document_id
        LOOP
          standing := #{prefix}finance_einvoice_standing_source_link(link, NEW.document_id);

          IF standing IS NOT NULL THEN
            RAISE EXCEPTION 'document % is not submitted: % % is the source of document %, which stands',
              NEW.document_id, link.source_module, link.source_record, standing
              USING ERRCODE = 'restrict_violation';
          END IF;
        END LOOP;

        RETURN NEW;
      END
      $$
      """
    ]
  end

  defp triggers(prefix) do
    table = "finance_einvoice_source_links"

    [
      """
      CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_einvoice_refuse_change()
      """,
      """
      CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table}
        FOR EACH STATEMENT EXECUTE FUNCTION #{prefix}finance_einvoice_refuse_change()
      """,
      """
      CREATE TRIGGER #{table}_recorded_document BEFORE INSERT ON #{table}
        FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_einvoice_refuse_recorded_line()
      """,
      """
      CREATE TRIGGER #{table}_standing BEFORE INSERT ON #{table}
        FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_einvoice_refuse_second_source_link()
      """,
      """
      CREATE TRIGGER finance_einvoice_submissions_linked
        BEFORE INSERT ON finance_einvoice_submissions
        FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_einvoice_refuse_linked_submission()
      """
    ]
  end
end
