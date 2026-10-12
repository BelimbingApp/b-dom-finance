# Payables

Module ID: `finance/payables`. A company's accounts payable: documents from
parties (bills, and the debit notes that correct them), payments allocated to
bills, and what is owed to whom as of any date. It posts to the ledger only
through `Bilimbi.Finance.Ledger`'s facade and never reads the ledger's
tables; other modules call this module's facade and never read its tables.

## Public API

Call `Bilimbi.Finance.Payables` with a validated `Bilimbi.Base.Tenancy.Scope`
and an explicit company ID. Results are plain maps; the schemas are private.

| Function | Capability | Does |
| --- | --- | --- |
| `get_settings/2` | `finance.payables.view` | The company's payable account |
| `put_settings/3` | `finance.payables.settings.manage` | Sets `payable_account_id`, an active liability account, with an optional `reason` |
| `list_settings_changes/2`, `list_tax_code_changes/2` | `finance.payables.view` | The history of changes to the payable account and to tax codes: who, why, when, and the values before and after |
| `list_tax_codes/2` | `finance.payables.view` | The company's tax codes by code |
| `create_tax_code/3`, `update_tax_code/4` | `finance.payables.settings.manage` | A tax code: `code`, `name`, `rate` (percent), `account_id`, `active`, and an optional `reason`; the code never changes |
| `create_bill/3` | `finance.payables.documents.create` | Records a party's bill as a draft |
| `create_debit_note/4` | `finance.payables.documents.create` | Records a debit note against a posted bill as a draft |
| `approve_document/3` | `finance.payables.documents.approve` | Approves a draft |
| `void_document/4` | `finance.payables.documents.approve` | Voids a draft or approved document with a `void_reason` |
| `post_document/3` | `finance.payables.documents.post` | Posts an approved document to the ledger and numbers it |
| `get_document/3`, `list_documents/3` | `finance.payables.view` | Documents with lines, tax lines, and `debit_note_ids`; a posted bill shows `outstanding` |
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
capability. Recording, approving, and posting are separate capabilities, so a
company can give them to different people; requiring that a document's
approver differ from its recorder is later work.

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
net of tax, an optional `tax_code_id`, and an optional
`external_order_line_id`. Each tax code the lines use becomes one tax line:
the lines' total for that code (`taxable_amount`) and its `tax_amount` at the
code's rate, rounded half up to the book's minor units, unless `tax_lines`
states the party's own figure for that code. A tax line copies its code,
rate, and account, so later changes to the tax code leave recorded documents
alone. A document's `total_net`, `total_tax`, and `total` are its lines'.

Documents move one way:

```text
draft --approve--> approved --post--> posted
  \                    \
   `------void----------`--> voided
```

A document is recorded whole: nothing is added to its lines afterwards and
nothing it recorded changes, only its status. Posting (`post_document/3`)
posts one ledger entry on the document date: a bill debits each line's
account and each tax line's account and credits the payable account from
the settings with its total; a debit note posts the opposite, to the payable
account its bill posted to, whatever the settings say by then. The document
keeps its `payable_account_id`, `entry_id`, and `entry_number`. A posted
document is never changed or voided: a bill is corrected by a debit note,
whose total cannot exceed what is still owed on the bill, checked when it is
recorded and again when it posts, both now and as of the debit note's date
(see Aged payables).

Posted documents are numbered per company and document type, 1, 2, 3, ... in
posting order, by the database: drafts and voided documents take no number,
and a refused or rolled-back post takes none, so a number is never skipped or
reused.

`list_documents/3` takes `document_type`, `status`, `party_key`, `from`,
`to`, `limit`, and `after` (`{document_date, id}`), and pages as the
ledger's `list_entries/3` does.

## Payments

