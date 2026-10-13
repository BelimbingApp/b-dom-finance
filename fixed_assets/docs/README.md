# Fixed assets

`finance/fixed_assets` owns a company's permanent asset register, category
revisions, monthly depreciation runs with their items and exceptions, and
disposal, void and reversal events. It depends on Ledger for the books and Payables for acquisition from
posted supplier bills; Supply Chain remains optional behind Payables' own
three-way-match seam. It reads and posts through both public facades.

## Workflow

1. Open the company's ledger book and fiscal year. Configure category defaults
   on `/finance/fixed-assets/categories`: cost and accumulated depreciation
   accounts of type asset, depreciation expense and disposal loss accounts of
   type expense, and a disposal gain account of type income. All are active
   accounts of that company; cost and accumulated depreciation accounts differ.
   Method and useful life are company choices, never a fixed chart or currency.
2. Register an acquisition on `/finance/fixed-assets/register` with a category
   revision, description, in-service date, and optional residual value. Name
   either a posted supplier bill and line or a manually posted acquisition
   entry and debit line. The entry date and cost are derived from the source;
   the debit must be on the category's cost account, and a line is registered
   once. Reversed entries, draft/held bills, credits and foreign-company records
   are refused. A bill's net line is the cost; additional acquisition costs
   must be included in the acquisition entry before registering its debit.
3. Post monthly depreciation on `/finance/fixed-assets/runs`, using the first
   day of a fiscal calendar month. The month must be open. One balanced entry
   debits expense and credits accumulated depreciation across all eligible
   assets; immutable items preserve each asset's charge. A month with no charge
   records an empty run with no ledger entry. The company-period unique index
   and company lock make retries return the original run, including after its
   reversal. New runs cannot precede later asset activity.
4. Read an asset's frozen assumptions and projected schedule on its detail
   page. Dispose it by recording proceeds and a settlement asset account for
   a sale, or zero proceeds for a write-off. Post depreciation through the last
   completed month first. The disposal removes cost and accumulated depreciation,
   books proceeds, and posts the difference against gain or loss.
5. Correct charges and disposals with reversal actions on the same pages.
   A run's later nonempty runs and standing disposals must be reversed first.
   The reversal date cannot precede the original and must be open in Ledger.
   A reversed month's run stays recorded; the next new monthly run catches up
   outstanding scheduled depreciation. A disposal reversal restores the asset,
   and a later run catches up its remaining scheduled charges.

6. When an acquisition entry is reversed in the ledger (for example by voiding
   the supplier bill), a depreciation run never stops for it: the asset is
   skipped, recorded as an exception on that run (shown in the run result and
   the runs page's "Skipped assets" column), and every other asset is charged
   as usual. Retire it with "Void acquisition" on its detail page, under its
   own `finance-asset-void` capability. The append-only `acquisition_voided`
   event records the actor, reason and database time. Only an asset whose
   acquisition entry is reversed can be voided, and a standing disposal must be
   reversed first. Its unreversed depreciation is mirrored in one entry that
   touches only that asset's amounts; a month's other assets keep their posted
   charges. The asset then drops out of runs and reconciliation, the register
   shows it as voided with zero carrying value, and disposal is refused. A void
   cannot be undone; an asset with nothing to reverse records an event without
   a ledger entry. Reversing a run later leaves a voided asset's charge alone.

Every action rechecks its own `finance.fixed-assets` capability. Its verb names
start with `finance-asset-` and cannot duplicate another Domain's `post` verb.
Ledger view/post and Payables view permissions are additionally checked by their
facades. Writes take the writable-company lock; an archived company is frozen.
Actors and impersonators come from the scope, never form attributes.

## Depreciation policy

The book schedule charges a full month in the calendar month the asset enters
service. There is no daily proration. Month-end is the charge's effective date,
so a midmonth disposal includes charges through the preceding completed month.
The company must assess whether this convention is suitable for its accounting
policy and materiality; the module does not claim full IAS 16 compliance.

Straight line divides cost less residual value by useful life in months.
Reducing balance charges opening carrying value times the explicitly selected
annual percentage divided by twelve. Both round half up at the book's minor
units, cap charges at the remaining depreciable amount, and clear that amount
in the final useful-life month. A run catches up the cumulative schedule through
its month less already posted, unreversed charges. Useful life is 1–1200 months;
residual is nonnegative and no greater than cost. The acquisition snapshots the
category revision; revising category defaults never changes existing assets.

## Reports and reproduction

`register_report(scope, company_id, as_of, options)` returns the register,
projected schedules, cost, accumulated depreciation and carrying values, and
ledger reconciliation. `depreciation_schedule_report/4` exposes the same
reproducible report for schedule consumers. Monetary totals are read with
`Ledger.account_totals/3`, never summed from ledger lines in memory.

The result records four boundaries. Pass all of them back together:

```elixir
[:through_entry_number, :through_asset_number,
 :through_event_number, :through_category_revision_id]
```

These preserve the ledger, acquisitions, effective events and configured
account set even after backdated records arrive. The register page lets the
reader choose a report-through date and retain these boundaries in its URL.
A report includes disposals and reversals effective through that date. Disposed
assets remain visible, with zero carrying value. Projected schedules show the
original assumptions; they do not assert every charge has already been posted.

Reconciliation compares net ledger balances with registered cost and accumulated
depreciation, and reconciles depreciation expense and disposal gains/losses on
every account configured in category revisions up to the report boundary. Flow
accounts exclude year-end closing entries and their reversals at the same ledger
watermark, so closing the books does not erase the schedule's expense figures.
It displays differences, including unregistered acquisitions and
external postings on those accounts. Shared category accounts are aggregated;
using an account for unrelated balances therefore produces an explicit difference.
Acquisition reversals made directly through Ledger also produce a difference
until the asset is voided; meanwhile runs skip the asset and disposal is refused.
A voided asset contributes nothing to the registered balances.

## Standards addressed and limits

The register supports systematic allocation of depreciable cost and disposal
gain/loss accounting described by
[IAS 16](https://www.ifrs.org/issued-standards/list-of-standards/ias-16-property-plant-and-equipment/).
It preserves immutable actor/impersonator histories, database timestamps, gapless
company asset and event numbers, and bounded reports for audit reproduction.
PostgreSQL refuses updates, deletes and truncation of every owned table, so
records remain permanently retained and exceed the requested seven-year record
retention. Operational backups and recovery remain the company's responsibility.

Follow-ups: tax capital allowances; prospective revisions to individual asset
estimates following annual method/life/residual reviews; component depreciation;
assets held for sale. Revaluation, impairment and leases are outside this module's
current scope. Category default revisions do not implement prospective changes
for an existing asset. Acquisition sources must already have correctly determined
cost; this module does not allocate ancillary costs or reverse supplier credit
notes automatically.

## Verification

Mount a real copy at `apps/domains/finance` in an isolated Bilimbi checkout.
Run `mix test` in its `fixed_assets` folder and the module's `web_test` through
the Web host. Run `mix precommit` from the Bilimbi root. Tests build temporary
copies from the migration's `statements(temporary: true)`; the fresh-database
contract suite runs the actual migration and proves commit-time totals,
rollback-safe numbering, the standing disposal rules and permanent retention.
The descriptor deliberately excludes this Bilimbi-only schema from adoption.
