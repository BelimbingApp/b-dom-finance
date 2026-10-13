defmodule Bilimbi.Finance.Reconciliation.Migrations.ClaimEntries do
  @moduledoc """
  Claims the ledger entries this module posted before the ledger recorded
  an entry's owner (the ledger's migration `20261015150000`).

  Bilimbi-only. The charge or interest entry a statement line posted is not
  named by any column; the match made with it is the only trace, noted
  `Posted from statement line as <kind>`. A match whose note starts that way
  and that names exactly one statement line and exactly one entry is such a
  posting, and this calls the ledger's own `finance_ledger_claim_legacy_entry`
  for its entry, which marks it as owned by `finance/reconciliation` and
  `statement_line:<line id>`, as the facade's own postings do. A statement
  line with more than one such match (posted again after an unmatch, before
  one entry per line was kept) is left unclaimed, because the ledger keeps one
  original entry per owned record; those entries stay legacy and are reversed
  directly. The ledger's rule, not this module, decides what a claim may
  change: only a legacy entry's owner, from none to one, once. Nothing here
  reads or writes the ledger's tables directly.

  It is data, not schema: `statements/1` is empty with `temporary: true`,
  so the module's test fixtures, which build temporary tables, run nothing
  for it; `test/schema_contract_test.exs` proves the claim on a fresh
  database with the ledger's migrations. `down/0` is a no-op: an owner,
  once recorded, is kept.
  """

  use Ecto.Migration

  def up, do: Enum.each(statements(), &execute/1)

  def down, do: :ok

  @doc "The claim statements, or none when building temporary test tables."
  def statements(options \\ []) do
    if Keyword.get(options, :temporary, false), do: [], else: claims()
  end

  defp claims do
    [
      """
      SELECT finance_ledger_claim_legacy_entry(
        e.entry_id, m.company_id, 'finance/reconciliation',
        'statement_line:' || l.statement_line_id)
      FROM finance_reconciliation_matches m
      JOIN finance_reconciliation_match_lines l ON l.match_id = m.id
      JOIN finance_reconciliation_match_entries e ON e.match_id = m.id
      WHERE starts_with(m.note, 'Posted from statement line as ')
        AND (SELECT count(*) FROM finance_reconciliation_match_lines x
             WHERE x.match_id = m.id) = 1
        AND (SELECT count(*) FROM finance_reconciliation_match_entries x
             WHERE x.match_id = m.id) = 1
        AND NOT EXISTS (
          SELECT 1
          FROM finance_reconciliation_match_lines other_line
          JOIN finance_reconciliation_matches other ON other.id = other_line.match_id
          WHERE other_line.statement_line_id = l.statement_line_id
            AND other.id <> m.id
            AND starts_with(other.note, 'Posted from statement line as '))
      ORDER BY m.id
      """
    ]
  end
end
