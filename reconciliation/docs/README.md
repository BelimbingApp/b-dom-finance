# Bank reconciliation

Module ID: `finance/reconciliation`. A company's bank reconciliation: bank
accounts mapped one-to-one to ledger accounts; the bank statements imported
for them, immutable once imported; the matches between statement lines and
the ledger's postings on the account, with the events that make and unmake
them; and the reconciliations of an account as of a statement end date,
which show the statement balance, the book balance, what is unmatched on
each side, and the difference, and are finalised only when the difference is
zero. It reads and posts to the ledger only through `Bilimbi.Finance.Ledger`'s
facade and never reads the ledger's tables; other modules call this module's
facade and never read its tables.

## Public API

Call `Bilimbi.Finance.Reconciliation` with a validated
`Bilimbi.Base.Tenancy.Scope` and an explicit company ID. Results are plain
maps; the schemas are private.

| Function | Capability | Does |
| --- | --- | --- |
| `list_bank_accounts/2`, `get_bank_account/3` | `finance.reconciliation.view` | The company's bank accounts |
| `create_bank_account/3` | `finance.reconciliation.bank-accounts.manage` | Adds one: `name`, `ledger_account_id`, `import_mapping`, optional `charges_account_id`, `interest_account_id`, `match_window_days`, `active`, `reason` |
| `update_bank_account/4` | `finance.reconciliation.bank-accounts.manage` | Changes everything but the ledger account, with an optional `reason` |
| `list_bank_account_changes/4` | `finance.reconciliation.view` | The change log: field, values before and after, actor, reason, time |
| `import_statement/4` | `finance.reconciliation.statements.import` | Imports a CSV file's bytes as a numbered statement with its lines |
| `list_statements/4`, `get_statement/3`, `list_statement_lines/4` | `finance.reconciliation.view` | Statements, one with its lines, and an account's lines |
| `unmatched_items/4` | `finance.reconciliation.view` | Unmatched statement lines and ledger entries, with suggested matches |
| `match/4` | `finance.reconciliation.matches.manage` | Matches one or many statement lines with one or many entries |
| `unmatch/4` | `finance.reconciliation.matches.manage` | Appends an `unmatched` event with its `reason` |
| `list_matches/4`, `get_match/3` | `finance.reconciliation.view` | Matches with their status, lines, entries, and events |
| `preview_reconciliation/5` | `finance.reconciliation.view` | The figures as of an `end_date` against a `statement_balance`, optionally pinned to `through_*` numbers |
| `open_reconciliation/4` | `finance.reconciliation.reconciliations.manage` | Opens a reconciliation: `end_date`, `statement_balance` |
| `finalise_reconciliation/3` | `finance.reconciliation.reconciliations.finalise` | Finalises an open one at zero difference and stores its snapshot, by someone other than whoever opened it while the company separates duties |
| `abandon_reconciliation/4` | `finance.reconciliation.reconciliations.manage` | Abandons an open one with a `reason` |
| `get_reconciliation/3`, `list_reconciliations/3` | `finance.reconciliation.view` | A reconciliation's figures and items; an account's reconciliations |
| `post_statement_line/4` | `finance.reconciliation.statement-lines.post` | Posts an unmatched line as a `charge` or `interest` through the ledger and matches it |
| `reverse_statement_line/4` | `finance.reconciliation.statement-lines.manage` | Unmatches a posted line with a reason and reverses its entry as the owner, in one transaction |

## Authorization and company scope

Every call authorizes its capability for the scope's signed-in actor and the
target company when it runs, through
`Bilimbi.Core.Company.authorize_company_target/3`, exactly as the ledger
does: a system scope is `{:error, :unauthorized}` and a company the scope's
tenant cannot see is `{:error, :company_not_found}`. Writes take
`Bilimbi.Core.Company.lock_writable_company/2` inside their transaction, so
an archived company is `{:error, :company_archived}` and one company's
reconciliation writes run one at a time; that lock is what keeps two people
from matching the same line.

