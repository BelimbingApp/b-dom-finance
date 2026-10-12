# Ledger

Module ID: `finance/ledger`. A company's general ledger: its book, chart of
accounts, journal entries, and trial balance. Other Finance modules and other
Domains post through this module's facade; none of them reads its tables.

## Public API

Call `Bilimbi.Finance.Ledger` with a validated `Bilimbi.Base.Tenancy.Scope`
and an explicit company ID. Results are plain maps; the schemas are private.

| Function | Capability | Does |
| --- | --- | --- |
| `get_book/2` | `finance.ledger.view` | The company's currency code and minor units |
| `open_book/3` | `finance.ledger.accounts.manage` | Opens the book once with `currency_code` and `minor_units` |
| `list_accounts/2` | `finance.ledger.view` | The chart of accounts by code |
| `create_account/3` | `finance.ledger.accounts.manage` | Adds an account: `code`, `name`, `account_type`, optional `parent_id`, `active` |
| `update_account/4` | `finance.ledger.accounts.manage` | Changes `name`, `parent_id`, or `active` |
| `post_entry/3` | `finance.ledger.entries.post` | Posts a balanced entry: `entry_date`, `description`, optional `reference`, `lines` |
| `reverse_entry/4` | `finance.ledger.entries.post` | Posts a posted entry's mirror image on `entry_date` with `description` |
| `get_entry/3`, `list_entries/3` | `finance.ledger.view` | Posted entries with their lines; `list_entries/3` takes `from`, `to`, `limit`, and `after` |
| `trial_balance/4` | `finance.ledger.view` | Per-account totals and balances as of a date, optionally `through_entry_number` |

## Authorization and company scope

Every call authorizes its capability for the scope's signed-in actor and the
target company when it runs, through
`Bilimbi.Core.Company.authorize_company_target/3`: the actor's own company,
or a sibling company with Core Company's tenant-wide reach. A system scope
names nobody and is `{:error, :unauthorized}`; a company the scope's tenant
cannot see is `{:error, :company_not_found}`. Writes then take
`Bilimbi.Core.Company.lock_writable_company/2` inside their transaction, so an
archived company is `{:error, :company_archived}` and one company's ledger
writes run one at a time; that lock is also what keeps an account from being
deactivated while an entry posts to it. Ledger figures are financial facts, so
reads need `finance.ledger.view`; the Tenant Owner role holds all three
capabilities.

An entry records who posted it: `posted_by_user_id` from `Scope.actor/1`, and
`posted_by_impersonator_id` for an impersonated session; the database stamps
`posted_at`. Posting therefore needs a signed-in person; a system principal
posting for another module (for example payroll) is not supported yet and
needs its own decision.

## Money

Amounts are decimals (`numeric(20, 4)`, Ecto `:decimal`) in the currency of
the company's book, the way People Claims and Payroll and Factory Inventory
store money: a decimal amount beside an explicit ISO 4217-shaped currency
code (`^[A-Z]{3}$`). Decimal keeps sums exact in PostgreSQL and lets those
modules post their decimal amounts without converting to integer minor units.

The book records the currency code and its `minor_units` (0 to 4 decimal
places, which covers every ISO 4217 currency). An amount finer than the book's
minor units is refused, not rounded. Both are fixed once the book opens,
because every posted amount is denominated in them; they are not a Base
Setting for that reason. Every entry carries the book's currency, and a
composite foreign key to the book refuses any other. Conversion between
currencies is out of scope.

## Chart of accounts

An account has a code unique in the company, a name, one of five types
(`asset`, `liability`, `equity`, `income`, `expense`; `account_types/0`), an
optional parent of the same type in the same company for grouping, and an
active flag. Code and type never change once created, and an account is never
deleted: deactivate it instead. A deactivated account takes no new postings,
but its history stays and reversals of entries that used it still post. The
code ships no account list; a company's chart is its own data.

## Journal entries

`post_entry/3` stores an entry only when it has at least two lines, each line
names an active account of the company with exactly one positive amount, and
debits equal credits; otherwise it returns a changeset whose `lines` errors
say why, per line where one line is at fault. A posted entry and its lines are
immutable. `reverse_entry/4` corrects one by posting the same lines with
debits and credits swapped, on a date not before the original's; an entry is
reversed at most once and a reversal is not itself reversed, so a correction
is a reversal plus a new entry. `get_entry/3` shows `reversed_by_entry_id` on
a reversed entry. There are no draft entries in this slice.

