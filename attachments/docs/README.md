# Finance Attachments

`finance/attachments` keeps the original source documents behind Finance
records: a supplier's invoice scan behind a bill, a remittance behind a
payment, a contract behind an invoice, a voucher behind a manual journal, and
the bank's own file behind an imported statement. Each is a records-grade
document in Base Artifacts with a retain-until date the company's retention
setting gives it, linked to its record with the file's facts and who
captured it when, and never changed afterwards.

## What it owns

- `Bilimbi.Finance.Attachments`, the facade: `attach/5` for an existing
  record; `capture_file/5` and `attach_capture/5` for a record created in
  the same transaction as its file; `replace/4` and `remove/4` while the
  record is not final; `extend_retention/4`, `place_hold/4`, and
  `release_hold/4`; `refresh_retention/4` for a record whose date changed (it
  queues `RetentionRefreshWorker`); the company's `get_retention/2`, `set_retention/3`, and
  `list_retention_changes/2`; `retain_until/3`; `evidence_page/4`; and the reads
  `list_attachments/4`, `list_company_attachments/3`, `list_sources/2`,
  `get_attachment/3`, and `read_attachment/3`.
- `Bilimbi.Finance.Attachments.Source`, the behaviour a Finance module
  implements once per kind of record it keeps source documents for. The
  module names the record (`source_id/0`, `source_label/0`), names the
  capability it asks to read its records (`view_capability/0`), and reads it
  through its own facade (`document/3`: label, date, final?). Payables
  implements it for bills and payment requests, receivables for documents
  and payments, reconciliation for statements; the ledger has no pages, so
  `Bilimbi.Finance.Attachments.JournalSource` lives here.
- `Bilimbi.Finance.Attachments.ArtifactOwner`, the Base Artifacts adapter:
  every store, read, delete, and retention change re-asks this module's
  capability for the operation and that the company is live.
- The pages: `/finance/attachments`, the company's source documents with a
  download each, filters by kind of record and standing, and the retention
  setting with its history; `/finance/attachments/:id/download`, which
  reads through the facade on every request and delivers the file as an
  attachment, content sniffing disabled, never cached; and
  `Bilimbi.Finance.Attachments.Web.Panel`, the live component a record's
  page embeds (payables' bill page, reconciliation's statements) to list,
  download, attach, replace, and remove.

## Rules

- **Retention.** A document is kept the company's retention years (seven
  until the company lengthens it; `set_retention/3` refuses fewer or the
  same, and so does the database) after the end of the financial year its
  record's date falls in: the ledger's fiscal year covering the date when
  the company has opened one, else the calendar year; the day ends in UTC.
  The years and the original retain-until are kept on the attachment. Base
  refuses to delete the bytes before retain-until, and `purge_expired` never
  selects them; a legal hold refuses deletion after it. `extend_retention/4`
  only moves a retain-until later, as a `retention_extended` event; the
  retain-until and `on_hold` a read shows follow the latest `retention_extended`
  and hold events, and nothing shortens one. Base Artifacts makes a change
  first, outside any transaction, after a short transaction under the company
  lock has checked it against the events; the event follows without that lock
  (`{:error, {:recorded_in_storage, reason}}` if it cannot be recorded). Base
  is the fact, so `get_attachment/3` and `read_attachment/3` append any
  retention event Base holds and the events lack, with the actor, impersonator
  or system principal and reason Base recorded (never the reader's), under a
  lock on the attachment's row so it is recorded once. A record whose date can
  change while it is not final (a draft invoice) may be re-dated after its
  attachments were kept; its module calls `refresh_retention/4` once the
  record is final, inside the transaction that finalises it (the job is an
  insert, so it commits with the record) or after it. That checks, with the
  caller's own scope, that the record is readable and final and computes the
  retain-until its date gives (`finance.ledger.view` for the fiscal years),
  then queues `RetentionRefreshWorker` with Base Queue's
  `enqueue_as_system/4` under the declared principal
  `finance.attachments.retention_refresh`, so the issuer needs no attachments
  grant. The job extends each standing attachment kept for less (never
  shortens one) and records `retention_extended` as the principal; a job whose source module is
  no longer mounted is cancelled, not retried. Finance
  code that must change retention without a user's grant queues that worker
  through `refresh_retention/4`; the owner adapter accepts the principal for
  `:retain`, and the facade gates every discretionary extension and hold with
  `finance.attachments.retention.manage` (and view).
- **Standing.** An attachment row is append-only; its standing is its
  latest event. A record that is not final (a draft bill, a submitted
  journal, a draft invoice, an undecided payment request) can have an
  attachment replaced (a new attachment, and `replaced` on the old naming
  it) or removed (`removed`, with a reason). Once the record is final
  (posted, issued, approved, rejected, voided, imported), its attachments
  are kept as they are; one can still be added. A replaced or removed
  attachment's bytes stay retained and readable from its history.
- **Capabilities.** `finance.attachments.view` reads and downloads;
  `finance.attachments.create` attaches and replaces;
  `finance.attachments.delete` removes; `finance.attachments.retention.manage`
  lengthens the company's retention or an attachment's and places or
  releases a hold. Reading a record through its source carries the owning
  facade's capability too, and so does reading an attachment's metadata
  (the file name, label, date, hash, and who captured it): the lists and the
  source documents page leave out the attachments of every source whose
  `view_capability/0` the caller lacks (one check per source module), and
  `get_attachment/3`, `extend_retention/4`, `place_hold/4`, and
  `release_hold/4` refuse one with `:unauthorized`, so the attachments grant
  alone discloses nothing about a bill, invoice, or statement. The retention
  reads the ledger's fiscal years (`finance.ledger.view`). The verbs are
  Base Authz's; this module declares none of its own (see the repository
  guide).
