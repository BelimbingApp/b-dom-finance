# Reports

Module ID: `finance/reports`. A company's management reports, read live
from its general ledger: profit and loss for any date range, the balance
sheet and the cash position as of any date, headline figures against the
previous period, and the entries behind any account's figure; and the pages
an independent reviewer reads the ledger's approval exceptions and entries
recorded late on, with the company's bookkeeping controls. It stores
immutable issued snapshots; ledger figures come through `finance/ledger`'s
facade, and the only other writes its pages make (the separation setting,
controlled bookkeeping, a fiscal year, a review) are that facade's calls.

## Management reports, not statutory statements

Profit and loss, the balance sheet, and the cash position are management
reports for the company's own use. Every page that shows them says so, and
their exports, if any are added, must carry the same label: the Reports page
states it above the figures, each statement is labelled "Management report:",
and the overview's headings say "(management)". They are not statutory
financial statements. There is no cash flow statement, no statement of
changes in equity or other comprehensive income, no notes, and no
consolidation, and currency translation is not built in. A statement layout
that a standard requires (MFRS, IFRS, or another) is not produced here.

## Public API

Call `Bilimbi.Finance.Reports` with a validated `Bilimbi.Base.Tenancy.Scope`
and an explicit company ID. Results are plain maps.

| Function | Does |
| --- | --- |
| `profit_and_loss/4` | Income and expense for one to four `{from, to}` periods, by section, and `net_income` |
| `balance_sheet/4` | Assets, liabilities and equity as of one to four dates, with `earnings`, `total_assets`, `total_liabilities_and_equity` |
| `cash_position/4` | The balances of the accounts the cash sections cover, as of one to four dates |
| `overview/4` | Headline figures for a period and `previous_period/1` of it |
| `account_activity/4` | One account's debits and credits over a window, and the entries behind them |
| `subscribe/2` | The ledger's posting notices (`Ledger.subscribe_postings/2`) |
| `previous_period/1` | The comparison period: as many whole months before, or as many days |
| `valid_sections?/1` | The validator Base Settings runs on the layout setting |

Every amount is a list with one value per column, in the order the periods
or dates were given; the first column is the reporting period and the rest
its comparatives. Every report takes the option `through_entry_number`.

## Authorization and company scope

Every function authorizes `finance.ledger.view` for the scope's signed-in
actor and the target company when it runs, through
`Bilimbi.Core.Company.authorize_company_target/3`, and the ledger calls it
makes authorize again: a system scope or a missing grant is
`{:error, :unauthorized}`, and a company the scope cannot see is
`{:error, :company_not_found}`. Reports have no capability of their own:
their figures are the ledger's, so reading them is reading the ledger.

## Figures that reproduce

A report names `through_entry_number`, the last ledger entry it counts, and
every column is read at that same number. Posted entries never change and
are numbered in posting order, so passing the number back reproduces the
report's figures exactly, whatever was posted since, including entries
back-dated into its periods. `account_activity/4` given the report's window
and number lists exactly the entries the figure counted, and its debits and
credits equal the figure.

Each account reports its own postings, so a parent account is never counted
twice. Account names, the chart's parents, and the section layout are read
as they are when the report runs, as the ledger's trial balance reads
account names.

## Grouping and signs

The five account types are the one fixed classification. A profit and loss
lists income then expenses; a balance sheet lists assets, liabilities, then
equity. Within a type, accounts are grouped by the company's sections in
their configured order, and accounts no section covers follow under no
heading. A statement lists every account with a posting in any of its
columns.

