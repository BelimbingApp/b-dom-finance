# SST returns

Module ID: `finance/sst`. Malaysia's Sales and Service Tax return, form
SST-02, for a company registered for sales tax, service tax, or both: its
registration, kept as numbered versions; which SST-02 item each tax code of
receivables and payables reports in; and the return of each tax for each
taxable period, computed from posted documents only, reconciled against the
tax accounts' ledger postings with any difference shown, finalised into a
stored snapshot that never changes, and amended by a new version for the
same period. It reads documents and ledger figures only through the
`finance/receivables`, `finance/payables`, and `finance/ledger` facades and
never reads their tables; other modules call this module's facade and never
read its tables.

Filing the return electronically to MySST, paying the tax, and the penalty
of item 15 are out of scope: the return is prepared, reviewed, finalised,
and exported here, and filed by the company.

## Sources

The form's layout and rules come from the Royal Malaysian Customs
Department (RMCD) and the MySST portal, as read on 13 October 2026:

- **Form**: Borang SST-02 as amended on 2 October 2026,
  <https://mysst.customs.gov.my/wp-content/uploads/2026/10/BORANG-SST-02-AMENDMENT-02102026.pdf>.
- **Completion guide**: *Panduan Mengisi Penyata SST-02 (Secara
  Manual/Pindaan)*, 31 May 2026,
  <https://mysst.customs.gov.my/wp-content/uploads/2026/07/Panduan-Mengisi-Penyata-SST-02-Manual-Pindaan-BM-2026-2.pdf>.
- **Guide on Return and Payment**, version 3 (13 October 2020), RMCD's
  specific guide for sales tax and service tax.
- **Sales Tax Act 2018** (Act 806) and **Service Tax Act 2018** (Act 807),
  with the Sales Tax Regulations 2018 and Service Tax Regulations 2018.
- **Rates**: Sales Tax (Rate of Sales Tax) Order 2025, P.U.(A) 170/2025, in
  force 1 July 2025 (10% generally, 5% on First Schedule goods, specific
  rates on Second Schedule goods); Service Tax (Rate of Tax) Order 2018 as
  amended by P.U.(A) 64/2024 (8% from 1 March 2024) and P.U.(A) 173/2025
  (from 1 July 2025: 8% generally, 6% on the First Schedule's services,
  RM25 a card a year on credit and charge cards) and P.U.(A) 125/2026
  (rental or leasing at 6% from 1 January 2026). The orders are linked from
  <https://mysst.customs.gov.my/sst-orders/>.

Rates are a company's data, never code: each tax code carries its rate, and
the boxes of items 11(a) to 11(d) check that the codes mapped to them carry
5%, 10%, 6%, and 8%, the rates the form prints. A new rate the form gains
is a new box in `Bilimbi.Finance.Sst.Form`, reviewed like code.

## Public API

Call `Bilimbi.Finance.Sst` with a validated `Bilimbi.Base.Tenancy.Scope`
and an explicit company ID. Results are plain maps; the schemas are private.

| Function | Capability | Does |
| --- | --- | --- |
| `get_registration/2`, `list_registrations/2` | `finance.sst.view` | The current registration and every version |
| `register/3` | `finance.sst.settings.manage` | Records the next version: `sales_tax_number`, `service_tax_number`, `period_months`, `period_start`, `service_tax_basis`, `reason` |
| `taxable_periods/3` | `finance.sst.view` | The cycle's recent periods with their due dates |
| `list_tax_codes/2` | `finance.sst.view` | Every receivables and payables tax code with its current mapping |
| `map_tax_code/3` | `finance.sst.settings.manage` | Maps a tax code (`source`, `tax_code_id`) to a `box`, or to none (not reported), with a `reason` |
| `list_mappings/3` | `finance.sst.view` | Every mapping recorded, oldest first |
| `preview_return/4` | `finance.sst.view` | A period's figures without opening a return, optionally pinned |
| `open_return/3` | `finance.sst.returns.sst-prepare` | Opens the `tax_type` return of the period starting `period_start` |
| `add_adjustment/4`, `withdraw_adjustment/4` | `finance.sst.returns.sst-prepare` | Adds an adjustment to an open return; withdraws one with a `reason` |
| `discard_return/4` | `finance.sst.returns.sst-prepare` | Discards an open return with a `reason` |
| `finalise_return/3` | `finance.sst.returns.sst-finalise` | Finalises an open return into its stored snapshot |
| `amend_return/4` | `finance.sst.returns.sst-amend` | Opens the next version of a finalised return, with a `reason` |
| `get_return/3`, `list_returns/3` | `finance.sst.view` | A return with its figures, adjustments, events, and checks; the returns on record |
| `reproduce_return/3` | `finance.sst.view` | Reads a finalised return again at its recorded numbers and says whether it equals its snapshot |
| `export_return/4` | `finance.sst.view` | The return as CSV in SST-02 item order, or as a printable HTML page |

