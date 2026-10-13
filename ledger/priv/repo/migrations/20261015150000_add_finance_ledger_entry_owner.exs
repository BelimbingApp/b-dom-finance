defmodule Bilimbi.Finance.Ledger.Migrations.AddEntryOwner do
  @moduledoc """
  The owner of a journal entry: the module and the record of its own that
  the entry recognises, so a correction goes through that module.

  Bilimbi-only. An entry posted for a module's record carries
  `owner_module` (the module's descriptor ID, such as `finance/receivables`)
  and `owner_record` (`<kind>:<id>` in that module's own terms, such as
  `payment:17`); a manual journal entry carries neither. PostgreSQL keeps
  the two together:

  - an owned record has one original entry per company: a second posting
    for the same record is refused, so a record is never recognised twice;
  - a reversal carries exactly its original's owner, so an owned entry is
    never reversed by a writer that does not act for its owner, and a
    manual entry's reversal is manual;
  - entries posted before this migration are marked `legacy`, with no
    owner; an owning module claims such an entry once, through
    `finance_ledger_claim_legacy_entry`, which is the only change ever
    allowed to a posted entry's row, and only from no owner to one.

  The migration is self-contained: a database that ran the earlier ones
  loads only this file, so the entries' UPDATE trigger it replaces is
  spelled out here and `down/0` restores the original. `statements/1`
  gives the same SQL to the module's test fixtures.
  """

  use Ecto.Migration

  @doc "Where a module's descriptor ID and a record identity must match."
  def owner_module_pattern, do: "^[a-z][a-z0-9_]*/[a-z][a-z0-9_]*$"
  def owner_record_pattern, do: "^[a-z][a-z0-9_]*:[1-9][0-9]*$"

  def up, do: Enum.each(statements(), &execute/1)

  def down do
    execute("DROP TRIGGER finance_ledger_entries_owner_claim ON finance_ledger_entries")
    execute("DROP TRIGGER finance_ledger_entries_append_only ON finance_ledger_entries")
    execute("DROP TRIGGER finance_ledger_entries_reversal_owner ON finance_ledger_entries")
    execute("DROP FUNCTION finance_ledger_claim_legacy_entry(bigint, bigint, text, text)")
    execute("DROP FUNCTION finance_ledger_claim_entry_owner()")
    execute("DROP FUNCTION finance_ledger_check_reversal_owner()")

    execute("""
    CREATE TRIGGER finance_ledger_entries_append_only
      BEFORE UPDATE OR DELETE ON finance_ledger_entries
      FOR EACH ROW EXECUTE FUNCTION finance_ledger_refuse_change()
    """)

    execute("DROP INDEX finance_ledger_entries_owner_record_unique")

    execute("""
    ALTER TABLE finance_ledger_entries
      DROP CONSTRAINT finance_ledger_entries_owner_pair,
      DROP CONSTRAINT finance_ledger_entries_owner_module,
      DROP CONSTRAINT finance_ledger_entries_owner_record,
      DROP COLUMN owner_module,
      DROP COLUMN owner_record,
      DROP COLUMN legacy
    """)
  end

  @doc """
  The schema's SQL in order. With `temporary: true` the functions live in
  `pg_temp`, for module tests, whose tables are temporary copies.
  """
  def statements(options \\ []) do
    prefix = if Keyword.get(options, :temporary, false), do: "pg_temp.", else: ""
    columns() ++ functions(prefix) ++ triggers(prefix)
  end

  # Every entry already posted predates ownership: `legacy` defaults to true
  # for them and to false from here on.
  defp columns do
    [
      """
      ALTER TABLE finance_ledger_entries
        ADD COLUMN owner_module varchar(100),
        ADD COLUMN owner_record varchar(100),
        ADD COLUMN legacy boolean NOT NULL DEFAULT true
      """,
      "ALTER TABLE finance_ledger_entries ALTER COLUMN legacy SET DEFAULT false",
      """
      ALTER TABLE finance_ledger_entries ADD CONSTRAINT finance_ledger_entries_owner_pair
        CHECK ((owner_module IS NULL) = (owner_record IS NULL))
      """,
      """
      ALTER TABLE finance_ledger_entries ADD CONSTRAINT finance_ledger_entries_owner_module
        CHECK (owner_module IS NULL OR owner_module ~ '#{owner_module_pattern()}')
      """,
      """
      ALTER TABLE finance_ledger_entries ADD CONSTRAINT finance_ledger_entries_owner_record
        CHECK (owner_record IS NULL OR owner_record ~ '#{owner_record_pattern()}')
      """,
      """
      CREATE UNIQUE INDEX finance_ledger_entries_owner_record_unique
        ON finance_ledger_entries (company_id, owner_module, owner_record)
        WHERE owner_module IS NOT NULL AND reverses_entry_id IS NULL
      """
    ]
  end

  @doc """
  The ownership rules' functions, created under `prefix` (`""`, or
  `"pg_temp."` for module tests).
  """
  def functions(prefix) do
    [
      # A reversal names its original's owner, or none when the original has
      # none: the owner's correction path posts it, nothing else does.
      """
      CREATE FUNCTION #{prefix}finance_ledger_check_reversal_owner() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        original finance_ledger_entries%ROWTYPE;
      BEGIN
        IF NEW.reverses_entry_id IS NULL THEN
          RETURN NEW;
        END IF;

        SELECT * INTO original FROM finance_ledger_entries
        WHERE id = NEW.reverses_entry_id AND company_id = NEW.company_id;

        IF NOT FOUND THEN
          RETURN NEW;
        END IF;

        IF original.owner_module IS NOT NULL
          AND (NEW.owner_module, NEW.owner_record)
              IS DISTINCT FROM (original.owner_module, original.owner_record) THEN
          RAISE EXCEPTION 'journal entry % is owned by % (%): it is reversed through that module',
            original.id, original.owner_module, original.owner_record
            USING ERRCODE = 'restrict_violation';
        ELSIF original.owner_module IS NULL AND NEW.owner_module IS NOT NULL THEN
          RAISE EXCEPTION 'journal entry % has no owner: its reversal has none either',
            original.id
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      # The one change a posted entry's row ever takes: a legacy entry gains
      # its owner, once, with every other column as it was. A reversal's
      # owner must agree with its original's, and an original's with any
      # reversal already claimed.
      """
      CREATE FUNCTION #{prefix}finance_ledger_claim_entry_owner() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT (OLD.legacy AND OLD.owner_module IS NULL AND NEW.owner_module IS NOT NULL
          AND (NEW.id, NEW.tenant_id, NEW.company_id, NEW.entry_number, NEW.entry_date,
               NEW.description, NEW.reference, NEW.currency_code, NEW.reverses_entry_id,
               NEW.posted_by_user_id, NEW.posted_by_impersonator_id, NEW.posted_at,
               NEW.legacy)
              IS NOT DISTINCT FROM
              (OLD.id, OLD.tenant_id, OLD.company_id, OLD.entry_number, OLD.entry_date,
               OLD.description, OLD.reference, OLD.currency_code, OLD.reverses_entry_id,
               OLD.posted_by_user_id, OLD.posted_by_impersonator_id, OLD.posted_at,
               OLD.legacy)) THEN
          RAISE EXCEPTION 'the finance ledger keeps % rows: % is refused; post a reversing entry',
            TG_TABLE_NAME, TG_OP
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF EXISTS (
          SELECT 1 FROM finance_ledger_entries o
          WHERE o.id = NEW.reverses_entry_id AND o.owner_module IS NOT NULL
            AND (o.owner_module, o.owner_record)
                IS DISTINCT FROM (NEW.owner_module, NEW.owner_record)
        ) OR EXISTS (
          SELECT 1 FROM finance_ledger_entries r
          WHERE r.reverses_entry_id = NEW.id AND r.owner_module IS NOT NULL
            AND (r.owner_module, r.owner_record)
                IS DISTINCT FROM (NEW.owner_module, NEW.owner_record)
        ) THEN
          RAISE EXCEPTION 'journal entry % and its reversal have one owner', NEW.id
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      # What an owning module's own migration calls for each entry it posted
      # before ownership was recorded. Claiming an entry already claimed by
      # the same owner is nothing; by another, or a non-legacy entry, fails.
      """
      CREATE FUNCTION #{prefix}finance_ledger_claim_legacy_entry(
        entry bigint, company bigint, module text, record text
      ) RETURNS void
      LANGUAGE plpgsql AS $$
      DECLARE
        current finance_ledger_entries%ROWTYPE;
      BEGIN
        SELECT * INTO current FROM finance_ledger_entries
        WHERE id = entry AND company_id = company
        FOR NO KEY UPDATE;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'journal entry % of company % does not exist', entry, company
            USING ERRCODE = 'no_data_found';
        ELSIF current.owner_module = module AND current.owner_record = record THEN
          RETURN;
        ELSIF current.owner_module IS NOT NULL OR NOT current.legacy THEN
          RAISE EXCEPTION 'journal entry % is not an unclaimed legacy entry', entry
            USING ERRCODE = 'restrict_violation';
        END IF;

        UPDATE finance_ledger_entries SET owner_module = module, owner_record = record
        WHERE id = entry AND company_id = company;
      END
      $$
      """
    ]
  end

  defp triggers(prefix) do
    [
      "DROP TRIGGER finance_ledger_entries_append_only ON finance_ledger_entries",
      """
      CREATE TRIGGER finance_ledger_entries_append_only
        BEFORE DELETE ON finance_ledger_entries
        FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_ledger_refuse_change()
      """,
      """
      CREATE TRIGGER finance_ledger_entries_owner_claim
        BEFORE UPDATE ON finance_ledger_entries
        FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_ledger_claim_entry_owner()
      """,
      """
      CREATE TRIGGER finance_ledger_entries_reversal_owner
        BEFORE INSERT ON finance_ledger_entries
        FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_ledger_check_reversal_owner()
      """
    ]
  end
end
