defmodule Bilimbi.Finance.Ledger.Migrations.AddLateRecordingReviews do
  @moduledoc """
  Late recording: an independent reviewer's written explanation of a journal
  entry that was recorded long after its transaction date.

  Bilimbi-only. An entry's transaction date is its `entry_date`; its
  recording time is `posted_at`, which the database stamps. The late-recording
  report lists the entries recorded 45 or more days after their transaction
  date, and the ones more than 60 days after it are the exceptions. The
  report's days are whole UTC days, so they need no company time zone.

  A review is appended once per entry, by someone who neither posted it nor
  impersonated its poster, with a reason. The database refuses a review of an
  entry recorded less than 45 days late, a second review of one entry, and a
  reviewer who overlaps the poster; the table is append-only.

  `statements/1` is the one source of the schema change: with
  `temporary: true` the table is temporary and the functions live in
  `pg_temp`, for the module tests' fixtures.
  """

  use Ecto.Migration

  @approaching_days 45

  def up, do: Enum.each(statements(), &execute/1)

  def down do
    execute("DROP TABLE finance_ledger_late_recording_reviews")
    execute("DROP FUNCTION finance_ledger_record_late_recording_review()")
  end

  @doc "The schema change's SQL in order, as `statements/1` in the module doc says."
  def statements(options \\ []) do
    {table, prefix} =
      if Keyword.get(options, :temporary, false),
        do: {"TEMPORARY TABLE", "pg_temp."},
        else: {"TABLE", ""}

    [
      table_statement(table),
      "CREATE UNIQUE INDEX finance_ledger_late_recording_reviews_entry_unique " <>
        "ON finance_ledger_late_recording_reviews (entry_id)",
      "CREATE INDEX finance_ledger_late_recording_reviews_tenant_company_index " <>
        "ON finance_ledger_late_recording_reviews (tenant_id, company_id)"
    ] ++ functions(prefix) ++ triggers(prefix)
  end

  defp table_statement(table) do
    """
    CREATE #{table} finance_ledger_late_recording_reviews (
      id bigserial PRIMARY KEY,
      tenant_id bigint NOT NULL,
      company_id bigint NOT NULL,
      entry_id bigint NOT NULL,
      reason varchar(500) NOT NULL,
      reviewed_by_user_id bigint NOT NULL,
      reviewed_by_impersonator_id bigint,
      reviewed_at timestamp(6) NOT NULL,
      CONSTRAINT finance_ledger_late_recording_reviews_entry_fkey
        FOREIGN KEY (entry_id, company_id)
        REFERENCES finance_ledger_entries (id, company_id) ON DELETE RESTRICT,
      CONSTRAINT finance_ledger_late_recording_reviews_reason
        CHECK (btrim(reason) <> '')
    )
    """
  end

  defp functions(prefix) do
    [
      """
      CREATE FUNCTION #{prefix}finance_ledger_record_late_recording_review() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        entry finance_ledger_entries%ROWTYPE;
      BEGIN
        SELECT * INTO entry FROM finance_ledger_entries WHERE id = NEW.entry_id;

        IF CAST(entry.posted_at AS date) - entry.entry_date < #{@approaching_days} THEN
          RAISE EXCEPTION 'journal entry % was not recorded late', NEW.entry_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        -- Overlap in either direction: the reviewer is, or impersonated, the poster.
        IF NEW.reviewed_by_user_id IN (entry.posted_by_user_id, entry.posted_by_impersonator_id)
          OR NEW.reviewed_by_impersonator_id IN
            (entry.posted_by_user_id, entry.posted_by_impersonator_id) THEN
          RAISE EXCEPTION 'journal entry % was posted by the reviewer', NEW.entry_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        NEW.reviewed_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """
    ]
  end

  defp triggers(prefix) do
    refuse = "EXECUTE FUNCTION #{prefix}finance_ledger_refuse_record_change()"

    [
      "CREATE TRIGGER finance_ledger_late_recording_reviews_append_only " <>
        "BEFORE UPDATE OR DELETE ON finance_ledger_late_recording_reviews " <>
        "FOR EACH ROW #{refuse}",
      "CREATE TRIGGER finance_ledger_late_recording_reviews_no_truncate " <>
        "BEFORE TRUNCATE ON finance_ledger_late_recording_reviews " <>
        "FOR EACH STATEMENT #{refuse}",
      "CREATE TRIGGER finance_ledger_late_recording_reviews_record " <>
        "BEFORE INSERT ON finance_ledger_late_recording_reviews " <>
        "FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_ledger_record_late_recording_review()"
    ]
  end
end