## Authorization and company scope

Every call authorizes its capability for the scope's signed-in actor and the
target company when it runs, through
`Bilimbi.Core.Company.authorize_company_target/3`, as the ledger does: a
system scope is `{:error, :unauthorized}` and a company the scope's tenant
cannot see is `{:error, :company_not_found}`. Writes take
`Bilimbi.Core.Company.lock_writable_company/2` inside their transaction, so
an archived company is `{:error, :company_archived}` and one company's SST
writes run one at a time.

Authz verbs are shared vocabulary and only capability keys need one owner;
this module declares its own verbs with an `sst-` prefix:
`sst-prepare`, `sst-finalise`, and `sst-amend`; `view` and `manage` are the
platform's. Preparing, finalising, and amending are separate capabilities,
so a company can have one person prepare a return and another finalise it.
A call that computes a return's figures or lists tax codes reads the other
modules through their facades with the same scope, so it also needs
`finance.receivables.view`, `finance.payables.view`, and
`finance.ledger.view`. The Tenant Owner role holds every SST capability.
Each page re-asks its event's capability through
`Bilimbi.Base.Authz.LiveAuthorization` before calling the facade, which
asks again.

## Registration

A registration holds the sales tax and service tax registration numbers
(at least one, each shaped `A00-0000-00000000` as the completion guide's
example is: a station letter and two digits, the year and month of
registration, and an eight-digit serial), the taxable period cycle, and when service tax is due.
It is never changed: `register/3` records the next version, numbered by the
database, with the actor, reason, and time, carrying over whatever the call
leaves out; a call that changes nothing records nothing. Each return keeps
the version it was prepared under.

**Taxable periods.** A taxable period is two months, the first running
from the date a person is registered to the end of the month after it
(section 25(1) of both Acts); the Director General may approve another
length (section 25(2) and (3)). The cycle is `period_start` and
`period_months`: the first period runs from `period_start` to the end of
the month `period_months` months on, counting its own month, and each later
one is `period_months` whole calendar months. A return is due on the last
day of the month after its period ends (section 26(1)), or 30 days after it
on a varied cycle (section 26(2)); a due date on a weekend or holiday moves
to the next working day, which is not computed here.

**Service tax basis.** Service tax is due when payment is received
(section 11(1) of the Service Tax Act), or, unpaid twelve months after the
invoice date, on the day after (section 11(2)); a registrant may apply to
account for it when invoiced instead (section 11(1A); Guide on Return and
Payment, paragraph 6). `service_tax_basis` is `payment` (the default) or
`invoice`. Sales tax is always due when goods are sold (section 11(1) of
the Sales Tax Act), by the document date.

The cycle and the basis change only from a `period_start` after the last
finalised return's period, so a reported period stays the period it was and
nothing is counted under two bases; the registration numbers may change at
any time. A period is opened under the latest version whose cycle starts on
or before it.

## Tax code mappings

Each receivables and payables tax code is mapped to the SST-02 item it
reports in, or to none (deliberately not reported, such as a code for a
tax other than SST). A mapping is never changed: `map_tax_code/3` records
the next one, numbered, with the actor, reason, and time, and the latest
for a code applies. A return reads the mappings through the mapping number
it records. A code with tax in a period and no mapping stops the return
finalising; it is never silently left out.

