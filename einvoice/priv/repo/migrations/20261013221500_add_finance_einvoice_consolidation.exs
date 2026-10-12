defmodule Bilimbi.Finance.Einvoice.Migrations.AddConsolidation do
  @moduledoc """
  The documents a consolidated document covers.

  Bilimbi-only. A consolidated document reports, in one document to the
  authority, the sales of a period that no buyer asked an individual
  document for. Each row names one covered (source) document and a line
  of the consolidated document that carries it (a source whose lines are
  taxed differently is carried by one line per tax). Rows are append-only,
  like the documents themselves, and are written only in the transaction
  that records the consolidated document.

  PostgreSQL enforces what the facade checks:

  - a source is covered by one consolidated document at a time: a second
    is refused unless every earlier one was refused, found invalid, or
    cancelled at the authority, which releases its sources;
  - a source that was ever submitted on its own is never covered, and a
    covered source is never submitted on its own while its consolidated
    document holds it; a consolidated document that released its sources
    is never submitted again;
  - a consolidated document is never itself a source, and its sources
    belong to its company and environment;
  - at commit, a consolidated document's totals equal its sources' totals.
  """

  use Ecto.Migration

  @functions ~w(
    finance_einvoice_refuse_covered_source
    finance_einvoice_refuse_consolidated_submission
    finance_einvoice_check_consolidation
  )

  def up, do: Enum.each(statements(), &execute/1)

  def down do
    execute(
      "DROP TRIGGER finance_einvoice_submissions_consolidated ON finance_einvoice_submissions"
    )

    execute("DROP TRIGGER finance_einvoice_documents_match_sources ON finance_einvoice_documents")

    execute("DROP TABLE finance_einvoice_consolidated_sources")
    for function <- @functions, do: execute("DROP FUNCTION #{function}()")
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
      CREATE #{table} finance_einvoice_consolidated_sources (
        id bigserial PRIMARY KEY,
        tenant_id bigint NOT NULL,
        company_id bigint NOT NULL,
        document_id bigint NOT NULL,
        source_document_id bigint NOT NULL,
        line_number integer NOT NULL,
        CONSTRAINT finance_einvoice_consolidated_sources_document_fkey
          FOREIGN KEY (document_id, company_id)
          REFERENCES finance_einvoice_documents (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_einvoice_consolidated_sources_source_fkey
          FOREIGN KEY (source_document_id, company_id)
          REFERENCES finance_einvoice_documents (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_einvoice_consolidated_sources_line_fkey
          FOREIGN KEY (document_id, line_number)
          REFERENCES finance_einvoice_document_lines (document_id, line_number)
          ON DELETE RESTRICT,
        CONSTRAINT finance_einvoice_consolidated_sources_not_own_source
          CHECK (source_document_id <> document_id)
      )#{persistence}
      """,
      """
      CREATE UNIQUE INDEX finance_einvoice_consolidated_sources_unique
        ON finance_einvoice_consolidated_sources (document_id, line_number, source_document_id)
      """,
      """
      CREATE INDEX finance_einvoice_consolidated_sources_source_index
        ON finance_einvoice_consolidated_sources (company_id, source_document_id)
      """
    ]
  end

  # A consolidated document releases its sources once the authority refused
  # it, found it invalid, or cancelled it; each is final for it, since its
  # bytes and issue date never change (it is never submitted again).
  @releasing "('refused', 'invalid', 'cancelled')"

  @doc """
  The trigger functions, created under `prefix` (`""`, or `"pg_temp."` for
  module tests).
  """
  def functions(prefix) do
    [
      """
      CREATE FUNCTION #{prefix}finance_einvoice_refuse_covered_source() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF (SELECT environment FROM finance_einvoice_documents WHERE id = NEW.source_document_id)
           IS DISTINCT FROM
           (SELECT environment FROM finance_einvoice_documents WHERE id = NEW.document_id) THEN
          RAISE EXCEPTION 'document % is in another environment than consolidated document %',
            NEW.source_document_id, NEW.document_id
            USING ERRCODE = 'check_violation';
        END IF;

        IF EXISTS (
          SELECT 1 FROM finance_einvoice_submissions WHERE document_id = NEW.source_document_id
        ) THEN
          RAISE EXCEPTION 'document % was submitted on its own and cannot be consolidated',
            NEW.source_document_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF EXISTS (
          SELECT 1 FROM finance_einvoice_consolidated_sources
          WHERE document_id = NEW.source_document_id OR source_document_id = NEW.document_id
        ) THEN
          RAISE EXCEPTION 'a consolidated document is never a source'
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF EXISTS (
          SELECT 1 FROM finance_einvoice_consolidated_sources c
          WHERE c.source_document_id = NEW.source_document_id
            AND c.document_id <> NEW.document_id
            AND NOT EXISTS (
              SELECT 1 FROM finance_einvoice_status_events e
              WHERE e.document_id = c.document_id AND e.event IN #{@releasing}
            )
        ) THEN
          RAISE EXCEPTION 'document % is already consolidated', NEW.source_document_id
            USING ERRCODE = 'unique_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_einvoice_refuse_consolidated_submission() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM finance_einvoice_consolidated_sources c
          WHERE c.source_document_id = NEW.document_id
            AND NOT EXISTS (
              SELECT 1 FROM finance_einvoice_status_events e
              WHERE e.document_id = c.document_id AND e.event IN #{@releasing}
            )
        ) THEN
          RAISE EXCEPTION 'document % is consolidated and cannot be submitted on its own',
            NEW.document_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF EXISTS (
          SELECT 1 FROM finance_einvoice_consolidated_sources
          WHERE document_id = NEW.document_id
        ) AND EXISTS (
          SELECT 1 FROM finance_einvoice_status_events
          WHERE document_id = NEW.document_id AND event IN #{@releasing}
        ) THEN
          RAISE EXCEPTION 'consolidated document % released its sources and is not submitted again',
            NEW.document_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_einvoice_check_consolidation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        net numeric;
        tax numeric;
      BEGIN
        SELECT sum(s.line_extension_amount), sum(s.tax_amount) INTO net, tax
        FROM finance_einvoice_documents s
        WHERE s.id IN (SELECT source_document_id FROM finance_einvoice_consolidated_sources
                       WHERE document_id = NEW.id);

        IF net IS NOT NULL AND (net <> NEW.line_extension_amount OR tax <> NEW.tax_amount) THEN
          RAISE EXCEPTION 'consolidated document % totals differ from its sources', NEW.id
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NULL;
      END
      $$
      """
    ]
  end

  defp triggers(prefix) do
    table = "finance_einvoice_consolidated_sources"

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
      CREATE TRIGGER #{table}_covered BEFORE INSERT ON #{table}
        FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_einvoice_refuse_covered_source()
      """,
      """
      CREATE CONSTRAINT TRIGGER finance_einvoice_documents_match_sources
        AFTER INSERT ON finance_einvoice_documents
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_einvoice_check_consolidation()
      """,
      """
      CREATE TRIGGER finance_einvoice_submissions_consolidated
        BEFORE INSERT ON finance_einvoice_submissions
        FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_einvoice_refuse_consolidated_submission()
      """
    ]
  end
end
