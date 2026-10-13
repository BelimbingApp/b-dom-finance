defmodule Bilimbi.Finance.FixedAssets.Migrations.ClaimEntries do
  @moduledoc """
  Claims the ledger entries this module posted before the ledger recorded
  an entry's owner (the ledger's migration `20261015150000`).

  Bilimbi-only. A depreciation run names the entry it posted, and a
  disposal or a void names the entry it posted (a void with nothing to
  mirror posts none); this calls the ledger's own
  `finance_ledger_claim_legacy_entry` for each, which marks the entry as
  owned by `finance/fixed_assets` and `run:<id>` or `event:<id>`, as the
  facade's own postings do. A run's reversal and a disposal's reversal are
  claimed with their originals by the ledger's rule. The mirror a partial
  run reversal posted stays legacy: nothing in this module's records tells
  it from the run's own reversal, and the ledger keeps a reversal's owner
  equal to its original's. An asset's acquisition entry is never claimed:
  it belongs to whoever posted it. The ledger's rule, not this module,
  decides what a claim may change: only a legacy entry's owner, from none to
  one, once. Nothing here reads or writes the ledger's tables directly.

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
        r.entry_id, r.company_id, 'finance/fixed_assets', 'run:' || r.id)
      FROM finance_fixed_assets_runs r
      WHERE r.entry_id IS NOT NULL
      ORDER BY r.id
      """,
      """
      SELECT finance_ledger_claim_legacy_entry(
        e.entry_id, e.company_id, 'finance/fixed_assets', 'event:' || e.id)
      FROM finance_fixed_assets_events e
      WHERE e.action IN ('disposed', 'acquisition_voided') AND e.entry_id IS NOT NULL
      ORDER BY e.id
      """
    ]
  end
end
