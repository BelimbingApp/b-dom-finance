# b-dom-finance Agent Guide

This repository is the Finance Domain for Bilimbi. It is not a standalone Mix
project: it builds only when mounted in a Bilimbi checkout at
`apps/domains/finance` (see `README.md` for the mount commands and naming
convention). Read Bilimbi's root `AGENTS.md`, `apps/domains/AGENTS.md`,
`docs/architecture/0010_composition-model.md`, and
`docs/architecture/database.md` in that checkout before changing anything
here; they govern this code and are not copied here.

## Working here

- Run Mix from the Bilimbi root, not from this repository: `mix precommit`
  there tests every mounted module, and database tasks refuse a partial graph.
  To test one module, run `mix test` inside that module's folder. A module
  whose closure boots Base Queue creates Queue's tables from its `test` alias,
  as `ledger/mix.exs` does.
- The container (`bilimbi.container.exs`, `mix.exs`) holds no `lib/`,
  `priv/`, or `test/`; Bilimbi's workspace-boundary test rejects them. Code
  lives in an immediate child module folder with its own `bilimbi.module.exs`,
  `mix.exs` (`MixDiscovery.module_project/2`), `lib/<folder>.ex` facade,
  `test/`, and `docs/`. Declare every `Bilimbi.*` namespace a module
  references in its descriptor, or Bilimbi's `.github/scripts/graph_edges.exs`
  fails. Namespaces are `Bilimbi.Finance.<Module>` with OTP app
  `:bilimbi_finance_<folder>`.
- Domain code uses only meta-terms: book, account, account type, entry, line,
  debit, credit, fiscal document, party, submission, status event. A fixed
  chart of accounts or a currency is a company's data, never a code
  identifier, schema constant, inclusion list, or default. The five account
  types are the one fixed classification. A tax authority's own rules,
  formats, and code lists live only behind `Bilimbi.Finance.Einvoice.Authority`
  in that authority's namespace (`einvoice/lib/einvoice/my_invois/`).
- Issue a fiscal document through `Bilimbi.Finance.Einvoice.issue_document/3`
  with plain attributes, never by writing its tables: it derives every amount
  and records the `issued` event the status reads from.
- Write UBL JSON through `MyInvois.Json` (`einvoice/lib/einvoice/my_invois/json.ex`),
  not `Jason.encode!/1` of a map: the authority signs exact bytes, so key
  order and each number's written form must survive.
- Post to the ledger through `Bilimbi.Finance.Ledger`'s facade, from Finance
  modules and other Domains alike; never write or read its tables. A posted
  entry is corrected with `reverse_entry/4`, never edited. Its `entry_date`
  must fall in an open period: handle that changeset error, never reopen a
  period to post.
- Keep a record's changing state (open, closed, approved, ...) as append-only
  events with actor, reason, and a database-stamped time, the latest deciding
  the state, as the ledger's closing log does; an updatable status column
  loses the history an auditor asks for.
- Record an e-invoice status event through
  `Bilimbi.Finance.Einvoice.Documents.record_event!/4` and an outcome's
  audit action through `Documents.record_action!/4`, never by inserting the
  schemas: they take the actor from the scope. Talk to the authority only
  through the `Bilimbi.Finance.Einvoice.Authority` callbacks (`submit`,
  `document_status`, `cancel`, ...), which return meta-term outcomes;
  `Bilimbi.Finance.Einvoice.Clearance` is the one caller that records them.
  On a duplicate or an outage, look the document up with `find_submission`
  before stopping or retrying; never resubmit one the authority holds.
  Post a document once (`Posting.post` is a no-op after a `posted` event),
  decide a status change from the document read under the company lock,
  never call the ledger inside a `write!`: its refusal rolls back the
  transaction it joins. Only `Posting` calls it inside a transaction, of
  its own, which it rolls back whole on a refusal before recording the
  failure in a fresh one. Resolve a failed posting with
  `Einvoice.retry_posting/3` or `retry_reversal/3`.
- A job that acts for a user is queued with `Queue.enqueue_for/3` and its
  arguments are identifiers only (`SubmitWorker.validate_args/1` is the
  allowlist shape). Base Queue has no snooze: a worker returns `{:retry,
  code}` and the queue's backoff spaces attempts; it never sleeps for a
  `Retry-After`.
- Authorize every public call inside the facade with
  `Bilimbi.Core.Company.authorize_company_target/3` and the scope it was
  handed, and take `Company.lock_writable_company/2` inside every write's
  transaction, as `ledger/lib/ledger.ex`'s `authorize/3` and `write/4` do.
  Never take an actor or actor ID as an argument.
- New tables are Bilimbi-only: declare each migration `:bilimbi_only` with a
  globally unique version, and keep the module's `SchemaContract` out of the
  descriptor (adoption would expect the tables before they exist); a
  `test/schema_contract_test.exs` verifies it against a fresh database.
  Pass a table name as an argument (`owned_columns("table") |> ...`), never
  as the head of a pipe: Bilimbi's `TenantScopeGateTest` reads a piped string
  literal as an unscoped query over that tenant-owned table.
- Module tests run against temporary tables in each module's
  `test/support/test_fixtures.ex`, not its migrations. Mirror a migration's
  constraints and triggers there, or a test that makes PostgreSQL refuse
  proves nothing; a migration's public `functions/1` (the closing migration's)
  lets fixtures create its trigger functions in `pg_temp.` instead of copying
  them. The sandbox never commits, so a deferred trigger runs only
  after `check_deferred_constraints!/0`, and TRUNCATE with pending trigger
  events fails for that reason rather than the trigger's; prove those in the
  fresh-database contract test.
- A test that installs a contribution snapshot is `async: false`: the
  snapshot is process-global.
- Mount a real copy (clone or `rsync`), not a symlink: `mix.exs` locates the
  Platform with `__DIR__`, which resolves through a symlink to this checkout.
- `.github/scripts/missing_dependency.sh` moves Finance out of the mounted
  workspace and mounts a throwaway Extension, so CI runs it as the last step;
  never commit that fixture or add a real Extension to prove the refusal.
- Never commit a lock file here. Mounted builds share Bilimbi's ignored
  `.scratchpad/composition-lock/` overlay (`mix/composition_lock.exs`).
- CI is `.github/workflows/ci.yml`; the Bilimbi revision it builds against is
  the single line in `.github/bilimbi-revision`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