The module declares the verbs `import` and `finalise`; `post` is the
ledger's and `manage` Base's. A call that reads the ledger (the chart when a bank account is
added or changed, the book when a statement imports or a reconciliation
opens, the account's entries when matching or reconciling) also needs
`finance.ledger.view`, and posting or reversing a statement line needs
`finance.ledger.entries.post`, because the ledger authorizes its own calls.
The Tenant Owner role holds every reconciliation capability. Importing,
matching, opening, finalising, and posting are separate capabilities, so a
company can keep finalising with a reviewer. The company's separation of
duties (the ledger's `set_duty_separation/3`, required unless turned off)
holds them apart for each reconciliation too: whoever opened it, or anyone
who impersonated them or whom they impersonated, cannot finalise it
(`{:error, :same_person}`); finalising therefore also asks
`finance.ledger.view` of the ledger's `check_approval/3`. While separation is
off, the finalisation goes ahead and is listed in the ledger's approval
exceptions for independent review. Each page re-asks its event's
capability through `Bilimbi.Base.Authz.LiveAuthorization` before calling the
facade, which asks again.

## Bank accounts

A bank account names an active asset account of the ledger that no other
bank account maps, and keeps it for good: every match and reconciliation
reads that account's postings. It carries the expense account bank charges
post to and the income account interest posts to (each optional until
needed), the window in days a suggested match's dates may differ by (0 to
90, default 5), and its import mapping. Its name, counter accounts, window,
mapping, and active flag change in place, and every change is appended to
`finance_reconciliation_bank_account_changes` with the field, the values
before and after, the actor, the reason, and the database's time. A bank
account is never deleted; deactivate it, and it imports and reconciles no
more.

### Import mapping

The mapping (`Bilimbi.Finance.Reconciliation.Mapping`) says how the bank's
CSV export is read, so a bank's layout is a company's data, never code: the
column separator, how many rows precede the data (the last being the header
row, or none), which columns hold the date, description, optional
reference, either one signed amount column (with which sign means money in)
or a debit column (money out) and a credit column (money in), the optional
running balance, the date format (nine common forms), and the decimal
separator. A column is named by its header text, or by its 1-based
position when the file has no header row. Amounts may carry thousands
separators, parentheses, a leading or trailing minus, or a `CR` or `DR`
marker.

## Statements

`import_statement/4` takes the file's name and bytes (and its content type,
`text/csv` unless given), reads it with the account's mapping, keeps the
file whole as the statement's source document through
`Bilimbi.Finance.Attachments` (`StatementSource`; a records-grade document
retained for the company's retention years after the end of the financial
year the statement ends in, so the import also needs
`finance.attachments.create`), and records one numbered statement with its
lines and the mapping it was read through (`import_mapping`) in one
transaction. Every check below runs before the file is stored (the active
bank account again inside the transaction, under the company lock), and the
store runs before the transaction, as Base Artifacts asks; a refused import
stores nothing, and a storage refusal imports nothing. A statement
line's `amount` is signed from the account holder's side, money in positive
and money out negative, which is the sign of a debit less a credit on the
asset account it is matched against. A row whose amount is zero is skipped
and counted in `skipped_count`.

With a running balance column, each line's balance must be the previous
line's plus its amount; a file written newest first is read in reverse,
and one that chains in neither direction is refused
(`{:running_balance_mismatch, row}`), which catches a mapping whose sign is
wrong. The statement then records its opening and closing balances.
Without one, the lines are kept in file order, oldest first.

The same file is refused a second time by its SHA-256
(`{:duplicate_file, statement_number}`). The same line is refused by its
fingerprint, a hash of its date, description, reference, amount, running
balance, and its occurrence among identical lines of the same file, so a
statement may carry two identical movements on one day while an overlapping
export is refused whole, naming each line already on file and the statement
and line that hold it (`{:duplicate_lines, [...]}`). A row the mapping
cannot read refuses the file with every faulty row and why
(`{:invalid_lines, [...]}`). Statements and lines are never changed or
deleted.

## Matching

`unmatched_items/4` lists the bank account's statement lines with no
standing match and, read through the ledger facade page by page, every
entry on its ledger account with none; an entry's `amount` is its debits
less its credits on that account, so a transfer between two of the
company's bank accounts appears on both, with opposite signs, and is
matched on each. Suggestions pair each line with the unmatched entry of the
same amount dated within the account's window, preferring one whose
reference or description names the line's reference (or the reverse), then
the nearest date; each entry is suggested once.

`match/4` matches any number of statement lines with any number of entries
whose amounts sum to the same figure, recording the match with the actor,
the database's time, the company's gapless `match_number`, a `matched`
event, each line, and each entry with its number, date, description,
reference, and amount copied (a posted entry never changes, so the copy is
exact and a match reads without the ledger). `unmatch/4` appends the one
`unmatched` event, which needs a reason; a match stands while it has a
`matched` event and no `unmatched` one, and a line or entry is in at most
one standing match. Matching again is a new match with a new number. A
match a finalised reconciliation counted is kept
(`{:error, :match_finalised}`, see Reconciliations).

## Reconciliations

A reconciliation of a bank account is as of a statement `end_date` against
the `statement_balance` the bank shows on that date. Its figures
(`preview_reconciliation/5`, `get_reconciliation/3`) are:

- the book balance: the ledger account's debits less credits through the
  end date, summed by PostgreSQL through `Ledger.account_totals/3`;
