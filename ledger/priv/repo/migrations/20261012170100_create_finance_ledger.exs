defmodule Bilimbi.Finance.Ledger.Migrations.CreateLedger do
  @moduledoc """
  The general ledger: each company's book, its chart of accounts, and its
  journal entries with their lines.

  Bilimbi-only. Rows of one company reference each other through composite
  `(id, company_id)` foreign keys, so a line cannot name another company's
  account or entry. A book, an entry, and its lines are append-only: a
  trigger refuses UPDATE, DELETE, and TRUNCATE, so a posted entry is
  corrected by a reversing entry. The database numbers each company's
  entries without gaps and stamps their posting time. A line can only be
  inserted in the transaction that inserts its entry, so a later
  transaction cannot add lines to a posted entry. An account is never
  deleted and keeps its code and type; its name, parent, and active flag
  may change. A deferred constraint trigger refuses a commit in which an
  entry has no lines or its debits and credits differ.
  """

  use Ecto.Migration

  def up do
    create table(:finance_ledger_books, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :currency_code, :string, size: 3, null: false
      add :minor_units, :smallint, null: false
      timestamps(type: :naive_datetime, updated_at: false)
    end

    create unique_index(:finance_ledger_books, [:company_id],
             name: :finance_ledger_books_company_unique
           )

    create unique_index(:finance_ledger_books, [:company_id, :currency_code],
             name: :finance_ledger_books_company_currency_unique
           )

    create index(:finance_ledger_books, [:tenant_id, :company_id])

    create constraint(:finance_ledger_books, :finance_ledger_books_currency_code,
             check: "currency_code ~ '^[A-Z]{3}$'"
           )

    create constraint(:finance_ledger_books, :finance_ledger_books_minor_units,
             check: "minor_units BETWEEN 0 AND 4"
           )

    create table(:finance_ledger_accounts, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :code, :string, size: 50, null: false
      add :name, :string, size: 200, null: false
      add :account_type, :string, size: 16, null: false

      add :parent_id, :bigint
      add :active, :boolean, null: false, default: true
      timestamps(type: :naive_datetime)
    end

    create unique_index(:finance_ledger_accounts, [:id, :company_id],
             name: :finance_ledger_accounts_id_company_unique
           )

    # A self-reference needs the composite key above before it can exist.
    execute(
      self_reference(:finance_ledger_accounts, :parent_id, :finance_ledger_accounts_parent_fkey)
    )

    create unique_index(:finance_ledger_accounts, [:company_id, :code],
             name: :finance_ledger_accounts_company_code_unique
           )

    create index(:finance_ledger_accounts, [:tenant_id, :company_id])

    create constraint(:finance_ledger_accounts, :finance_ledger_accounts_account_type,
             check: "account_type IN ('asset', 'liability', 'equity', 'income', 'expense')"
           )

    create constraint(:finance_ledger_accounts, :finance_ledger_accounts_not_own_parent,
             check: "parent_id IS NULL OR parent_id <> id"
           )

    create table(:finance_ledger_entries, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false
      add :entry_number, :bigint, null: false
      add :entry_date, :date, null: false
      add :description, :string, size: 500, null: false
      add :reference, :string, size: 100

      add :currency_code,
          references(:finance_ledger_books,
            column: :currency_code,
            type: :string,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_ledger_entries_book_fkey
          ),
          size: 3,
          null: false

      add :reverses_entry_id, :bigint
      add :posted_by_user_id, :bigint, null: false
      add :posted_by_impersonator_id, :bigint
      add :posted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:finance_ledger_entries, [:id, :company_id],
             name: :finance_ledger_entries_id_company_unique
           )

    execute(
      self_reference(
        :finance_ledger_entries,
        :reverses_entry_id,
        :finance_ledger_entries_reverses_entry_fkey
      )
    )

    create unique_index(:finance_ledger_entries, [:reverses_entry_id],
             where: "reverses_entry_id IS NOT NULL",
             name: :finance_ledger_entries_reversed_once
           )

    create index(:finance_ledger_entries, [:tenant_id, :company_id, :entry_date])

    create unique_index(:finance_ledger_entries, [:company_id, :entry_number],
             name: :finance_ledger_entries_company_number_unique
           )

    create constraint(:finance_ledger_entries, :finance_ledger_entries_entry_number,
             check: "entry_number > 0"
           )

    create constraint(:finance_ledger_entries, :finance_ledger_entries_not_own_reversal,
             check: "reverses_entry_id IS NULL OR reverses_entry_id <> id"
           )

    create table(:finance_ledger_entry_lines, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tenant_id, :bigint, null: false
      add :company_id, :bigint, null: false

      add :entry_id,
          references(:finance_ledger_entries,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_ledger_entry_lines_entry_fkey
          ),
          null: false

      add :line_number, :integer, null: false

      add :account_id,
          references(:finance_ledger_accounts,
            type: :bigint,
            with: [company_id: :company_id],
            on_delete: :restrict,
            name: :finance_ledger_entry_lines_account_fkey
          ),
          null: false

      add :debit, :decimal, precision: 20, scale: 4, null: false
      add :credit, :decimal, precision: 20, scale: 4, null: false
      add :description, :string, size: 500
    end

    create unique_index(:finance_ledger_entry_lines, [:entry_id, :line_number],
             name: :finance_ledger_entry_lines_entry_line_unique
           )

    create index(:finance_ledger_entry_lines, [:company_id, :account_id])

    create constraint(:finance_ledger_entry_lines, :finance_ledger_entry_lines_line_number,
             check: "line_number > 0"
           )

    # Exactly one side of a line carries a positive amount.
    create constraint(:finance_ledger_entry_lines, :finance_ledger_entry_lines_one_side,
             check: "debit >= 0 AND credit >= 0 AND (debit = 0) <> (credit = 0)"
           )

    execute("""
    CREATE FUNCTION finance_ledger_refuse_change() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'the finance ledger keeps % rows: % is refused; post a reversing entry',
        TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'restrict_violation';
    END
    $$
    """)

    for table <- [:finance_ledger_books, :finance_ledger_entries, :finance_ledger_entry_lines] do
      execute("""
      CREATE TRIGGER #{table}_append_only
        BEFORE UPDATE OR DELETE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION finance_ledger_refuse_change()
      """)
    end

    execute("""
    CREATE TRIGGER finance_ledger_accounts_kept
      BEFORE DELETE ON finance_ledger_accounts
      FOR EACH ROW EXECUTE FUNCTION finance_ledger_refuse_change()
    """)

    for table <- [
          :finance_ledger_books,
          :finance_ledger_accounts,
          :finance_ledger_entries,
          :finance_ledger_entry_lines
        ] do
      execute("""
      CREATE TRIGGER #{table}_no_truncate
        BEFORE TRUNCATE ON #{table}
        FOR EACH STATEMENT EXECUTE FUNCTION finance_ledger_refuse_change()
      """)
    end

    execute("""
    CREATE FUNCTION finance_ledger_accounts_keep_identity() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.tenant_id <> OLD.tenant_id OR NEW.company_id <> OLD.company_id
        OR NEW.code <> OLD.code OR NEW.account_type <> OLD.account_type THEN
        RAISE EXCEPTION 'a ledger account keeps its company, code and type'
          USING ERRCODE = 'restrict_violation';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER finance_ledger_accounts_identity
      BEFORE UPDATE ON finance_ledger_accounts
      FOR EACH ROW EXECUTE FUNCTION finance_ledger_accounts_keep_identity()
    """)

    # The database numbers each company's entries 1, 2, 3, ... and stamps the
    # posting time, whatever the inserting writer sent: with no sequence and
    # no deletion, a number is never skipped or reused, and a concurrent
    # writer that takes the same number fails on the unique index.
    execute("""
    CREATE FUNCTION finance_ledger_number_entry() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      NEW.entry_number := COALESCE(
        (SELECT max(entry_number) FROM finance_ledger_entries
         WHERE company_id = NEW.company_id), 0) + 1;
      NEW.posted_at := now() AT TIME ZONE 'UTC';
      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER finance_ledger_entries_number
      BEFORE INSERT ON finance_ledger_entries
      FOR EACH ROW EXECUTE FUNCTION finance_ledger_number_entry()
    """)

    # An entry is "posted" once its inserting transaction is no longer in
    # progress. pg_xact_status is NULL for a transaction older than the
    # retained commit log, so IS DISTINCT FROM keeps old entries refused.
    execute("""
    CREATE FUNCTION finance_ledger_refuse_posted_line() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM finance_ledger_entries
        WHERE id = NEW.entry_id
          AND pg_xact_status(
                ((pg_current_xact_id()::text::bigint >> 32 << 32) | xmin::text::bigint)::text::xid8
              ) IS DISTINCT FROM 'in progress'
      ) THEN
        RAISE EXCEPTION 'journal entry % is already posted: a line cannot be added; post a reversing entry',
          NEW.entry_id
          USING ERRCODE = 'restrict_violation';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER finance_ledger_entry_lines_posted_entry
      BEFORE INSERT ON finance_ledger_entry_lines
      FOR EACH ROW EXECUTE FUNCTION finance_ledger_refuse_posted_line()
    """)

    execute("""
    CREATE FUNCTION finance_ledger_check_balance() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      checked_id bigint;
    BEGIN
      IF TG_TABLE_NAME = 'finance_ledger_entries' THEN
        checked_id := NEW.id;
      ELSE
        checked_id := NEW.entry_id;
      END IF;

      IF NOT EXISTS (SELECT 1 FROM finance_ledger_entry_lines WHERE entry_id = checked_id) THEN
        RAISE EXCEPTION 'journal entry % has no lines', checked_id
          USING ERRCODE = 'check_violation';
      END IF;

      IF (SELECT sum(debit) - sum(credit) FROM finance_ledger_entry_lines
          WHERE entry_id = checked_id) <> 0 THEN
        RAISE EXCEPTION 'journal entry % does not balance', checked_id
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NULL;
    END
    $$
    """)

    for table <- [:finance_ledger_entries, :finance_ledger_entry_lines] do
      execute("""
      CREATE CONSTRAINT TRIGGER #{table}_balanced
        AFTER INSERT ON #{table}
        DEFERRABLE INITIALLY DEFERRED
        FOR EACH ROW EXECUTE FUNCTION finance_ledger_check_balance()
      """)
    end
  end

  def down do
    drop table(:finance_ledger_entry_lines)
    drop table(:finance_ledger_entries)
    drop table(:finance_ledger_accounts)
    drop table(:finance_ledger_books)
    execute("DROP FUNCTION finance_ledger_check_balance()")
    execute("DROP FUNCTION finance_ledger_refuse_posted_line()")
    execute("DROP FUNCTION finance_ledger_number_entry()")
    execute("DROP FUNCTION finance_ledger_accounts_keep_identity()")
    execute("DROP FUNCTION finance_ledger_refuse_change()")
  end

  defp self_reference(table, column, name) do
    """
    ALTER TABLE #{table} ADD CONSTRAINT #{name}
      FOREIGN KEY (#{column}, company_id) REFERENCES #{table} (id, company_id)
      ON DELETE RESTRICT
    """
  end
end
