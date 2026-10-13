# Payables

Module ID: `finance/payables`. A company's accounts payable: documents from
parties (bills, and the debit notes that correct them), payments allocated to
bills, what is owed to whom as of any date, and the three-way match of a
bill against the purchase order and goods receipts behind it. It posts to
the ledger only through `Bilimbi.Finance.Ledger`'s facade and never reads
the ledger's tables; it reads orders and receipts only through the
installed order source's facades (`Bilimbi.Finance.Payables.OrderSource`);
other modules call this module's facade and never read its tables.

## Public API

Call `Bilimbi.Finance.Payables` with a validated `Bilimbi.Base.Tenancy.Scope`
and an explicit company ID. Results are plain maps; the schemas are private.

| Function | Capability | Does |
| --- | --- | --- |
| `get_settings/2` | `finance.payables.view` | The company's payable account and match tolerances |
| `put_settings/3` | `finance.payables.settings.manage` | Sets `payable_account_id`, an active liability account, and the match tolerances (`quantity_tolerance_kind` and `price_tolerance_kind`, each `percent` or `amount`, with `quantity_tolerance` and `price_tolerance`), with an optional `reason` |
| `list_settings_changes/2`, `list_tax_code_changes/2` | `finance.payables.view` | The history of changes to the settings and to tax codes: who, why, when, and the values before and after |
| `list_tax_codes/2` | `finance.payables.view` | The company's tax codes by code |
| `create_tax_code/3`, `update_tax_code/4` | `finance.payables.settings.manage` | A tax code: `code`, `name`, `rate` (percent), `account_id`, `active`, and an optional `reason`; the code never changes |
| `create_bill/3` | `finance.payables.documents.create` | Records a party's bill as a draft |
| `create_debit_note/4` | `finance.payables.documents.create` | Records a debit note against a posted bill as a draft |
| `approve_document/3` | `finance.payables.documents.approve` | Approves a draft |
| `void_document/4` | `finance.payables.documents.approve` | Voids a draft or approved document with a `void_reason` |
| `post_document/3` | `finance.payables.documents.post` | Posts an approved or held document to the ledger and numbers it; a bill naming order lines is matched first, and held instead when outside tolerance |
| `approve_match_exception/4` | `finance.payables.match.approve` | Approves a held bill's match exceptions with a `reason` and the `held_event_id` of the hold seen (`:stale_hold` when a newer hold exists), so it may be posted over them |
| `get_document/3`, `list_documents/3`, `page_documents/3` | `finance.payables.view` | Documents with lines, tax lines, `debit_note_ids`, `match_status`, and `match_events`; a posted bill shows `outstanding`; `page_documents/3` pages newest first for a list |
| `billed_quantities/3` | `finance.payables.view` | The quantity posted bills billed against each order line, less posted debit notes |
| `post_payment/3` | `finance.payables.payments.post` | Posts a payment allocated to one party's posted bills |
| `reverse_payment/4` | `finance.payables.payments.post` | Posts a payment's reversal |
| `get_payment/3`, `list_payments/3` | `finance.payables.view` | Payments with their allocations; `list_payments/3` filters by `party_key` or `document_id` |
| `aged_payables/4` | `finance.payables.view` | What is owed to each party as of a date, by days overdue |

## Authorization and company scope

Every call authorizes its capability for the scope's signed-in actor and the
target company when it runs, through
`Bilimbi.Core.Company.authorize_company_target/3`, exactly as the ledger
does: a system scope is `{:error, :unauthorized}` and a company the scope's
tenant cannot see is `{:error, :company_not_found}`. Writes take
`Bilimbi.Core.Company.lock_writable_company/2` inside their transaction, so
an archived company is `{:error, :company_archived}` and one company's
payables writes run one at a time; that lock is what keeps two payments from
both paying the last of a bill.

A write that touches the ledger calls its facade with the same scope, so the
actor also needs the ledger capability that call asks for:
`finance.ledger.view` to record documents, set the payable account, and keep
tax codes (they read the book and chart of accounts), and
`finance.ledger.entries.post` to post documents and payments. Reads need only
`finance.payables.view`. The Tenant Owner role holds every payables
capability. Recording, approving, posting, and approving a match exception
are separate capabilities, so a company can give them to different people;
requiring that a document's approver differ from its recorder, or an
exception's approver from its poster, is later work.