Amounts are on the type's natural side: assets and expenses as debits less
credits, liabilities, equity and income as credits less debits. Net income
is income less expense. A profit and loss, the overview's income and
expense, and their drill-downs leave out the ledger's year-end closing
entries and their reversals (`exclude_closing` on the ledger's reads), so a
closed year still shows its activity rather than zero. The balance sheet
counts them: a closed year's result sits in the retained-earnings account,
and `earnings` is the income less expense not yet closed into it. That line
is part of equity, so `total_assets` always equals
`total_liabilities_and_equity`.

The cash position lists every account its sections cover, whatever its type
and whether or not it has postings, as debits less credits, so an overdrawn
bank account kept as a liability counts against the total.

## Configuration

Section headings and account choices are a company's own data, never code.
They are the `finance.reports.sections` setting (Base Settings, tenant or
company scope): an ordered JSON array of sections, each with only these
keys.

```json
[
  {"report": "profit_and_loss", "name": "<heading>", "accounts": ["<code>", "<code>"]},
  {"report": "balance_sheet", "name": "<heading>", "accounts": ["<code>"]},
  {"report": "cash_position", "name": "<heading>", "accounts": ["<code>"]}
]
```

A listed account brings its sub-accounts in the chart, unless a sub-account
is listed itself: the nearest listed account decides, and within one report
the first section that lists a code keeps it. The cash position lists only
the accounts its sections cover. `valid_sections?/1` refuses any other shape
on save; a stored value that is not valid (written before validation, or
adopted) groups nothing rather than grouping wrongly. A report names, in
`unmatched_codes`, any listed code the chart does not have.

The setting is editable in group `finance.reports` on the operator Settings
screen at company scope, by holders of `finance.ledger.accounts.manage`, and
through `Bilimbi.Base.Settings.put/3`. A page on which a company's own users
arrange sections is later work.

## Comparative periods

`previous_period/1` gives a period of whole calendar months the same number
of whole months before it (a quarter compares with the previous quarter, a
year with the previous year) and any other period the same number of days
before it. The pages compare the balance sheet and the cash position as of
the day before the period starts.

## Live updates

`subscribe/2` relays the ledger's posting notices, which PostgreSQL delivers
only when the posting transaction commits (see the ledger's README,
"Posting notices"). A notice carries no figures; the reader reads again
through this facade.

## Pages

`/finance/reports` (menu Finance › Reports, route capability
`finance.ledger.view`, titled Management reports) shows one period, chosen
with the shared period filter, in four tabs: an overview of the headline
figures against the previous period, profit and loss, balance sheet, and cash
position, each labelled as a management report. Each
account's amount links to `/finance/reports/accounts/:account_id`, which
lists the entries behind it with who posted each and when. The page reads
again when an entry posts. "Pin these figures" adds the report's entry
number to the address and stops automatic posting updates. The address
freezes ledger postings; it is not an issued copy and metadata can still change.

`/finance/reports/bookkeeping` (menu Finance › Bookkeeping, route capability
`finance.ledger.view`) shows whether the company is controlled, and why it
was last changed, with every change. A controlled company with no fiscal year
is told so, and the first year is opened on this page (`open_fiscal_year/3`,
`finance.ledger.periods.manage`), explicitly, before anything posts; turning
controlled bookkeeping on (`finance.ledger.controlled-bookkeeping.manage`) is
one button, and turning it off asks for a reason, which the approval
exceptions then list. Below it are the entries recorded 45 or more days after
their transaction dates, approaching (45 to 60 days) or late (over 60), with
who posted each and its review; an independent reviewer records the reason
for each with `finance.ledger.late-recordings.review`, which the ledger's
facade refuses from whoever posted the entry. The list leaves out the
year-end closing entries and reopen reversals the ledger writes itself, as
the figures' `exclude_closing` does. The ledger's README describes both rules.

`/finance/reports/approval-exceptions` (menu Finance › Approval
exceptions, route capability `finance.ledger.view`) is the ledger's approval
exceptions by period, chosen with the shared period filter in the viewer's
time zone: every same-person approval and every override of a control, with
the record, who prepared and approved it, the reason, and its review,
filtered by review status. It shows the company's separation of duties and
every change to it, and offers turning it off with a reason (or requiring it
again) to `finance.ledger.duty-separation.manage`, and recording a review to
`finance.ledger.approval-exceptions.review`; both are the ledger's facade
calls, which re-ask their capability and refuse a review by whoever approved
or prepared what an exception records.

## Performance

Each column is one aggregate query in the ledger: PostgreSQL sums the lines
per account, using the lines' account and entry indexes and the entries'
date index, and returns one row per account. No report loads lines into
memory; the drill-down pages entries 100 at a time. A report reads at most
four columns, and the overview four windows.

## Standards addressed

The module supports the audit trail a company's accounts are reviewed on.
What it covers:

- **Issued reports.** `issue_report/5` stores the figures, dates, entry cutoff,
  chart, layout, labels, generator version, issuer and database-stamped time.
  `get_issued_report/3` returns that immutable stored copy. Entry pins alone
  reproduce postings, not complete live reports.
- **Traceability.** Every figure on a statement opens the entries that make
  it up, numbered gaplessly by the ledger, with who posted each (and any
  impersonator) and when; reversals and reversed entries are marked, so a
  correction is visible as a reversal, never as a changed figure.
- **Immutable records, nothing deleted.** Reports keep and delete nothing;
  they read only posted entries, which the ledger keeps append-only. The
  section layout is a Base Settings value, and every change to it is a Repo
  write that Base Audit records with its actor and time (ADR 0013).
- **Double-entry consistency.** Statement totals come from the same
  per-account sums as the trial balance, and the balance sheet balances by
  construction.
- **Independent review.** The approval exceptions page lists, by period,
  what an independent reviewer reads when a company cannot separate duties
  (same-person approvals) and every override of a control, and records each
  review with the reviewer and time. The bookkeeping page lists the entries
  recorded late the same way, with each review.
- **No standard hard-coded.** Management reports group by the five account
  types and the company's own sections; no chart, heading, or statement
  format of any accounting standard is built in, and none is claimed.

Gapless document numbering does not apply: reports issue no numbered
documents. Known gaps, not built, so these outputs are management reports only:

- an accountant-adjustment or statutory-pack bridge from these figures to
  statutory statements;
- a cash flow statement;
- a statement of changes in equity or other comprehensive income;
- notes to the statements;
- versioned restatement that retains the originally issued report (a
  current-period reversal is not one);
- SST return source-linked tax-point, rate, and exemption adjustments, their
  approvals, the filed version and acknowledgment, and payment evidence;
- payroll posting tied to an approved pay run with its source evidence.

## Tests

Module tests run on the ledger's temporary tables
(`Bilimbi.Finance.Ledger.TestFixtures`) and the Settings table;
`test/support/test_fixtures.ex` builds a chart with a parent account and
installs a contribution snapshot with the ledger's capabilities and this
module's setting. `web_test/` drives the pages in the real host, the
bookkeeping page included; a sandboxed
post never commits, so the live update is proved there by delivering the
notice the ledger sends after a commit.

## Issuing and evidence export

`issue_report(scope, company, kind, dates, options)` supports `:profit_and_loss`,
`:balance_sheet`, `:cash_position`, `:trial_balance`, `:aged_receivables` and
`:aged_payables`. Arguments follow their live APIs. It requires an outer
repeatable-read transaction and the writable company lock; call outside a
transaction. The stored `content`, `chart`, `layout` and `membership` are durable JSON with
string keys, exact decimal strings and ISO dates/timestamps. `get_issued_report/3`
reads these stored values rather than recalculating. The report implementation
version is independent of future code changes. Section membership is stored explicitly for every covered chart account;
the configured layout and effective section headings are retained too.

`export_auditor_pack(scope, company, as_of)` returns Base Artifacts metadata
for a ZIP download. `read_auditor_pack/3` rechecks export and all Finance source view grants,
and verifies integrity on every download. The reports page provides generation
and download controls. Source evidence is all company records visible in one repeatable-read
database snapshot, including drafts, reversals and lifecycle events; the trial
balance and aging summaries additionally use the supplied date and the same
ledger entry cutoff. Each owning Finance facade exposes bounded, ID-ordered
`evidence_page/4` reads; the generator consumes every page through the terminal
cursor and writes CSV incrementally. Source schemas remain private.

The archive includes line-level ledger entries/lines and chart, trial balance,
AR/AP documents, lines, tax, payments and allocations, payment requests with
their events, fiscal closing events, manual journals with their lines and
decisions, approval exceptions with their reviews, duty-separation changes,
e-invoice code overrides, e-invoice submissions and status events, bank statements and lines, matches,
match events, stored reconciliation figures/items, and issued report snapshots.
Base Audit trails are not included: they stay behind Base Audit's own
capability. The source-file index names imported bank files with their original
SHA-256; their original bytes are not retained. Exact authority submission
payloads are included with their hashes. No source uploads exist for the current
AR/AP document APIs.

The pack covers the Ledger, Receivables, Payables, Reconciliation, E-invoice,
Payroll, SST and Fixed Assets modules: each facade's `evidence_page/4` exports every table of
the module, including payroll posting events, mapping and settings changes,
and SST registrations, mappings, returns, return events, boxes, accounts,
sources and adjustments; and fixed-asset categories, revisions, assets, runs, items, exceptions and events. Ledger evidence and line-level GL include owner module/record and legacy flags; e-invoice source links identify already-recognised transactions. The manifest's `filters.evidence` names these modules.
A test lists every table of those modules and fails unless the pack exports it
or an exclusion names it with a reason (the only exclusion is the issued
report table, which the pack writes as `issued-reports.csv`), so a new table
cannot be left out unnoticed.

`manifest.json` records the company/tenant, database snapshot, ledger cutoff,
filters, UTC timezone, generator version, actor/time, file hashes, CSV row counts
and line debit/credit control totals, verified against ledger aggregates. Amounts retain their exact decimal written
form, never floats. Text that could be interpreted as a spreadsheet formula is
prefixed with an apostrophe before CSV quoting. Numeric Decimal cells remain
numeric, including negative balances. Archive publication is bounded by the
configured Base Artifacts size limit; errors return no downloadable partial pack.
Artifacts have their configured expiry, distinct from durable issued snapshots.
Grant auditors Finance view and export capabilities through ordinary company
authorization; database credentials are unnecessary.