- **Storage order.** Base Artifacts stores outside any transaction, so a
  file is stored first, retained from creation, and the link recorded in
  its own transaction (or the caller's, for `attach_capture/5`). What can be
  checked is checked before storing; a link that still fails leaves a
  retained document nobody references, which an operator can find in Base
  Artifacts by its owner `finance/attachments`.
- **Not kept here.** The e-invoice PDF stays einvoice's regenerable visual,
  not a source document. The auditor's evidence pack exports the attachment
  index through `evidence_page/4` (`attachment`: document, file name, hash,
  and retain-until; `attachment_event`; `retention_change`), authorized with
  `finance.attachments.view`; the bytes stay in Base Artifacts and are read
  through `/finance/attachments`.

## Database

The migration `20261017090000` is `:bilimbi_only`:

- `finance_attachments_retention_changes`: the company's retention years,
  numbered and stamped by the database, which refuses a change that does not
  lengthen it.
- `finance_attachments`: the link from a record (`source`, `source_module`,
  `document_id`, `document_label`, `document_date`) to its artifact
  (`artifact_id`, unique) with `file_name`, `content_type`, `byte_size`,
  `sha256`, `retention_years`, `retain_until`, and `captured_by_*`,
  numbered per company and stamped by the database.
- `finance_attachment_events`: `replaced` (with `replacement_id`, a later
  attachment of the same record), `removed`, `retention_extended` (with the
  new `retain_until`), `hold_placed`, `hold_released`, each with the actor
  and the database's time; at most one `replaced` or `removed` per
  attachment.

Every table refuses updates, deletes, and truncation. `statements/1` is the
one source of the schema: the migration runs it, and the module tests run it
with `temporary: true`. `lib/attachments/schema_contract.ex` describes the
fresh schema and `test/schema_contract_test.exs` verifies it against the
migration in a fresh database; the descriptor registers no contract, as the
repository guide explains.

## Standards addressed

- Companies Act 2016 s.245, Income Tax Act 1967 s.82, Sales Tax Act 2018
  s.24 and Service Tax Act 2018 s.24 (records kept seven years): the
  original file is kept, hashed, and retained for the company's years after
  the end of the financial year, deletion before then is refused by the
  facade and the database, and a legal hold extends the refusal for an open
  matter. What this module does not do: prove that backups and restores of
  the storage root work, or where the storage is located; those are the
  deployment's evidence.
- ISA 315 and NIST SP 800-53 AU-9/AU-11 (protection and retention of audit
  information): every capture and change carries the actor, any
  impersonator, a reason where one is asked, and the database's time, and
  nothing is updated or deleted.
