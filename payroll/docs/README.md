# Payroll and claims posting

Module ID: `finance/payroll`. The bridge from a company's payroll runs and
staff expense claims to its ledger: the accounts net pay and approved claims
are owed on, the mapping of each payroll component (gross pay, each
contribution and deduction, whatever the company calls them) and each claim
category to ledger accounts, the posting of one balanced journal entry per
finalised run and per approved claim, the reversal of a posting, and the
append-only record of every attempt. The runs and claims come from an
optional source Domain (People's payroll and claims when mounted) through
`Bilimbi.Finance.Payroll.PeopleSource`; this module posts to the ledger only
through `Bilimbi.Finance.Ledger`'s facade and never reads the ledger's or
the source's tables; other modules call this module's facade and never read
its tables.

## Public API

Call `Bilimbi.Finance.Payroll` with a validated `Bilimbi.Base.Tenancy.Scope`
and an explicit company ID. Results are plain maps; the schemas are private.

| Function | Capability | Does |
| --- | --- | --- |
| `get_settings/2` | `finance.payroll.view` | The posting accounts: `net_pay_account_id`, `claims_payable_account_id` |
| `put_settings/3` | `finance.payroll.settings.manage` | Sets both (active liability accounts) with an optional `reason` |
| `list_settings_changes/2` | `finance.payroll.view` | The change log: values before and after, actor, reason, time |
| `list_mappings/2` | `finance.payroll.view` | The mappings of components and claim categories to accounts |
| `put_mapping/3` | `finance.payroll.settings.manage` | Adds a mapping by `kind`, `code`, `direction`, or changes an existing one's accounts, with an optional `reason` |
| `list_mapping_changes/2` | `finance.payroll.view` | The change log of the mappings |
| `list_payroll_runs/2`, `list_claims/2` | `finance.payroll.view` and the source's | The source's runs and approved claims, each with its `posting` and `last_failure` |
| `post_payroll_run/3`, `post_claim/3`, `post_claims/3` | `finance.payroll.postings.post` | Posts one entry through the ledger and records the outcome |
| `reverse_posting/4` | `finance.payroll.postings.post` | Reverses a posting's entry with a `reason` and records it |
| `list_postings/2`, `get_posting/3` | `finance.payroll.view` | What was posted, with each reversal, from this module's own events |
| `list_posting_events/2` | `finance.payroll.view` | Every `posted`, `posting_failed`, `reversed`, and `reversal_failed` event |
| `people_available?/0` | none | Whether a source of runs and claims is installed |

## Authorization and company scope

Every call authorizes its capability for the scope's signed-in actor and the
target company when it runs, through
`Bilimbi.Core.Company.authorize_company_target/3`, exactly as the ledger
does: a system scope is `{:error, :unauthorized}` and a company the scope's
tenant cannot see is `{:error, :company_not_found}`. Writes take
`Bilimbi.Core.Company.lock_writable_company/2` inside their transaction, so
an archived company is `{:error, :company_archived}` and one company's
payroll writes run one at a time.

The module declares no verb of its own: `view` and `manage` are Base
Authz's and `post` is the ledger's, so no verb here can clash with one
another Domain declares. Posting and reversing need `finance.ledger.view`
and `finance.ledger.entries.post` too, because the ledger authorizes its own
calls, and listing or posting runs and claims needs the source's read
capabilities (for People, `people.payroll.view` and `people.claims.approve`),
because the source authorizes its own. The Tenant Owner role holds every
payroll capability. Each page re-asks its event's capability through
`Bilimbi.Base.Authz.LiveAuthorization` before calling the facade.

## The source of runs and claims

`Bilimbi.Finance.Payroll.PeopleSource` is the seam. It finds the installed
source among the module descriptors Base Module Registry recorded for the
loaded applications, by the descriptor IDs `people/payroll` and
`people/claims`, and calls their facades by the namespace each descriptor
declares; nothing in this module aliases a People module, and the
descriptor declares no edge to People, so Finance composes without it.
Without the source, `people_available?/0` is false, the listing and posting
calls are `{:error, :people_unavailable}`, the page says so, and what was
posted is still read from this module's events. Module tests substitute the
source with `test/support/stub_people_source.ex`; the last test in
`web_test/payroll_postings_live_test.exs` proves the installed one with both
Domains mounted.

The seam answers in meta-terms. A run is `%{id, reference, pay_date,
currency_code, status, finalised, components}`, its `components` the run's
lines summed per pay item `code` and `direction` (`earning`, `deduction`, or
`employer`); it is `finalised` once its figures are final and approved (for
People, once the run has its calculation and an approved decision). A claim
is `%{id, reference, approved_on, currency_code, amount, category_code,
claim_type_code, status}`; approved and reimbursed claims are both listed,
because both were approved. People stores a claim's approval time as naive
UTC; its `approved_on`, and so the ledger date, is the company's local
calendar date of it, in the company's time zone from Base DateTime
(`localization.timezone`, the app's configured zone when the company has not
set one), so an approval at 00:30 local time on the 1st is dated the 1st. A
run whose pay date the source cannot read is listed with no pay date and
refused at posting with a recorded reason, as is a claim whose date cannot be
worked out; neither breaks the listing. A claim is read from one list of the
company's claims, so `post_claims/3` reads the source once for a batch, not
once per claim, and the page's "post every unposted claim" uses it. People offers no event or facade that voids or
reverses a run or an approval, so a reversal here is a user's decision with
a reason (`reverse_posting/4`), never a reaction to the source.

## Mappings

A mapping is keyed by `kind`, `code`, and `direction`. A `component` mapping
names a payroll pay item by the `code` the source gives it, with the
`direction` its lines carry: an `earning` names the expense account it
debits; a `deduction` names the liability account it credits (what is owed
to an authority or a fund until paid); an `employer` contribution names
both, the expense it debits and the liability it credits. A `claim_category`
mapping names a claim category by its code, with direction `claim`, and the
expense account its claims debit; the credit is the settings' claims
payable account. The settings' net pay account is the liability a run's net
pay is credited to. No account, component, or category is named in code: a
company's pay items and its chart are its data.

A mapping's key never changes; its accounts do, and each change is kept
with who made it, why, and the values before and after. Nothing is deleted.

## Posting

`post_payroll_run/3` reads the run again under the company's lock, refuses
one that is not finalised or has its `posted` event, and posts one entry
dated the run's pay date with the run's reference, one line per component
(summed across employees, so no person's pay appears in the ledger) and one
for net pay: debits for earnings and employer contributions, credits for
deductions, employer liabilities, and net pay (a debit when deductions
exceed earnings). Each component's total is rounded to the book's minor
units, half away from zero, and net pay is the difference of the rounded
earnings and deductions, so the entry balances in the book's units; the
source keeps its finer figures. `post_claim/3` posts the approved amount
dated the company's local approval date: a debit to the category's expense account and a
credit to the claims payable account.

The entry and the `posted` event that names it are one transaction, so a
source never has an entry without its event, and the database refuses a
second `posted` event for a source and one entry on two events. A refusal
(accounts unset or unmapped, the book not open or in another currency, a
closed period, a missing ledger grant) rolls that transaction back, and the
reason is recorded afterwards as a `posting_failed` event in a transaction
of its own; the page lists the source with that reason and a retry until an
attempt succeeds. A closed period is never reopened to post. A database
failure that may pass at once is tried a second time, then recorded.
`Bilimbi.Finance.Payroll.Posting` holds the rules.

`reverse_posting/4` posts the mirror entry through `Ledger.reverse_entry/4`
on the date given (today by default) and records a `reversed` event with the
reason; a posting reverses once, and a reversed source is not posted again:
its correction is a new ledger entry. A refused reversal is a
`reversal_failed` event.

## Pages

`/finance/payroll` (`Bilimbi.Finance.Payroll.Web.PostingsLive`) lists the
runs and approved claims with their standing in the books (posted with the
entry number, reversed, failed with the reason, or not posted), the post,
retry, and reverse actions, a button that posts every unposted claim, and
the postings made. `/finance/payroll/setup`
(`Bilimbi.Finance.Payroll.Web.SetupLive`) sets the posting accounts and the
mappings and shows both change logs. Both routes need
`finance.payroll.view`; the menu item sits under Finance.

## Database

The migration `20261015120000_create_finance_payroll.exs` is Bilimbi-only
and holds its schema as `statements/1`, which module tests also run with
`temporary: true`. Five tables, all prefixed `finance_payroll_`: `settings`
and `settings_changes`, `mappings` and `mapping_changes`, and
`posting_events`. Settings and mappings change in place but keep their
company and key and are never deleted; the change tables and the events are
append-only; triggers refuse everything else. Each change and event is
stamped with the database's time. Partial unique indexes keep one `posted`
and one `reversed` event per source and one entry per event, and a trigger
refuses a reversal of a source that never posted. Ledger account IDs and
source IDs are plain columns: the ledger's tables belong to `finance/ledger`
and the source's to its own Domain. `Bilimbi.Finance.Payroll.SchemaContract`
describes the schema and `test/schema_contract_test.exs` verifies it against
a fresh database.

## Standards addressed

- **Audit trail.** Every posting, reversal, and failed attempt is an event
  with its actor, reason, and database-stamped time, naming the source and
  the entry; a source's standing is its latest event, never a column. Every
  change to the posting accounts or a mapping is logged with its actor,
  reason, and the values before and after. Entries carry the source's
  reference, so an auditor walks entry to run or claim and back.
- **Gapless numbering.** The entries are the ledger's, numbered per company
  by the database in posting order; events are numbered in order of
  recording.
- **Nothing deleted.** Events and change logs are never updated, deleted,
  or truncated; a wrong posting is reversed on record, and unmounting
  Finance keeps every row.
- **Reproducible reports.** A posting keeps the entry number, date, total,
  and currency it was made with; the ledger reproduces the entry's figures
  by number, and a run's or claim's figures stay in their source.
- **Completeness and separation.** A run or claim posts once, which the
  database enforces; only a finalised run posts; the ledger authorizes
  every entry on its own, so posting needs the ledger's grant as well as
  this module's.

Out of scope here: paying salaries and claims (the liabilities are settled
by payments posted through the ledger or a payments module), statutory
submission files and formats, and a source's own payroll calculation.

## Tests

Module tests run on temporary copies of the tables built from the
migration's own `statements(temporary: true)`, constraints and triggers
included; the ledger's come from its fixtures. `test/support/test_fixtures.ex`
builds two tenants' companies and an Authz snapshot,
`test/support/payroll_case.ex` a company with a book, a chart, the posting
accounts, and a few mappings, and `test/support/stub_people_source.ex` the
substitute source. `web_test/` covers both pages against the real host, and
its last test runs only with People mounted. Payroll data in tests is made
up: pay item codes such as `basic` and `fund`, a test currency, and
whole-number amounts; no person, salary, or identity number appears.