| Source | Items a code may map to |
| --- | --- |
| Receivables | 11(a), 11(b), 17, 18(a), 18(b)(1) to 18(b)(3)(iii), 18(d) for sales tax; 11(c), 11(d), 18(c)(1) to 18(c)(4) for service tax |
| Payables | 19, 20, 21 (Schedule C purchases) for sales tax; 11(c), 11(d) (taxable services acquired or imported) for service tax |

## The form

`Bilimbi.Finance.Sst.Form` holds each tax's boxes in the form's order.
SST-02 is filed separately for sales tax and service tax, so each return is
of one `tax_type`.

| Item | Sales tax | Service tax |
| --- | --- | --- |
| 11 | (a) goods at 5%, (b) goods at 10%: value and tax | (c) services at 6%, (d) services at 8%: value and tax; (e) Group H item 1 cards: tax |
| 12 | 11(a) + 11(b) + 17 | 11(c) + 11(d) + 11(e) |
| 13 | (a) credit notes, (b) sales tax deduction, (d) bad debt relief; 13A excess deduction claimed earlier | (a) credit notes, (c) service tax deduction, (d) bad debt relief |
| 14 | 12 − 13(a) − 13(b) − 13(d) − 13A | 12 − 13(a) − 13(c) − 13(d) |
| 17 | Second Schedule goods at specific rates: value and tax | — |
| 18 | (a) exports and Special or Designated Areas; (b)(1) to (b)(3)(iii) Schedule A, B, and C exemptions; (d) section 35(3) or 61A: values | (c)(1) to (c)(4) exempted and non-taxable services: values |
| 19 to 21 | Schedule C purchases: values | — |

Item 14 follows the completion guide's formula for each tax; the form's
printed formula leaves out 13(d), which the guide says is deducted once
the Director General approves the relief. Items 15 and 16 (penalty), Part
B1's lines per item, and Part F's declaration are completed when the return
is filed.

## Figures

A return's figures (`Bilimbi.Finance.Sst.Figures`) read, at one ledger
entry number:

- `Ledger.account_totals/3` over the period, which names the
  `through_entry_number`;
- `Receivables.tax_totals/3` and `Payables.tax_totals/3` at that entry
  number: the tax on documents issued or posted in the period, summed by
  PostgreSQL per document kind and tax code;
- for service tax on the payment basis, `Receivables.received_tax_totals/3`
  at the same number instead of receivables' invoices: the tax share of
  each payment received in the period before its invoice fell due under
  the twelve-month rule, less the share of payments reversed in the period
  before that day (a reversal on or after it leaves the unpaid balance,
  already taxed under section 11(2), alone);
  the share each invoice still owed when its twelve months ran out in the
  period; and credit notes issued after that on tax already due.

Each row goes to the box its tax code maps to: an invoice or bill adds its
value and tax; a credit note on an invoice issued in the same period, or a
payables debit note, subtracts them; a credit note on an earlier period's
invoice deducts its tax in item 13(a), where the guide puts credit notes
for tax already paid (regulation 8 of the Sales Tax Regulations and
regulation 11 of the Service Tax Regulations put a note's adjustment in the
return for the period it is issued in). A row whose code maps to the other
tax's form is left to that return. Each box is the exact sum of its rows
and adjustments, rounded half up to the book's minor units; items 12 and 14
are computed from the rounded boxes.

`figures.sources` lists every row with its box and signed contribution;
`unmapped` the rows whose code has no mapping; `rate_mismatches` the rows
mapped to a rated box of another rate, or to a value box with tax. Either
list keeps the return from finalising.

**Ledger reconciliation.** For each tax account a code of the form (or an
unmapped code) posted to in the period, the figures compare the account's ledger debits and credits over the
period with what every document posted to it: receivables invoices credit
their tax and credit notes debit it; payables bills debit theirs and debit
notes credit it. The `difference`, ledger credits less debits less the
documents' credits less debits, is shown on every return and stored with a
finalised one, never hidden. A difference is an entry no document
explains: the payment of an earlier return, a manual journal, or another
module's posting such as an e-invoice's. Under the payment basis the
return's service tax differs from the documents' by design; the
reconciliation still compares documents with postings.

