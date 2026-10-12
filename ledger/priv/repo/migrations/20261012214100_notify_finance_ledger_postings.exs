defmodule Bilimbi.Finance.Ledger.Migrations.NotifyPostings do
  @moduledoc """
  Announces each posted entry on the `finance_ledger_postings` channel.

  Bilimbi-only. An AFTER INSERT trigger on `finance_ledger_entries` calls
  `pg_notify` with `tenant_id:company_id:entry_number`. PostgreSQL delivers a
  notification only when the inserting transaction commits, so a refused or
  rolled-back post announces nothing and a listener that reads on the notice
  sees the entry. The payload carries identifiers only, no figures.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION finance_ledger_notify_posting() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      PERFORM pg_notify(
        'finance_ledger_postings',
        NEW.tenant_id || ':' || NEW.company_id || ':' || NEW.entry_number
      );

      RETURN NULL;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER finance_ledger_entries_notify
      AFTER INSERT ON finance_ledger_entries
      FOR EACH ROW EXECUTE FUNCTION finance_ledger_notify_posting()
    """)
  end

  def down do
    execute("DROP TRIGGER finance_ledger_entries_notify ON finance_ledger_entries")
    execute("DROP FUNCTION finance_ledger_notify_posting()")
  end
end
