defmodule Bilimbi.Finance.Payroll.Migrations.ClaimEntries do
  @moduledoc """
  Claims the ledger entries this module posted before the ledger recorded
  an entry's owner (the ledger's migration `20261015150000`).

  Bilimbi-only. A source's `posted` event names the entry it posted and its
  `reversed` event the entry that reversed it; this calls the ledger's own
  `finance_ledger_claim_legacy_entry` for each, which marks the entry as
  owned by `finance/payroll` and the source (`payroll_run:<id>` or
  `claim:<id>`, as the facade's own postings do). The ledger's rule, not
  this module, decides what a claim may change: only a legacy entry's
  owner, from none to one, once. Nothing here reads or writes the ledger's
  tables directly.

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
        e.entry_id, e.company_id, 'finance/payroll', e.source_kind || ':' || e.source_id)
      FROM finance_payroll_posting_events e
      WHERE e.event IN ('posted', 'reversed') AND e.entry_id IS NOT NULL
      ORDER BY e.event DESC, e.id
      """
    ]
  end
end
