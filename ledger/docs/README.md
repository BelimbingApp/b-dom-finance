# Ledger

Module ID: `finance/ledger`. A company's general ledger: its book, chart of
accounts, journal entries, period closing, and trial balance. Other Finance
modules and other Domains post through this module's facade; none of them
reads its tables.

## Public API

Call `Bilimbi.Finance.Ledger` with a validated `Bilimbi.Base.Tenancy.Scope`
and an explicit company ID. Results are plain maps; the schemas are private.

| Function | Capability | Does |
| --- | --- | --- |
| `get_book/2` | `finance.ledger.view` | The company's currency code and minor units |
| `open_book/3` | `finance.ledger.accounts.manage` | Opens the book once with `currency_code` and `minor_units` |
| `list_accounts/2` | `finance.ledger.view` | The chart of accounts by code |
| `create_account/3` | `finance.ledger.accounts.manage` | Adds an account: `code`, `name`, `account_type`, optional `parent_id`, `active`, `retained_earnings` |
| `update_account/4` | `finance.ledger.accounts.manage` | Changes `name`, `parent_id`, `active`, or `retained_earnings` |
| `post_entry/3,4` | `finance.ledger.entries.post` | Posts a balanced entry: `entry_date`, `description`, optional `reference`, `lines`; option `settlement_account_ids` lists accounts that may be inactive in this entry |
| `reverse_entry/4` | `finance.ledger.entries.post` | Posts a posted entry's mirror image on `entry_date` with `description` |
| `get_entry/3`, `list_entries/3` | `finance.ledger.view` | Posted entries with their lines; `list_entries/3` takes `from`, `to`, `limit`, and `after` |
| `trial_balance/4` | `finance.ledger.view` | Per-account totals and balances as of a date, optionally `through_entry_number` |
| `open_fiscal_year/3` | `finance.ledger.periods.manage` | Opens the next fiscal year, `start_date` and `end_date`, as monthly periods |
| `list_fiscal_years/2`, `get_fiscal_year/3` | `finance.ledger.view` | Fiscal years with their status, closing entry, and periods |
| `list_closing_events/3` | `finance.ledger.view` | A fiscal year's closing log, oldest first |
| `close_period/4` | `finance.ledger.periods.manage` | Closes an open period, optional `reason` |
| `reopen_period/4` | `finance.ledger.periods.reopen` | Reopens a closed period with a `reason` |
| `lock_period/4` | `finance.ledger.periods.lock` | Locks a closed period for good, optional `reason` |
| `close_fiscal_year/4` | `finance.ledger.periods.manage` and `finance.ledger.entries.post` | Posts the closing entry into retained earnings and closes the year; idempotent |
| `reopen_fiscal_year/4` | `finance.ledger.periods.reopen` and `finance.ledger.entries.post` | Reopens a closed year with a `reason`, reversing its closing entry |

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
deactivated while an entry posts to it, and a period from closing while an
entry posts into it. Ledger figures are financial facts, so reads need
`finance.ledger.view`; the Tenant Owner role holds all six capabilities.
Closing, reopening, and locking are separate capabilities, so a company can
let one person close periods and keep reopening and locking with another.
Closing and reopening a fiscal year also post an entry, so each needs the
posting capability `finance.ledger.entries.post` as well; a caller missing
either capability is `{:error, :unauthorized}` and nothing is posted.

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
but its history stays and reversals of entries that used it still post, as do
settlement entries that name it (see Journal entries). An
account can be deactivated only once its balance (its posted debits less its
credits) is zero; otherwise `update_account/4` returns a changeset whose
`active` error names the account and its balance, so an account that still
holds a balance, such as receivables an invoice still owes, cannot be left
where nothing can be posted against it. The code ships no account list; a
company's chart is its own data.

`retained_earnings: true` designates the one equity account the year-end
close moves profit into. Which account that is, like its code and name, is
the company's choice; designating another account moves the designation.

## Journal entries

`post_entry/3,4` stores an entry only when it has at least two lines, each line
names an active account of the company with exactly one positive amount, and
debits equal credits (the one exception is the settlement exception below); otherwise it returns a changeset whose `lines` errors
say why, per line where one line is at fault. Its `entry_date` must fall in
an open period (see Period closing); otherwise the changeset's `entry_date`
error says the period is closed or locked, or that the date is before the
company's first fiscal year. A posted entry and its lines are
immutable. `reverse_entry/4` corrects one by posting the same lines with
debits and credits swapped, on a date not before the original's; an entry is
reversed at most once and a reversal is not itself reversed, so a correction
is a reversal plus a new entry. A reversal is dated into an open period like
any entry, and a year-end closing entry is reversed only by reopening its
year (`{:error, :closing_entry}`). `get_entry/3` shows `reversed_by_entry_id`
on a reversed entry. There are no draft entries in this slice.