`post_payment/3` posts a payment to one party on `payment_date` from
`paid_from_account_id` (an active asset or liability account, such as a bank
account), with optional `reference` and `description`, and `allocations`,
each `%{document_id, amount}` naming a posted bill of that party dated on or
before the payment. Its amount is the allocations' total; an allocation
cannot exceed what is still owed on its bill, now and as of `payment_date`,
so a bill is paid in one or more parts. The ledger entry debits each paid bill's own payable account and
credits the paid-from account. Payments are numbered per company like
documents. Paying ahead of a bill, and refunds from a party, are later work.

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

A bill is never owed less than nothing: a debit note or payment is refused
(`:exceeds_outstanding`, or an allocation error) if it would take a bill below
nothing either now or as of its own date. The date check matters because a
payment later reversed still counts on the dates before its reversal. Dated
postings can still leave a bill negative on some date between those two, so
the report never drops one silently: `exceptions` lists each bill owed less
than nothing as of `as_of` (with a negative `outstanding`), outside the parties
and buckets, and `exceptions_total` is their sum. `total + exceptions_total`
is what the payable accounts hold for these bills as of the date, which is
what the ledger's trial balance shows for them.

## Seams for later work

- **Purchase-order match.** A line's `external_order_line_id` holds the
  caller's own ID for an order line. This module stores it and never
  interprets it; a later matching module reads it from `get_document/3`.
- **Self-billed e-invoices.** A posted bill carries its party snapshot
  (including tax and registration identifiers), its lines and tax lines, and
  its posting, which is what a later e-invoice module needs to issue a
  self-billed e-invoice for it through this facade. This module depends on no
  e-invoice module.

## Database

The migration `20261012213700` is `:bilimbi_only` and creates
`finance_payables_settings`, `finance_payables_tax_codes`,
`finance_payables_settings_changes`, `finance_payables_tax_code_changes`,
`finance_payables_documents`, `finance_payables_document_lines`,
`finance_payables_document_tax_lines`, `finance_payables_payments`, and
`finance_payables_payment_allocations`. Its `statements/1` is the schema's
one source: the migration runs it, and module tests run it with
`temporary: true`. PostgreSQL enforces the rules the facade checks, so no
other writer can break them:

- composite `(id, company_id)` foreign keys keep a line's document and tax
  code, a debit note's bill, an allocation's payment and document, and a
  reversal's original in one company; ledger account and entry IDs are plain
  columns, since the ledger's tables are another module's;
- checks keep each status's actor and time columns consistent, amounts
  positive, totals summed, and a bill's party document number present; a
  deferred constraint trigger refuses a commit in which a document has no
  lines, its totals differ from its lines, or its tax lines differ from them;
- a trigger records a document only as a draft, lets it move only draft to
  approved to posted or to voided before posting, refuses any change to what
  it recorded, stamps each step's time, and numbers it on posting; a unique
  index refuses a reused number and a partial unique index a party document
  number recorded twice;
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
  allocations, and the two change histories, DELETE on settings, tax codes,
  and documents, TRUNCATE on all nine tables, and a change to a tax code's
  code or any row's company.

`Bilimbi.Finance.Payables.SchemaContract` describes the tables but is not
registered in the descriptor, for the reason the ledger gives.
`test/schema_contract_test.exs` runs the migration in a fresh database,
verifies the contract, and proves the triggers that only a commit or a later
transaction shows.

## Standards addressed

What this slice covers of the bookkeeping and audit standards a company's
payables are held to:

- **Double entry through the ledger.** Every posted document and payment is
  one balanced ledger entry posted through the ledger's facade, which keeps
  its own integrity rules; the payables record keeps that entry's ID and
  number, so each posting traces both ways.
- **Authorization and segregation.** Recording, approving, posting, and
  paying are separate capabilities, checked when each call runs; nothing
  posts without an approval on record.
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
migration's own statements (`test/support/test_fixtures.ex`), plus the
ledger's from its fixtures. `test/support/payables_case.ex` builds a company
with an open book, the accounts a test posts to, payables settings, and one
tax code.

This slice has no pages, menu entries, or agent operations, like the ledger;
callers use the facade.