Each entry has an `entry_number`, its book's sequence number: the database
numbers a company's entries 1, 2, 3, ... in posting order, so a number is never
skipped (a refused or rolled-back post takes none) or reused.

`list_entries/3` orders entries by date and then ID. `limit` is a positive
integer (default 100, at most 500). To page past it, pass `after:
{entry_date, id}` from the last entry returned, and stop when fewer than
`limit` entries come back. A `limit`, `from`, `to`, or `after` of the wrong
shape is `{:error, :invalid_option}`.

## Trial balance

`trial_balance/3` lists every account with a posting dated on or before
`as_of`, ordered by code, with its debit and credit totals and its balance on
one side (`debit_balance` or `credit_balance`). Each account reports its own
postings only; `parent_id` lets a reader group rows without counting a parent
twice. `total_debit` equals `total_credit` because every entry balances.

The result names `through_entry_number`, the last entry it counts. An entry
posted later with an earlier date changes the figures for that date, so a
report's debit and credit figures (each row's totals and balance, and the
totals) reproduce exactly by passing the same `as_of` and its
`through_entry_number`: posted entries never change and are numbered in
posting order. Account names, parents, and active flags are read as they are
now. Closing a period against back-dated postings is
later work.

## Database

The migration `20261012170100` is `:bilimbi_only` and creates
`finance_ledger_books`, `finance_ledger_accounts`, `finance_ledger_entries`,
and `finance_ledger_entry_lines`. PostgreSQL enforces the rules the facade
checks, so no other writer can break them:

- composite `(id, company_id)` foreign keys keep a line's entry and account,
  an account's parent, and a reversal's original in one company;
- a check keeps each line to one positive side, and a deferred constraint
  trigger refuses a commit in which an entry has no lines or does not balance;
- triggers refuse UPDATE, DELETE, and TRUNCATE on books, entries, and lines,
  and refuse deleting an account or changing its company, code, or type;
- a trigger refuses a line whose entry was inserted in an earlier transaction,
  so a posted entry's lines stay fixed;
- a partial unique index allows one reversal per entry;
- a trigger numbers each company's entries without gaps and stamps
  `posted_at`, replacing whatever the inserting writer sent, and a unique
  index refuses a reused number.

`Bilimbi.Finance.Ledger.SchemaContract` describes the tables but is not
registered in the descriptor: compatibility verification runs before pending
Bilimbi-only migrations, when these tables correctly do not exist.
`test/schema_contract_test.exs` runs the migration in a fresh database,
verifies the contract with `Bilimbi.Base.Database.SchemaVerifier.verify/2`, and
proves the migration's own triggers outside the test sandbox.

## Standards addressed

The ledger is built to the bookkeeping and audit standards a company's
accounts are held to. What this slice covers:

- **Double-entry integrity.** Every entry balances, debits against credits,
  in one currency per book; each line has one positive side; an entry and
  its lines are fixed once posted. The facade and PostgreSQL both enforce
  this (see Database).
- **Audit trail.** Every entry records who posted it (and any impersonator),
  when the database recorded it, and its gapless book sequence number. A
  correction is a reversing entry that names the original, and the original
  reports the entry that reversed it, so the trail runs both ways and nothing
  is overwritten. Opening a book and every account change are Repo writes,
  which Base Audit records with their actor in the composed host (ADR 0013).
  Any past trial balance's debit and credit figures reproduce exactly from its
  `through_entry_number`.
- **Retention.** Nothing posted is ever deleted: the database refuses DELETE
  and TRUNCATE on books, entries, and lines, refuses deleting an account, and
  unmounting Finance keeps every row. Records therefore outlive any statutory
  retention period, such as the seven years Malaysia's Companies Act 2016
  requires; how long a company must keep them is law, not code.

Financial reporting under MFRS or IFRS (statements, period close, tax) is
later work in sibling modules.

## Tests

Module tests run on temporary copies of the tables, constraints and triggers
included, from `test/support/test_fixtures.ex`; change them with the
migration. `setup_ledger!/0` there builds two tenants' companies and an Authz
snapshot, and `sign_in!/4` signs a user in with direct grants.

This slice has no pages, menu entries, or agent operations; callers use the
facade.