A call that reads the order source (recording a bill naming order lines, and
posting one) reads it with the same scope, so the actor also holds the
source's own view capabilities: with Supply Chain mounted,
`supply-chain.purchasing.view` and `supply-chain.receiving.view`. The
source refusing is `{:error, {:order_source, reason}}`, and nothing is
written.

Every document records who recorded it (`created_by_user_id`), approved it,
posted it, or voided it, each with any impersonator, and the database stamps
each step's time. A payment records who posted it and when.

## Documents

A document is a party's bill (`document_type` `bill`) or our debit note
against one of its bills (`debit_note`). It carries a party snapshot as it
stood on the document: `party_key`, the company's own stable key for the
party, which groups what is owed to whom; `party_name`; and optionally
`party_tax_id`, `party_registration_id`, and `party_address`. A bill also
records `party_document_number`, the party's own number for it; a party's
number is recorded once per company until that bill is voided, so the same
bill cannot be entered and paid twice. A debit note copies its bill's party.

A document has `document_date`, `due_date` (default the document date; never
before it), an optional `description`, and lines, each with a
`description`, an active `asset` or `expense` ledger account, an `amount`
net of tax, an optional `tax_code_id`, an optional
`external_order_line_id` (the caller's own reference, stored and never
interpreted), and optionally an `order_line_id` with the `quantity` billed
against it, a purchase order line of the installed order source (see
Three-way match). Each tax code the lines use becomes one tax line:
the lines' total for that code (`taxable_amount`) and its `tax_amount` at the
code's rate, rounded half up to the book's minor units, unless `tax_lines`
states the party's own figure for that code. A tax line copies its code,
rate, and account, so later changes to the tax code leave recorded documents
alone. A document's `total_net`, `total_tax`, and `total` are its lines'.

Documents move one way:

```text
draft --approve--> approved --post--> posted
  \                    \      \        ^
   \                    \      `-hold-> held --post (after approval
    \                    \                |         or a clean match)
     `------void----------`------void-----'--> voided