**Settlement exception.** An inactive account blocks new business, not the
settlement of what was posted before it was deactivated. `post_entry/4` takes
the option `settlement_account_ids`, a list of account IDs that may be
inactive in that one entry, for a module that settles a document it posted
earlier (receivables does so for a payment or a credit note against an
invoice whose receivable account has since been deactivated). It is not a
general bypass: each listed account must still be an account of the company,
every other line still needs an active account, and any other option, or a
list of anything but integers, is `{:error, :invalid_option}`. Reversals
already post into inactive accounts.

Each entry has an `entry_number`, its book's sequence number: the database
numbers a company's entries 1, 2, 3, ... in posting order, so a number is never
skipped (a refused or rolled-back post takes none) or reused.

`list_entries/3` orders entries by date and then ID. `limit` is an integer
from 1 to 500 (default 100). To page past it, pass `after:
{entry_date, id}` from the last entry returned, and stop when fewer than
`limit` entries come back. A `limit`, `from`, `to`, or `after` of the wrong
shape or range, including an `after` ID beyond PostgreSQL's `bigint`, is
`{:error, :invalid_option}`.

## Trial balance

`trial_balance/4` lists every account with a posting dated on or before
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
now. A `through_entry_number` outside 0 to the `bigint` maximum is
`{:error, :invalid_option}`. Once a period closes, no entry is dated into it
or before it, so a trial balance as of a closed period's end stays the same
without `through_entry_number`.

## Period closing

Closing lives in the ledger rather than a sibling module because the database
must refuse a posting into a closed period: the rule is a trigger on the
entries table, which only its owner may define, and the facade checks it
inside the same company lock that posts.

`open_fiscal_year/3` opens a company's next fiscal year and divides it into
calendar-month periods. The first year starts on the first day of any month
the company chooses; each later year starts the day after the previous one
ends, and that is its default. `end_date`, the last day of a month, defaults
to twelve months on; a year runs one to 24 months, so a short first year or a
long transitional one fits. A year's periods are fixed once it is open.
Fiscal years are optional, but once a company has one, no entry is dated
before its first year; an entry after its last year posts, so a company opens
the next year before closing into it.

A period is `open`, `closed`, or `locked`, and a year `open` or `closed`.
Neither status is stored: each is the latest event in the company's closing
log, which is append-only. Every close, reopen, and lock is an event with
its `reason`, `recorded_by_user_id` (and `recorded_by_impersonator_id`),
a database-stamped `recorded_at`, and an `event_number` the database assigns
1, 2, 3, ... per company. `list_closing_events/3` returns a year's log.

| Call | Needs | Refused with |
| --- | --- | --- |
| `close_period/4` | an open period whose previous period is not open | `:period_not_open`, `:earlier_period_open`, `:closes_with_fiscal_year` for a year's last period |
| `reopen_period/4` | a closed period whose next period is open, in an open year, and a `reason` | `:period_locked`, `:period_not_closed`, `:fiscal_year_closed`, `:later_period_closed`, a changeset |
| `lock_period/4` | a closed period whose previous period is locked | `:period_locked`, `:period_not_closed`, `:earlier_period_unlocked` |

So periods close and lock in date order and reopen in reverse: a closed
period's figures never change under a later one, and only the privileged
reopen capability, with a recorded reason, opens one again. A locked period
never reopens.

## Year-end close

`close_fiscal_year/4` posts the year's closing entry and closes the year in
one transaction. The entry is dated the year's last day, with an optional
`description` and `reference`, and has one line per income and expense
account with a balance for the year, bringing it to zero, and one line for
the difference, the profit (a credit) or loss (a debit), on the designated
retained-earnings account. It is an ordinary posted entry with its own entry
number, actor, and time. The close then records the year's `close` event,
which names the entry and the retained-earnings account, and closes every
period of the year still open; the year's last period closes only this way,
so it stays open for year-end adjustments until the close. A year with no
income or expense balance closes with no entry. The previous year must be
closed first (`:earlier_period_open`), and an active retained-earnings
account must be designated (`:no_retained_earnings_account`). Closing needs
the posting capability as well as the period-management one, since it posts
the closing entry.