## Returns

`open_return/3` opens the return of a tax for a taxable period of the
registration that holds a number for that tax (`:not_registered`,
`:not_registered_for_tax`, `:not_a_taxable_period` otherwise). Per tax, one
return of a period is open at a time (`:return_open`), no period overlaps
another's (`:period_overlaps`), and a finalised period takes only an
amendment (`:return_finalised`). Returns are numbered per company without
gaps.

While open, a return's figures are read now, and the page follows the
ledger's posting notices. **Adjustments** cover what documents cannot
show: approved bad debt relief (item 13(d), claimed on JKDM No. 2 and
entered once approved: section 36 of the Sales Tax Act, section 35 of the
Service Tax Act), a sales or service tax deduction (13(b), 13(c)), goods
taken for own use, the repayment of relief on a bad debt later recovered
(section 37 of the Sales Tax Act, section 36 of the Service Tax Act; no
item is dedicated to it, so the preparer adds it to the box the original
tax was in), or cards under Group H item 1 (11(e)). An adjustment names a
box the form lets a preparer adjust, a value or tax in the book's minor
units (a column the box does not take is zero), and a description; it adds
to its box, and a deduction box deducts from item 14. It is withdrawn by an
appended row with a reason, never deleted.

`finalise_return/3` refuses a return whose period has not ended
(`:period_not_ended`), one with unmapped codes
(`{:unmapped_tax_codes, rows}`), and one with rate mismatches
(`{:rate_mismatch, rows}`). Otherwise it reads the figures now and records,
in one transaction, the `finalised` event with the ledger entry, mapping,
and adjustment numbers they were read at, the currency, the tax payable,
the actor, and the database's time; every box; every source row; and every
account of the reconciliation. From then on `get_return/3` reads that
snapshot, nothing about the return changes, and `reproduce_return/3` reads
the figures again from the live records at the recorded numbers and says
whether they equal it: posted documents never change and later ones carry
later entry numbers, so they do.

A finalised return also shows `posted_since`: the boxes that documents
dated in its period and posted after it would change (nil for an actor
without the receivables, payables, and ledger view grants, who still reads
the snapshot). A document a period
missed is never silently left out; it is reported by an amendment.

`discard_return/4` closes an open return with a reason instead; it stays on
record, numbered, and the period can be prepared again.

**Amendments.** A finalised return is never edited. `amend_return/4`
opens a new return for the same tax and period that names it, with a
reason, carrying the standing adjustments it had (each copy naming the
adjustment it copies). It is prepared and finalised as any return; its
version, assigned by the database when it is finalised, follows the one it
amends, the amended return shows `superseded_by_return_id`, and only the
latest finalised version is amended (`:return_superseded`). The amendment's
`amends` shows the amended version and every box that changed. RMCD lets a
return be amended in MySST before it is paid and the due date passes, and
takes tax left out afterwards as a supplement to the same period (Guide on
Return and Payment, paragraphs 30 and 31); which applies is the filer's
choice, and filing either is out of scope.

## Export

`export_return/4` writes the return as CSV, one row per item in the form's
order with its part, item number, description, value, and tax, preceded by
Part A's particulars and the status (a draft until finalised, then the
version), and followed by the numbers it was read at; text a spreadsheet
would read as a formula is quoted. `format: :html` writes a printable page
with Part A, the items, the adjustments, and the ledger reconciliation, a
draft marked as such. A discarded return is not exported.

## Pages

