# Receivables

Module ID: `finance/receivables`. What a company's customers owe it: its
customers, the invoices and credit notes it issues them, the payments it
receives, and aged receivables. Every amount it records is posted through
the `finance/ledger` facade; it never reads or writes the ledger's tables.

## Public API

Call `Bilimbi.Finance.Receivables` with a validated
`Bilimbi.Base.Tenancy.Scope` and an explicit company ID. Results are plain
maps; the schemas are private.

| Function | Capability | Does |
| --- | --- | --- |
| `get_setup/2` | `finance.receivables.view` | The receivable account and default income account |
| `configure/3` | `finance.receivables.setup.manage` | Sets `receivable_account_id` (asset) and `income_account_id` (income); each account set or changed is logged |
| `list_setup_changes/3` | view | The setup's append-only history: field, old and new value, who, when |
| `list_series/2`, `create_series/3`, `update_series/4` | view; `setup.manage` | Numbering series: `code`, `name`, `kind`, `prefix`, `number_width`, `active` |
| `list_tax_codes/2`, `create_tax_code/3`, `update_tax_code/4` | view; `setup.manage` | Tax codes: `code`, `name`, `rate` (percent), `account_id` (liability), `active` |
| `list_customers/2`, `get_customer/3`, `create_customer/3`, `update_customer/4` | view; `customers.manage` | Customers and their party fields |
| `create_draft/3`, `update_draft/4`, `discard_draft/3` | `finance.receivables.documents.manage` | Draft invoices and credit notes with their lines |
| `issue_document/3` | `finance.receivables.documents.issue` | Numbers, freezes, and posts a draft |
| `get_document/3`, `list_documents/3`, `list_issued_documents/3` | view | Documents with lines, tax lines, and what an invoice still owes |
| `record_payment/3`, `reverse_payment/4` | `finance.receivables.payments.post` | Payments received, allocated to invoices, and their reversal |
| `get_payment/3`, `list_payments/3` | view | Payments with their allocations and reversal |
| `aged_receivables/4` | view | What each customer owes as of a date, by days past due |

The Tenant Owner role holds every receivables capability.

## Authorization and company scope

Authorization is the ledger's, unchanged: every call authorizes its
capability for the scope's signed-in actor and the target company through
`Bilimbi.Core.Company.authorize_company_target/3`, and every write takes
`Bilimbi.Core.Company.lock_writable_company/2` inside its transaction, so an
archived company is `{:error, :company_archived}` and one company's
receivables and ledger writes run one at a time. A system scope is
`{:error, :unauthorized}`; a company the scope cannot see is
`{:error, :company_not_found}`.

Receivables calls the ledger facade with the same scope, inside the same
transaction, so the ledger authorizes its own part: drafting, configuring,
and aging read the book or chart and need `finance.ledger.view`; issuing,
recording, and reversing a payment post an entry and need
`finance.ledger.entries.post`. A ledger refusal, such as
`{:error, :book_not_open}`, is returned unchanged and rolls the whole write
back. Before the setup exists, a document or payment write is
`{:error, :not_configured}`.

## Configuration

Nothing about a company's tax regime, chart, numbering, or currency is in
code; each is the company's data:

- **Setup.** The receivable control account (an asset) and the income
  account a line posts to when it names none. Changing either affects only
  documents and lines made afterwards (see Payments), and every account set
  or changed is kept in an append-only history with who changed it and when
  (`list_setup_changes/3`).
- **Series.** Each numbers one kind of record: `invoice`, `credit_note`, or
  `payment` (`series_kinds/0`). Its reference for a number is its `prefix`
  and the number zero-padded to `number_width` digits (`"INV-"` and 4 give
  `"INV-0042"`). Prefixes are unique within the company, so references never
  collide. Code, kind, prefix, and width never change; a series is
  deactivated, never deleted.
- **Tax codes.** A `code`, a `rate` as a percentage (up to four decimal
  places), and the liability account the tax posts to. Code and rate never
  change, because documents record both; a new rate is a new tax code.
- **Customers.** A `code`, a `name`, optional tax and registration
  identifiers, contact fields, an address in Core Address's field names
  (`line1` to `line3`, `locality`, `postcode`, `admin1_code`,
  `country_iso`), and `payment_terms_days`. A customer is deactivated, never
  deleted; an inactive customer takes no new invoice, but its existing invoices
  can still be paid, credited, and have their payments reversed.

## Documents

A document is an invoice or a credit note (`document_kinds/0`). It starts as
a draft that can be changed or discarded freely. Each line has a
description, a quantity and unit price (up to four decimal places), an
income account, and an optional tax code. Its amount is quantity times unit
price, and its tax is the tax code's rate of that amount, each rounded half
up to the book's minor units; the document's tax lines sum its lines per
tax code, and its total is the subtotal plus tax. A discarded draft is kept,
unnumbered, with who discarded it and when.

