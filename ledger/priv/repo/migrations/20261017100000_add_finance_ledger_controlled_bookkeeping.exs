defmodule Bilimbi.Finance.Ledger.Migrations.AddControlledBookkeeping do
  @moduledoc """
  Controlled bookkeeping: each company's setting that an entry posts only
  into a fiscal period the company has configured and left open.

  Bilimbi-only. The setting is never stored as a column: it is the latest of
  the company's append-only changes, each with the actor, any impersonator,
  a reason (required to turn it off), and the database's time. A company
  with no change is not controlled, so companies that existed before this
  migration keep posting as they did until someone turns it on. The facade
  records a change turning it on when it opens a new company's book.

  While a company is controlled, the entries' BEFORE INSERT rule refuses an
  entry dated where no fiscal period exists, after the last fiscal year as
  well as before the first, so posting never depends on someone remembering
  to open the next year. Old entries are not refused for being old: an entry
  dated into an open period, including one in a year opened for catch-up
  accounting, posts as it always did. A closed or locked period is refused
  as before.

  The migration replaces the entries' closed-period function with
  `CREATE OR REPLACE`, spelled out in full; `down/0` restores the closing
  migration's original. `statements/1` is the one source of the schema
  change: with `temporary: true` the table is temporary and the functions
  live in `pg_temp`, for the module tests' fixtures.
  """

  use Ecto.Migration

  def up, do: Enum.each(statements(), &execute/1)

  def down do
    execute("DROP TABLE finance_ledger_bookkeeping_changes")
    execute("DROP FUNCTION finance_ledger_record_bookkeeping_change()")
    execute("DROP FUNCTION finance_ledger_company_controlled(bigint)")
    execute(refuse_closed_period("", ""))
  end

  @doc """
  The schema change's SQL in order. With `temporary: true` the table is
  temporary and the functions live in `pg_temp`, over the temporary copies
  of the ledger's earlier tables.
  """
  def statements(options \\ []) do
    {table, prefix} =
      if Keyword.get(options, :temporary, false),
        do: {"TEMPORARY TABLE", "pg_temp."},
        else: {"TABLE", ""}

    [
      table_statement(table),
      "CREATE UNIQUE INDEX finance_ledger_bookkeeping_changes_company_number_unique " <>
        "ON finance_ledger_bookkeeping_changes (company_id, change_number)",
      "CREATE INDEX finance_ledger_bookkeeping_changes_tenant_company_index " <>
        "ON finance_ledger_bookkeeping_changes (tenant_id, company_id)"
    ] ++ functions(prefix) ++ triggers(prefix)
  end

  defp table_statement(table) do
    """
    CREATE #{table} finance_ledger_bookkeeping_changes (
      id bigserial PRIMARY KEY,
      tenant_id bigint NOT NULL,
      company_id bigint NOT NULL,
      change_number bigint NOT NULL,
      controlled boolean NOT NULL,
      reason varchar(500),
      changed_by_user_id bigint NOT NULL,
      changed_by_impersonator_id bigint,
      changed_at timestamp(6) NOT NULL,
      CONSTRAINT finance_ledger_bookkeeping_changes_change_number
        CHECK (change_number > 0),
      CONSTRAINT finance_ledger_bookkeeping_changes_reason
        CHECK (controlled OR (reason IS NOT NULL AND btrim(reason) <> ''))
    )
    """
  end

  defp functions(prefix) do
    [
      # The latest change decides; with none, a company is not controlled. A
      # change must change the setting.
      """
      CREATE FUNCTION #{prefix}finance_ledger_record_bookkeeping_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        current boolean;
      BEGIN
        SELECT controlled INTO current FROM finance_ledger_bookkeeping_changes
        WHERE company_id = NEW.company_id ORDER BY change_number DESC LIMIT 1;

        IF COALESCE(current, false) = NEW.controlled THEN
          RAISE EXCEPTION 'controlled bookkeeping of company % is already %', NEW.company_id,
            CASE WHEN NEW.controlled THEN 'on' ELSE 'off' END
            USING ERRCODE = 'restrict_violation';
        END IF;

        NEW.change_number := COALESCE(
          (SELECT max(change_number) FROM finance_ledger_bookkeeping_changes
           WHERE company_id = NEW.company_id), 0) + 1;
        NEW.changed_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_ledger_company_controlled(target bigint) RETURNS boolean
      LANGUAGE plpgsql STABLE AS $$
      DECLARE
        latest boolean;
      BEGIN
        SELECT controlled INTO latest FROM finance_ledger_bookkeeping_changes
        WHERE company_id = target ORDER BY change_number DESC LIMIT 1;

        RETURN COALESCE(latest, false);
      END
      $$
      """,
      refuse_closed_period(prefix, controlled_branch(prefix))
    ]
  end

  defp triggers(prefix) do
    refuse = "EXECUTE FUNCTION #{prefix}finance_ledger_refuse_record_change()"

    [
      "CREATE TRIGGER finance_ledger_bookkeeping_changes_append_only " <>
        "BEFORE UPDATE OR DELETE ON finance_ledger_bookkeeping_changes " <>
        "FOR EACH ROW #{refuse}",
      "CREATE TRIGGER finance_ledger_bookkeeping_changes_no_truncate " <>
        "BEFORE TRUNCATE ON finance_ledger_bookkeeping_changes " <>
        "FOR EACH STATEMENT #{refuse}",
      "CREATE TRIGGER finance_ledger_bookkeeping_changes_record " <>
        "BEFORE INSERT ON finance_ledger_bookkeeping_changes " <>
        "FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_ledger_record_bookkeeping_change()"
    ]
  end

  # The branch for a date that no period covers and that is not before the
  # first fiscal year: a controlled company refuses it, and an uncontrolled
  # one keeps the closing migration's rule. Empty when restoring the original.
  defp controlled_branch(prefix) do
    """
      ELSIF #{prefix}finance_ledger_company_controlled(NEW.company_id) THEN
        RAISE EXCEPTION 'journal entry dated % falls in no fiscal period', NEW.entry_date
          USING ERRCODE = 'restrict_violation';
    """
  end

  # The entries' closed-period rule, replaced whole.
  defp refuse_closed_period(prefix, branch) do
    """
    CREATE OR REPLACE FUNCTION #{prefix}finance_ledger_refuse_closed_period() RETURNS trigger
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
        status := #{prefix}finance_ledger_period_status(target);

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
    #{branch}      END IF;

      RETURN NEW;
    END
    $$
    """
  end
end