| Route | Capability | Page |
| --- | --- | --- |
| `/finance/sst` (Finance › SST returns) | `finance.sst.view` | The recent taxable periods with each registered tax's return, a form that prepares any period's return, and every return on record |
| `/finance/sst/returns/:id` | `finance.sst.view` | One return: Part A, what keeps it from finalising, the items, adjustments, source rows, ledger reconciliation, history, and the finalise, discard, amend, and adjustment controls |
| `/finance/sst/returns/:id/export.csv`, `/print` | `finance.sst.view` | The CSV download and the printable page |
| `/finance/sst/setup` (Finance › SST setup) | `finance.sst.view` | The registration with its history and form, and every tax code with its item, the mapping form, and the mapping history |

A control the actor may not use is withheld with a sentence saying so, and
every event re-asks its capability.

## Database

The migration `20261015090000` is `:bilimbi_only` and creates
`finance_sst_registrations`, `_mappings`, `_returns`, `_return_events`,
`_return_adjustments`, `_return_boxes`, `_return_sources`, and
`_return_accounts`. Rows of one company reference each other through
composite `(id, company_id)` foreign keys; tax code and ledger account IDs
are plain columns. PostgreSQL enforces the rules the facade checks, so no
other writer can break them:

- every table is append-only: no UPDATE, DELETE, or TRUNCATE;
- triggers number each company's registration versions, mappings, returns,
  return events, and adjustments without gaps and stamp their times,
  replacing whatever the writer sent, and give a `finalised` event its
  version, the count of the period's finalised returns of that tax;
- a registration's cycle or basis changes only from after the last
  finalised period;
- per tax, one open return of a period, no overlapping periods, a period's
  first return amends nothing and every later one amends its latest
  finalised return with a reason;
- a return is recorded with its `opened` event (a deferred check refuses
  one without); `finalised` and `discarded` need an open return, a
  `finalised` event carries its numbers, currency, and tax payable, a
  deferred check refuses one without its box figures, and a `discarded`
  one needs a reason;
- a finalised return's boxes, sources, and accounts are inserted only in
  the transaction that finalises it; an account row's difference must
  follow from its debits and credits;
- an adjustment is recorded only on an open return, and a withdrawal names
  an adjustment of the same return, at most once.

`Bilimbi.Finance.Sst.SchemaContract` describes the tables but is not
registered in the descriptor: compatibility verification runs before
pending Bilimbi-only migrations, when these tables correctly do not exist.
`test/schema_contract_test.exs` runs the migration in a fresh database,
verifies the contract, rolls it back, and proves the triggers that only a
commit or a later transaction shows.

## Standards addressed

- **Audit trail.** Every registration version, mapping, return, return
  event, and adjustment records who made it (and any impersonator) and the
  database's time; opening, finalising, discarding, withdrawing, and
  amending are appended records with their actor and reason, so a return's
  status is always its latest event's and the log is the whole history.
- **Gapless numbering.** Registration versions, mappings, returns, return
  events, and adjustments are numbered per company by the database in
  order, never skipped or reused; a return's version per period follows
  its finalisation order.
- **Nothing deleted.** No SST row is updated, deleted, or truncated; a
  wrong return is discarded or amended on record, a wrong adjustment
  withdrawn on record, and unmounting Finance keeps every row.
- **Reproducible reports.** A finalised return keeps its boxes, source
  rows, and reconciliation as they were, with the ledger entry, mapping,
  and adjustment numbers that reproduce them from the live records;
  `reproduce_return/3` proves it.
- **Completeness.** Only posted documents count, each by its own date and
  ledger entry; a tax code with tax and no mapping stops a return
  finalising; a ledger difference is shown and kept; documents posted into
  a finalised period are shown beside it until an amendment reports them.
- **Records.** RMCD requires records to be kept for seven years (section
  24(2) of both Acts); nothing here is ever removed, so how long they are
  kept is the company's policy, not code.

## Tests

Module tests run on temporary copies of the tables built from the
migration's own `statements(temporary: true)`, constraints and triggers
included, and the ledger's, receivables', and payables' from their own
fixtures. `test/support/sst_case.ex` builds a company with a chart, tax
codes in both modules, and a registration on a two-month cycle from
1 January 2026. `web_test/` covers the three pages and the export against
the real host. Registration numbers in tests are made up with the station
letter `X`, which no station uses; no real company, number, TIN, or person
appears.