The close is idempotent: closing a closed year returns it unchanged and posts
nothing. Only `reopen_fiscal_year/4` undoes it, with the reopen and posting
capabilities and a `reason`: it records the year's and its last period's
`reopen` events and posts the closing entry's reversal on the year's last
day. The year's other periods stay closed until each is reopened. A year whose last period is
locked never reopens (`:period_locked`), nor one whose next year has a closed
period (`:later_period_closed`). Closing it again posts a fresh closing entry
over the year's entries, in which the earlier closing entry and its reversal
cancel.

The new year needs no opening entry: its opening balances follow from the
ledger. `trial_balance/4` as of the closed year's last day shows every income
and expense account at zero and the year's result in retained earnings,
alongside the balance-sheet accounts the new year carries forward.

## Database

The migration `20261012170100` is `:bilimbi_only` and creates
`finance_ledger_books`, `finance_ledger_accounts`, `finance_ledger_entries`,
and `finance_ledger_entry_lines`. The migration `20261013101700`, also
`:bilimbi_only`, adds `finance_ledger_fiscal_years`, `finance_ledger_periods`,
`finance_ledger_closing_events`, and accounts' `retained_earnings` flag.
PostgreSQL enforces the rules the facade checks, so no other writer can break
them:

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
  index refuses a reused number;
- a trigger refuses an entry dated in a closed or locked period, or before
  the company's first fiscal year, and holds a share lock on the period until
  the posting commits, so a period cannot close under it;
- fiscal years, periods, and closing events are append-only; a year starts
  the day after the previous one ends, its periods are added in its own
  transaction one month at a time, and a deferred trigger refuses a commit in
  which they do not reach the year's end;
- a trigger numbers each company's closing events without gaps, stamps
  `recorded_at`, and refuses an event that breaks the rules in Period closing
  and Year-end close; checks require a reopen's reason and keep the closing
  entry and retained-earnings account to a year's close; a deferred trigger
  refuses a commit that leaves a closed year with an open period;
- a check keeps the retained-earnings designation to equity accounts and a
  partial unique index to one per company.

`Bilimbi.Finance.Ledger.SchemaContract` describes the tables but is not
registered in the descriptor: compatibility verification runs before pending
Bilimbi-only migrations, when these tables correctly do not exist.
`test/schema_contract_test.exs` runs the migrations in a fresh database,
verifies the contract with `Bilimbi.Base.Database.SchemaVerifier.verify/2`, and
proves the migrations' own triggers outside the test sandbox.

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
  `through_entry_number`. Every period and year close, reopen, and lock is an
  append-only, gaplessly numbered closing event with its actor, time, and
  reason, and a status is always the latest event's, so the log is the whole
  history.
- **Period-end cut-off.** Once a period closes, PostgreSQL refuses any entry
  dated in it or before it, so a closed period's figures, and every report as
  of its end, stay as they were reported. Reopening needs a separate
  privileged capability and a recorded reason; locking is permanent, for
  periods whose figures have been filed or audited. Closing, reopening, and
  locking are separate capabilities, so they can be held by different people.
- **Year-end close.** Income and expense accounts are closed into the
  company's designated retained-earnings account by an ordinary posted entry,
  so the transfer is itself on the audit trail; it is never repeated, and is
  undone only by reopening the year, which reverses it. Opening balances
  carry forward by construction rather than by a separate entry that could
  disagree with the ledger.
- **Retention.** Nothing posted is ever deleted: the database refuses DELETE
  and TRUNCATE on books, entries, lines, fiscal years, periods, and closing
  events, refuses deleting an account, and unmounting Finance keeps every
  row. Records therefore outlive any statutory retention period, such as the seven years Malaysia's Companies Act 2016
  requires; how long a company must keep them is law, not code.

Financial reporting under MFRS or IFRS (statements, tax) is later work in
sibling modules.

## Tests

Module tests run on temporary copies of the tables, constraints and triggers
included, from `test/support/test_fixtures.ex`; change them with the
migrations. The closing rules' functions are not copied: the closing
migration's `functions/1` creates the same ones in `pg_temp`. `setup_ledger!/0`
there builds two tenants' companies and an Authz snapshot, and `sign_in!/4`
signs a user in with direct grants.

This slice has no pages, menu entries, or agent operations; callers use the
facade.