- the items that explain the difference: every statement line through the
  end date with no standing match (`statement_line`, on the statement but
  not in the books), every entry through the end date with none (`entry`,
  in the books but not yet on a statement), and every standing match whose
  statement side through the end date differs from its ledger side through
  it (`timing`, a cheque or deposit the bank saw after the date);
- the difference: the statement balance less the book balance, less the
  unmatched statement lines, plus the unmatched entries, plus the timing
  items. Zero means the two balances are explained; otherwise a statement
  is missing, a line was posted twice, or the balance was mistyped.

Every figure is read at three numbers the result names: the ledger's
`through_entry_number`, the company's `through_statement_number`, and its
`through_match_event_number`. Passing them back to `preview_reconciliation/5`
reproduces the figures exactly, however many entries, statements, or
matches came later, because all three are append-only and numbered in
order.

`open_reconciliation/4` records the reconciliation with its `opened` event;
one reconciliation of an account is open at a time, and each ends after
the last finalised one. `finalise_reconciliation/3` refuses whoever opened
it while the company separates duties (`{:error, :same_person}`), reads the
figures now, refuses a difference other than zero
(`{:error, {:difference, amount}}`),
and records the `finalised` event with the book balance, the difference,
the three numbers, and the actor and time, and the items as they stood.
From then on `get_reconciliation/3` reads the stored snapshot, nothing
about the reconciliation changes, and no match the snapshot counted (one
whose `matched` event is numbered through the recorded match-event number)
can be unmatched: the facade and the database both refuse it.
`abandon_reconciliation/4` closes an open reconciliation with a reason
instead, so a mistyped balance is corrected by a new reconciliation, not
by editing.

## Posting charges and interest

A statement line the books lack, a bank charge or interest, is posted from
the reconciliation page. `post_statement_line/4` posts, through
`Ledger.post_entry/4`, a charge (money out) as a debit to the account's
charges account against a credit to its ledger account, or interest (money
in) as the reverse, dated the line's date with its description and
reference, then matches the line to the new entry in the same transaction.
The ledger refuses a closed period or an inactive account by rolling back
the transaction it joined, so its changeset comes back and nothing is
recorded; nothing here reopens a period.