```

A document is recorded whole: nothing is added to its lines afterwards and
nothing it recorded changes, only its status. A bill naming order lines is
matched when it posts and is `held` instead of posted when a line falls
outside tolerance (see Three-way match); a held bill posts later or is
voided. Posting (`post_document/3`) posts one ledger entry on the document
date: a bill debits each line's
account and each tax line's account and credits the payable account from
the settings with its total; a debit note posts the opposite, to the payable
account its bill posted to, whatever the settings say by then. The document
keeps its `payable_account_id`, `entry_id`, and `entry_number`. A posted
document is never changed or voided: a bill is corrected by a debit note,
whose total cannot exceed what is still owed on the bill, checked when it is
recorded and again when it posts, on the date rule under Aged payables.

Posted documents are numbered per company and document type, 1, 2, 3, ... in
posting order, by the database: drafts and voided documents take no number,
and a refused or rolled-back post takes none, so a number is never skipped or
reused.

`list_documents/3` takes `document_type`, `status`, `party_key`, `from`,
`to`, `limit`, and `after` (`{document_date, id}`), and pages as the
ledger's `list_entries/3` does. `page_documents/3` pages newest first by
`page` and `page_size` with `document_type`, `status`, and a `search` over
the party's name and document number, for the bills list.

## Three-way match

A supplier's bill is paid for goods that were ordered and that arrived. A
bill line names the purchase order line it bills with `order_line_id` and
the `quantity` billed against it; the unit price billed is the line's
amount over that quantity. Order lines and receipts live in another
Domain, Supply Chain, which Finance never names: `Bilimbi.Finance.Payables.OrderSource`
finds the `supply_chain/purchasing` and `supply_chain/receiving` modules
among the descriptors this runtime loaded and calls `get_order_line/3` and
`order_line_receipts/3` on the namespaces they declare. Finance builds and
runs without Supply Chain; then no source is installed, a line cannot name
an order line, and a bill recorded earlier against one is held when posted,
with the exception `order_source_unavailable`.

When a bill naming order lines posts, each such line is compared, within
the company's tolerances from `put_settings/3`:

| Exception | Rule |
| --- | --- |
| `quantity_exceeds_ordered` | the quantities every posted bill billed on the line, this one included, exceed the ordered quantity |
| `quantity_exceeds_received` | the quantity exceeds what was received (net of reversals) and not yet billed by other posted bills, less posted debit notes |
| `price_differs` | the billed unit price differs from the ordered unit price, either way |
| `order_not_open` | the order is draft, submitted, or cancelled |
| `order_line_superseded` | an amendment replaced the line |
| `currency_mismatch` | the order's currency is not the book's, so the prices cannot be compared |
| `order_line_not_found` | the source has no such line in the company |
| `order_source_unavailable` | no source is installed |

A tolerance is `percent` of the ordered quantity or unit price, or an
`amount` in units of quantity or currency per unit, and applies to each
quantity rule and to the price rule; none means an exact match. Every
line within tolerance posts the bill as any other. Otherwise the bill is
held: nothing posts to the ledger, it takes no number, and `post_document/3`
returns the held document. A user holding `finance.payables.match.approve`
approves the exceptions with a reason and the id of the hold seen
(`approve_match_exception/4`; a hold recorded since is `:stale_hold`, and the
page reloads the new figures); the next posting matches afresh and posts when every exception it finds is
one the approval covers with figures no worse than the approver saw (the
hold it follows records them), or when it finds none, as when the goods
arrived meanwhile. A fresh exception, or the same one with more billed over
the order, less received, or a wider price gap, holds the bill again for a
new approval. A bill naming one order line on several lines is matched
cumulatively: each line counts the quantities of the bill's earlier lines
as already billed.

Every attempt is a match event, append-only, with the actor, any
impersonator, the database's time, and for a hold or a posting one match
line per bill line: the billed quantity and unit price, what was billed
before, the ordered quantity and unit price, the received quantity, the
tolerances in force, and the exceptions found with a plain-language detail.
`get_document/3` shows them as `match_events` and the bill's `match_status`
(`match_statuses/0`): `pending`, `held`, `exception_approved`, `matched`,
or `posted_with_exceptions`. The database refuses a held bill posting
without an approval later than its last hold unless the posting match found
no exception, a bill naming order lines posting without its `posted` match
record in the same transaction, an approval that does not name the last
hold of a held bill, and any change to a match record.

The billed quantity is this module's own record: the quantities of posted
bill lines naming an order line, less those of posted debit note lines
(`billed_quantities/3`), so the same received quantity cannot be billed
twice; the company lock serializes a company's postings, so two bills
cannot both take the last of it. A debit note's line may name an order line
the corrected bill names, with the quantity credited back, within what the
bill billed less earlier posted debit notes, checked when recorded and when
posted.

## Pages

`/finance/payables/bills` (menu Finance › Bills) lists the company's
documents newest first with their status and match status, searched by
party or the party's document number and filtered by status and type;
"Held bills" is the list filtered to `held`. `/finance/payables/bills/:id`
shows one document: party, lines with the order line each names, totals,
who recorded, approved, posted, or voided it, and for a bill naming order
lines the figures its last match compared, its exceptions, and every match
event. Its actions, each a facade call that asks its own capability, are
approve, post, approve the exceptions with a reason, and void with a
reason. Bills are recorded through the facade; a recording page is later
work, as is a settings page for the payable account and tolerances.

## Payments

`post_payment/3` posts a payment to one party on `payment_date` from
`paid_from_account_id` (an active asset or liability account, such as a bank
account), with optional `reference` and `description`, and `allocations`,
each `%{document_id, amount}` naming a posted bill of that party dated on or
before the payment. Its amount is the allocations' total; an allocation
cannot exceed what is still owed on its bill on the date rule under Aged
payables, from `payment_date` on, so a bill is paid in one or more parts. The
ledger entry debits each paid bill's own payable account and credits the
paid-from account. Payments are numbered per company like documents. Paying
ahead of a bill, and refunds from a party, are later work.

A posted payment is corrected by `reverse_payment/4`: the ledger reverses its
entry, and its bills are owed again from the reversal's date. A payment is
reversed at most once, and a reversal is not itself reversed.

Correct a payables posting through this module, never by reversing its
ledger entry with `Ledger.reverse_entry/4` directly: the ledger does not yet
know which module owns an entry, so it cannot refuse that, and the two
records would then disagree. A ledger-level owner guard is later work.

## Aged payables

`aged_payables/4` lists, per party, every posted bill dated on or before
`as_of` that is still owed, less its debit notes and the payments allocated
to it dated on or before `as_of`; a payment reversed by then counts as unpaid.
Each bill shows `days_overdue` and `bucket`, its column in `buckets`: column 0
is not yet due, column `i` is overdue up to `bucket_days[i - 1]` days, and the
last is overdue longer. `bucket_days` defaults to `[30, 60, 90]`; a company
passes its own.

The result names `through_entry_number`, the last ledger entry number of a
payables posting it counts. A posting made later with an earlier date changes
the figures for that date, so a report reproduces exactly by passing the same
`as_of` and its `through_entry_number`: postings never change and ledger
entry numbers follow posting order. Party names are the latest bill's
snapshot.

A bill is never owed less than nothing on any date. A debit note or payment
allocation of an amount is refused (`:exceeds_outstanding`, or an `amount`
error on the allocation) unless the amount fits the least that is owed on the
bill on any date from the new document's own date on: on that date, on each
later date a payment, a payment reversal, or a debit note against the bill is
dated, and now. This is checked when a debit note is recorded and again when
it posts, and for each allocation. A payment dated before one that is later
reversed is therefore refused, because the earlier one still counts until its
reversal. The aged report still never drops a bill owed less than nothing
silently, in case another writer made one: `exceptions` lists each bill owed
less than nothing as of `as_of` (with a negative `outstanding`), outside the
parties and buckets, and `exceptions_total` is their sum. `total +
exceptions_total` is what the payable accounts hold for these bills as of the
date, which is what the ledger's trial balance shows for them.

## Seams for later work

- **Order source.** `Bilimbi.Finance.Payables.OrderSource` is the behaviour
  the three-way match reads through; the installed implementation calls
  Supply Chain's facades by descriptor ID. A test substitutes a source
  through the `:order_source` application environment
  (`test/support/stub_order_source.ex`). A line's `external_order_line_id`
  stays the caller's own uninterpreted reference.
- **Self-billed e-invoices.** A posted bill carries its party snapshot
  (including tax and registration identifiers), its lines and tax lines, and
  its posting, which is what a later e-invoice module needs to issue a
  self-billed e-invoice for it through this facade. This module depends on no
  e-invoice module.

## Database

The migrations are `:bilimbi_only`. `20261012213700` creates
`finance_payables_settings`, `finance_payables_tax_codes`,
`finance_payables_settings_changes`, `finance_payables_tax_code_changes`,
`finance_payables_documents`, `finance_payables_document_lines`,
`finance_payables_document_tax_lines`, `finance_payables_payments`, and
`finance_payables_payment_allocations`. `20261014100000` adds the match
tolerances to the settings and their history, `order_line_id` and
`quantity` to document lines, the `held` status, and
`finance_payables_match_events`, `finance_payables_match_lines`, and
`finance_payables_match_exceptions`; it is self-contained and replaces the
document transition function with the held rules. Each migration's
`statements/1` is the schema's one source: the migration runs it, and
module tests run both with `temporary: true`, in order. PostgreSQL enforces
the rules the facade checks, so no other writer can break them:

- composite `(id, company_id)` foreign keys keep a line's document and tax
  code, a debit note's bill, an allocation's payment and document, and a
  reversal's original in one company; ledger account and entry IDs are plain
  columns, since the ledger's tables are another module's;
- checks keep each status's actor and time columns consistent, amounts
  positive, totals summed, and a bill's party document number present; a
  deferred constraint trigger refuses a commit in which a document has no
  lines, its totals differ from its lines, or its tax lines differ from them;
- a trigger records a document only as a draft, lets it move only draft to
  approved to posted, approved to held to posted, or to voided before
  posting, refuses any change to what it recorded, stamps each step's time,
  and numbers it on posting; a held bill posts only after an approval later
  than its last hold unless the posting match found no exception, and a bill
  naming order lines only with its `posted` match event written in the same
  transaction; a unique index refuses a reused number and a partial unique
  index a party document number recorded twice;
- a check keeps a line's order line and quantity together, and each
  tolerance kind with its value;
- a trigger records a match event only for a bill in the status its kind
  expects (an approval only for a held bill whose last event is a hold, which
  it names),
  stamps its time, and refuses a match line or exception added to an event
  recorded in an earlier transaction; a check lists the exception codes;
- a trigger refuses a line or tax line added to a document in a later
  transaction, or once it is no longer a draft, and an allocation added to a
  payment in a later transaction;
- a trigger numbers payments without gaps and stamps their posting time; a
  deferred constraint trigger refuses a payment whose allocations differ from
  its amount, or a reversal with allocations; a partial unique index allows
  one reversal per payment;
- a trigger stamps the time of each settings or tax code change, and a
  check keeps a tax code change's earlier values all present or all absent;
- triggers refuse UPDATE and DELETE on lines, tax lines, payments,
  allocations, the two change histories, and the three match tables, DELETE
  on settings, tax codes, and documents, TRUNCATE on all twelve tables, and
  a change to a tax code's code or any row's company.

`Bilimbi.Finance.Payables.SchemaContract` describes the tables but is not
registered in the descriptor, for the reason the ledger gives.
`test/schema_contract_test.exs` runs the migrations in a fresh database,
verifies the contract, rolls them back, and proves the triggers that only a
commit or a later transaction shows.

## Standards addressed

What this slice covers of the bookkeeping and audit standards a company's
payables are held to:

- **Double entry through the ledger.** Every posted document and payment is
  one balanced ledger entry posted through the ledger's facade, which keeps
  its own integrity rules; the payables record keeps that entry's ID and
  number, so each posting traces both ways.
- **Authorization and segregation.** Recording, approving, posting, paying,
  and approving a match exception are separate capabilities, checked when
  each call runs; nothing posts without an approval on record, and a held
  bill posts over an exception only with a reasoned approval on record.
- **Three-way match.** A bill naming order lines is paid only for what was
  ordered and received: posting compares each line with the order and the
  receipts within the company's tolerances, holds the bill otherwise, and
  records every comparison with its figures as an append-only event, so an
  auditor reads what was known and who accepted a difference and why.
- **Audit trail.** Every document records who recorded, approved, posted,
  or voided it and when, as the database stamped it; every payment who posted
  it and when. Corrections are new records that name what they correct (a
  debit note its bill, a reversal its payment), and the corrected record
  reports them (`debit_note_ids`, `reversed_by_payment_id`), so the trail
  runs both ways; nothing recorded is overwritten. Settings and tax codes
  change in place, so each change is also kept in an append-only history,
  written in the same transaction: the actor and any impersonator, an
  optional reason, the values before and after, and the database's time
  (`list_settings_changes/2`, `list_tax_code_changes/2`). A call that changes
  nothing records nothing.
- **Completeness and numbering.** Posted documents and payments carry
  gapless per-company numbers assigned by the database, and a party's
  document number is recorded once, so a bill is neither lost nor paid twice.
- **Retention.** Nothing is deleted: a mistaken draft is voided with a reason
  and kept, and the database refuses DELETE and TRUNCATE. How long records
  must be kept is law, not code.
- **Reproducible reports.** Aged payables as of any date reproduce exactly
  from their `through_entry_number`, and reconcile to the payable accounts:
  a bill owed less than nothing is listed as an exception, never dropped.
- **Settlement of recorded documents.** A bill and a debit note keep the
  payable account they posted to, and payments and debit notes settle that
  account even if it is no longer the setting. The ledger refuses to
  deactivate an account whose debits and credits differ, so an open bill's
  payable account stays active while it holds a balance.

Tax rules, a chart of accounts, payment terms, and currencies are a company's
configuration and data; the code ships none.

## Tests

Module tests run on temporary copies of the tables built from the
migrations' own statements (`test/support/test_fixtures.ex`), plus the
ledger's from its fixtures. `test/support/payables_case.ex` builds a company
with an open book, the accounts a test posts to, payables settings, and one
tax code. The match is proved against `test/support/stub_order_source.ex`,
since a module test runs without Supply Chain; `web_test/` runs the pages
against the Web host, and its last test matches a bill against a real order
and receipt when Supply Chain is mounted, or proves the source unavailable
when it is not.

The module has no agent operations; callers use the facade.
