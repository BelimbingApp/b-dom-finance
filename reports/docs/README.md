# Reports

Module ID: `finance/reports`. A company's financial statements, read live
from its general ledger: profit and loss for any date range, the balance
sheet and the cash position as of any date, headline figures against the
previous period, and the entries behind any account's figure. It stores immutable
issued snapshots; ledger figures come through `finance/ledger`'s facade.

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
| `issue_report/5` | Immutable issued statements, trial balances and aging reports |
| `get_issued_report/3` | The stored copy, under its source view permissions |
| `export_auditor_pack/3` | Company evidence ZIP at one pinned database snapshot |
| `read_auditor_pack/3` | Reauthorized artifact download |
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
`{:error, :company_not_found}`. Issuing requires `finance.reports.issue` plus the source report's view grants.
Generating and downloading evidence requires `finance.reports.reports-export` plus
view grants for each Finance source. Auditor roles can hold these read and
export grants without posting, setup, approval, or database-console access.

## Figures that reproduce

A report names `through_entry_number`, the last ledger entry it counts, and
every column is read at that same number. Posted entries never change and
are numbered in posting order, so passing the number back freezes the
postings counted, including later back-dated entries. It does **not** freeze
the chart, names, sections, settings, or customer labels. Removing an account
from a cash section changes even a pinned live cash total. `account_activity/4` given the report's window
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
`finance.ledger.view`) shows one period, chosen with the shared period
filter, in four tabs: an overview of the headline figures against the
previous period, profit and loss, balance sheet, and cash position. Each
account's amount links to `/finance/reports/accounts/:account_id`, which
lists the entries behind it with who posted each and when. The page reads
again when an entry posts. "Pin these figures" adds the report's entry
number to the address and stops automatic posting updates. The address
freezes ledger postings; it is not an issued copy and metadata can still change.

## Performance

Each column is one aggregate query in the ledger: PostgreSQL sums the lines
per account, using the lines' account and entry indexes and the entries'
date index, and returns one row per account. No report loads lines into
memory; the drill-down pages entries 100 at a time. A report reads at most
four columns, and the overview four windows.

## Standards addressed

The module is built to the audit and reporting standards a company's
accounts are held to. What this slice covers:

- **Issued reports.** `issue_report/5` stores the figures, dates, entry cutoff,
  chart, layout, labels, generator version, issuer and database-stamped time.
  `get_issued_report/3` returns that immutable stored copy. Entry pins alone
  reproduce postings, not complete live reports.
- **Traceability.** Every figure on a statement opens the entries that make
  it up, numbered gaplessly by the ledger, with who posted each (and any
  impersonator) and when; reversals and reversed entries are marked, so a
  correction is visible as a reversal, never as a changed figure.
- **Immutable issued records.** PostgreSQL refuses update, delete and truncate
  of issued reports; the ledger keeps postings append-only. The
  section layout is a Base Settings value, and every change to it is a Repo
  write that Base Audit records with its actor and time (ADR 0013).
- **Double-entry consistency.** Statement totals come from the same
  per-account sums as the trial balance, and the balance sheet balances by
  construction.
- **No standard hard-coded.** Statements group by the five account types and
  the company's own sections; no chart, heading, or statement format of any
  accounting standard is built in. A company presents to its standard
  (MFRS, IFRS, or another) by configuring sections.

Not covered: a cash flow statement and notes.

## Tests

Module tests run on the ledger's temporary tables
(`Bilimbi.Finance.Ledger.TestFixtures`) and the Settings table;
`test/support/test_fixtures.ex` builds a chart with a parent account and
installs a contribution snapshot with the ledger's capabilities and this
module's setting. `web_test/` drives the pages in the real host; a sandboxed
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
AR/AP documents, lines, tax, payments and allocations, fiscal closing events,
e-invoice submissions and status events, bank statements and lines, matches,
match events, stored reconciliation figures/items, and issued report snapshots.
Base Audit trails are not included: they stay behind Base Audit's own
capability. The source-file index names imported bank files with their original
SHA-256; their original bytes are not retained. Exact authority submission
payloads are included with their hashes. No source uploads exist for the current
AR/AP document APIs.

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