`issue_document/3` checks the draft as it stands (an issue date, at least
one line, a total above zero, an active series and (for an invoice) customer, active ledger
accounts of the right types, except that a credit note's receivable account
is its invoice's and may be inactive: it settles that invoice) and then, in one transaction:

1. numbers it next in its series and gives it the series' reference;
2. copies the customer's party fields onto it, so the document keeps the
   party as it was even when the customer changes later;
3. sets an invoice's due date from the customer's payment terms when the
   draft names none;
4. posts its entry through `Bilimbi.Finance.Ledger.post_entry/4`: an invoice
   debits the receivable account with its total and credits each income
   account and each tax code's account; a credit note posts the reverse;
5. records the entry's ID and number and who issued it; the database stamps
   when.

An issued document never changes. An invoice is corrected by a credit note,
which names an issued invoice of the same customer, is dated no earlier
than it, and credits no more than it still owes; an invoice that must be
replaced is credited in full and issued anew. Credit notes are not aged
themselves; they reduce the invoice they credit.

`get_document/3` and the lists show an issued invoice's `outstanding`: its
total less its issued credit notes and its allocations from payments that
were not reversed.

## Payments

`record_payment/3` records money received from one customer into a deposit
account (an asset), allocated to one or more of that customer's issued
invoices. The allocations add up to the payment, each invoice appears once,
each is dated on or before the payment, none is allocated more than it
owes, and each one's recorded receivable account is an asset account
(otherwise the allocation's error names the invoice), so an invoice can be
settled in part and by several payments. The payment is numbered next in its payment series and posted through the
ledger, debiting the deposit account the whole amount and crediting each
allocated invoice's receivable account with the amount allocated to it.

The receivable account is recorded, not looked up: an issued invoice
records the setup's receivable account (`receivable_account_id`), a credit
note the account of the invoice it credits, and a payment, its allocations,
and its reversal post to the account of each invoice they settle. Changing
the setup's account later therefore only affects new invoices, and each
receivable account's ledger balance stays what its own documents owe. The
line income accounts, tax line accounts, and a payment's deposit account are
recorded on their own rows in the same way.

An inactive account or customer blocks new business, never the settlement of
an existing document: a payment, a credit note, and a payment's reversal
against an existing invoice go through for a customer deactivated since. The
ledger refuses to deactivate an account with a balance, and a new invoice needs the setup's receivable account, and every line's income and
tax account, to be active. But a payment, a credit note, and a payment's
reversal against an existing invoice may post to that invoice's recorded
receivable account even when it has been deactivated since (for example
after a reversal reopened an invoice, or a manual ledger entry moved the
balance): a payment and a credit note pass the account to
`Bilimbi.Finance.Ledger.post_entry/4` as a `settlement_account_ids` entry for
that entry only, and a reversal posts through `reverse_entry/4`, which
already takes inactive accounts.

A payment and its allocations never change. `reverse_payment/4` reverses a
mistaken or returned payment once, on a date not before it and for a stated
reason, through `Bilimbi.Finance.Ledger.reverse_entry/4`; from that date its
allocations stop settling the invoices. A corrected payment is recorded
anew.

Unallocated receipts, refunds, and customer credit balances are later
work: a payment settles invoices only.

## Aged receivables

`aged_receivables/4` lists, for each customer, the issued invoices that
still owe something as of a date, with what each owes, its days past due,
and its bucket: not yet due, one bucket per limit in `bucket_days`
(default `[30, 60, 90]`), then older. Customer and report totals sum the
buckets.

Every invoice, credit note, payment, and reversal counts from its own date,
and each posted one ledger entry. The report names `through_entry_number`,
the last entry it counts; passing the same `as_of` and
`through_entry_number` reproduces its figures exactly, the way the ledger's
trial balance does, because those records never change and later ones post
later entry numbers. While the receivable account takes postings only from
this module, the report's total equals that account's balance in
`Bilimbi.Finance.Ledger.trial_balance/4` for the same date and entry
number. Customer codes and names are read as they are now; each row also
carries the party name the invoice was issued to.

## For e-invoicing

This module does not submit documents anywhere and depends on no
e-invoicing module. A module that does, such as one submitting to a tax
authority, depends on `finance/receivables` and follows
`list_issued_documents/3`: issued documents in issue order by the
`ledger_entry_number` each posted, after the last number it handled. Each
result carries everything the document was issued with (party snapshot,
lines, tax codes and rates, totals, currency, reference, dates). An issued
document never changes, so each is read once; a submission's own state
belongs to that module.

## Database

The migration `20261012214517` is `:bilimbi_only` and creates
`finance_receivables_setups`, `_setup_changes`, `_series`, `_tax_codes`, `_customers`,
`_documents`, `_document_lines`, `_document_tax_lines`, `_payments`,
`_allocations`, and `_payment_reversals`. Ledger accounts and entries are
named by ID without a foreign key: those tables are the ledger's.
PostgreSQL enforces the rules the facade checks, so no other writer can
break them:

- composite `(id, company_id)` foreign keys keep every reference within one
  company, and a document's series is one of its own kind;
- a document is inserted as a draft; a trigger refuses any change to an
  issued or discarded document, and any insert, change, or delete of the
  lines or tax lines of a document that is no longer a draft;
- issuing checks that the document number is the next in its series, that
  the header totals equal its lines and tax lines, and, for a credit note,
  that it credits an issued invoice of the same customer by no more than
  the invoice still owes; it stamps `issued_at`, and discarding stamps
  `discarded_at`;
- a payment's number must be the next in a payment series, and the
  database stamps `recorded_at`; an allocation must name an issued invoice
  of the payment's customer; a deferred constraint trigger refuses a commit
  in which a payment's allocations do not equal its amount or leave an
  invoice owing less than nothing;
- an issued document records its receivable account, and a credit note's
  is its invoice's;
- setup changes (the stamped `changed_at` included), payments, allocations,
  and reversals are append-only; one reversal per payment;
- triggers refuse deleting any row (setups, series, tax codes, customers,
  documents) and TRUNCATE of every table, and keep a series' code, kind,
  prefix, and width, a tax code's code and rate, and a customer's code.

`Bilimbi.Finance.Receivables.SchemaContract` describes the tables but is
not registered in the descriptor, for the same reason as the ledger's.
`test/schema_contract_test.exs` runs the migration in a fresh database,
verifies the contract, and proves the migration's triggers outside the test
sandbox.

## Standards addressed

Receivables is built to the bookkeeping and audit standards a company's
sales ledger is held to. What this slice covers:

- **Completeness and integrity of the sales ledger.** Every issued
  invoice, credit note, payment, and payment reversal posts one balanced
  ledger entry in the same transaction as the record itself, so the
  receivable account and the documents cannot drift apart through this
  module, and the aged receivables reconcile to the trial balance. Because
  every document posts, and is settled, against the receivable account it
  recorded, they still reconcile, per account, after the setup's account
  changes, and an invoice stays payable and creditable if that account is
  deactivated later.
- **Sequential numbering.** Invoices, credit notes, and payments are
  numbered per series 1, 2, 3, ... in issue order; the database refuses a
  number that is not the next, a refused issue takes no number, and drafts
  and discarded drafts have none, so a gap in a series means a record is
  missing.
- **Immutability and correction by document.** An issued document, its
  lines, and its tax lines are never changed or deleted; corrections are
  credit notes and payment reversals that name what they correct.
- **Audit trail.** Each issued document records who issued it (and any
  impersonator) and when, its ledger entry, and the party, tax codes, and
  rates as they were when issued; payments and reversals record who and
  when as well, and a reversal records its reason. A change to the setup's
  accounts is logged append-only with who changed it, the old and new
  value, and a database-stamped time. Drafts, setup, series, tax codes, and
  customers change through Repo writes, which Base Audit records with their
  actor in the composed host (ADR 0013).
- **Reproducible reports.** Any past aged-receivables report reproduces
  exactly from its `as_of` and `through_entry_number`.
- **Retention.** Nothing is deleted: the database refuses DELETE and
  TRUNCATE on every receivables table, except deleting a draft's own lines
  and tax lines while it is a draft, and unmounting Finance keeps every row. How long records must
  be kept is law, not code.

Tax rules themselves (which rate applies to what, rounding a tax authority
prescribes beyond half up per line, reporting returns) are a company's
configuration or later modules. Posting directly through the ledger to the
receivable account, or reversing a receivables entry through
`Bilimbi.Finance.Ledger.reverse_entry/4` rather than this module, bypasses
these records; correct receivables only through this facade.

## Tests

Module tests run on temporary copies of the tables, constraints and
triggers included, from `test/support/test_fixtures.ex`; change them with
the migration. `setup_receivables!/0` there builds two tenants' companies,
the ledger's tables from its own fixtures, an open book with a small chart,
and an Authz snapshot; `configure_receivables!/1` adds the setup, series,
tax codes, and customers.

This slice has no pages, menu entries, or agent operations, as the ledger
has none; callers use the facade.