The entry names this module and the statement line as its owner
(`finance/reconciliation`, `statement_line:<id>`, through
`Ledger.post_entry/4`'s `owner` option), so the ledger holds one entry per
line: a line unmatched after it posted is matched to that entry again, and
posting it again is `{:error, :statement_line_posted}`. The ledger refuses
`Ledger.reverse_entry/4` on the entry (`{:error, {:owned_by, owner}}`); the
owner's path is `reverse_statement_line/4`.

Entries this module posted before the ledger recorded owners are claimed by
its migration `20261015150600` through the ledger's
`finance_ledger_claim_legacy_entry`. The only trace of such a posting is the
match made with it, so the rule is: a match whose note starts `Posted from
statement line as ` and that names exactly one statement line and exactly one
entry has that entry claimed as `finance/reconciliation`,
`statement_line:<line id>`. A statement line named by more than one such match
(unmatched and posted again before one entry per line was kept) is not
claimed, since the ledger keeps one original entry per owned record; its
entries stay legacy. An unclaimed legacy entry whose standing match carries
that note is reversed by `reverse_statement_line/4` through
`Ledger.reverse_owned_entry/5` like an owned one, its reversal unowned as it
is; one matched by hand is refused (`:statement_line_not_posted`). A match
that carries the note by hand (a manual match written to look like a posting)
is claimed the same, so the note is not for free text.

`reverse_statement_line/4` corrects a wrong charge or interest entry. It
needs a `reason` (blank or over 500 characters is `{:error,
:invalid_reason}`), the line standing matched, alone, to the entry it
posted (`:statement_line_not_matched`; any other match is
`:statement_line_not_posted`), and no finalised reconciliation having
counted that match (`:match_finalised`). In one write transaction it
appends the match's `unmatched` event, which carries the reason and the
actor, then posts the entry's reversal through
`Ledger.reverse_owned_entry/5` as the line's owner, dated `entry_date`
(default today). The ledger's refusal (a closed period) rolls both back.
The line then stands unmatched with no unreversed entry of its own, and it
is not posted again (the ledger holds an entry for it): book the right
figure with a manual journal and match that.

## Pages

| Route | Capability | Page |
| --- | --- | --- |
| `/finance/reconciliation` | `finance.reconciliation.view` | Bank accounts and the form that adds or changes one |
| `/finance/reconciliation/accounts/:id` | `finance.reconciliation.view` | One account: statement import (a file upload read once and kept as the statement's source document), its statements each with a download of the bank's file, its reconciliations, and the form that opens the next |
| `/finance/reconciliation/accounts/:id/matching` | `finance.reconciliation.view` | Unmatched lines beside unmatched entries, suggestions, matching of a selection, and unmatching with a reason |
| `/finance/reconciliation/reconciliations/:id` | `finance.reconciliation.view` | A reconciliation's figures, items, posting of charges and interest, finalising, abandoning, and history |

The matching and reconciliation pages subscribe to the ledger's posting
notices and read again when an entry commits; a finalised reconciliation
ignores them. A control the actor may not use is withheld with a sentence
saying so, and every event re-asks its capability.

## Database

The migration `20261014090000` is `:bilimbi_only` and creates
`finance_reconciliation_bank_accounts`, `_bank_account_changes`,
`_statements`, `_statement_lines`, `_matches`, `_match_lines`,
`_match_entries`, `_match_events`, `_reconciliations`,
`_reconciliation_events`, and `_reconciliation_items`; `20261017090100`
adds `import_mapping` to the statements, the mapping each was read through
(null for a statement imported before it). Rows of one company
reference each other through composite `(id, company_id)` foreign keys;
ledger account and entry IDs are plain columns. PostgreSQL enforces the
rules the facade checks, so no other writer can break them:

- a bank account keeps its company and ledger account and is never
  deleted; one bank account per ledger account and per name;
- every other table is append-only: no UPDATE, DELETE, or TRUNCATE;
- triggers number each company's statements, matches, match events,
  reconciliations, and reconciliation events without gaps and stamp their
  times, replacing whatever the writer sent;
- the same file and the same line fingerprint are refused per bank account
  by unique indexes; a statement's lines are inserted only in its own
  transaction, and a deferred trigger refuses a commit in which the line
  count or dates disagree;
- a match's lines and entries are inserted only in its own transaction; a
  line or entry in another standing match is refused; a deferred trigger
  refuses a commit in which the two sides differ, either is empty, or the
  `matched` event is missing; an `unmatched` event needs a reason and a
  standing match that no finalised reconciliation counted;
- one open reconciliation per bank account, each ending after the last
  finalised one; a `finalised` event carries its figures and numbers and a
  zero difference; an `abandoned` one its reason; items are inserted only
  in the transaction that finalises.

`Bilimbi.Finance.Reconciliation.SchemaContract` describes the tables but is
not registered in the descriptor: compatibility verification runs before
pending Bilimbi-only migrations, when these tables correctly do not exist.
`test/schema_contract_test.exs` runs the migration in a fresh database,
verifies the contract with `Bilimbi.Base.Database.SchemaVerifier.verify/2`,
and proves the migration's own triggers outside the test sandbox.

## Standards addressed

- **Audit trail.** Every statement records who imported it and when, with
  the file's hash; every match and every reconciliation records who made it
  and when, and each change of state (unmatching, finalising, abandoning) is
  an appended event with its actor, reason, and database-stamped time, so a
  status is always the latest event's and the log is the whole history.
  Bank charges and interest reach the books only as ordinary ledger entries
  through the ledger's facade. Every change to a bank account is logged
  with its actor and reason.
- **Independent review.** While the company separates duties (the
  default), a reconciliation is finalised by someone other than whoever
  opened it, impersonation included; a company that does not lists each
  such finalisation in the ledger's approval exceptions for review.
- **Gapless numbering.** Statements, matches, match events,
  reconciliations, and reconciliation events are numbered per company by
  the database in order, never skipped or reused.
- **Nothing deleted.** Statements, lines, matches, events, reconciliations,
  and items are never updated, deleted, or truncated; a wrong match is
  unmatched on record, a wrong reconciliation abandoned on record, and
  unmounting Finance keeps every row.
- **Reproducible reports.** A finalised reconciliation keeps the figures
  and items it was finalised with, and the entry, statement, and
  match-event numbers that reproduce them from the live tables; the
  matches it counted cannot be unmatched, so what it reported stays true.
- **Completeness.** The same statement file or line cannot be imported
  twice, so bank movements are counted once; a running balance that does
  not follow from the amounts refuses the import.

Out of scope here: live bank feeds and bank APIs, OFX and MT940 formats,
and multi-currency revaluation.

## Tests

Module tests run on temporary copies of the tables built from the
migration's own `statements(temporary: true)`, constraints and triggers
included; the ledger's come from its fixtures. `test/support/test_fixtures.ex`
builds two tenants' companies and an Authz snapshot, and
`test/support/reconciliation_case.ex` a company with a book, a chart, and a
bank account. `web_test/` covers the four pages against the real host. Bank
data in tests is made up; no real bank, account number, or person appears.
