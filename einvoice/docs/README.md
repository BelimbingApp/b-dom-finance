# E-invoicing

Module ID: `finance/einvoice`. A company's fiscal documents, cleared by a tax
authority: what it issued, what it submitted, and every answer the authority
gave. The first authority is Malaysia's LHDN MyInvois. Each company registers
with the authority and holds its own credentials and signing certificate;
Bilimbi is never an intermediary.

The module covers:

1. the module, its immutable tables, its facade, and its capabilities;
2. company settings for the environment, format version, credentials,
   certificate, supplier profile, and posting accounts, a setup page, PEM
   validation, and "Test connection";
3. a UBL 2.1 JSON builder, the authority's code lists as shipped reference
   data each company can override, and field validation;
4. a JSON XAdES signer in Erlang's `:public_key` and `:crypto`;
5. a MyInvois API client behind Base Integration;
6. submit and poll jobs on Base Queue that act for the issuing user, a
   status event and an audit action per outcome, and an outage retry with
   an operator notice after 72 hours (see Clearance);
7. credit, debit, and refund notes that reference a validated original,
   the 72-hour cancellation guard, and a buyer's rejection request;
8. a document page with the validation link and its QR code, a share link,
   a PDF through Base Artifacts, and a filtered, paged list;
9. the ledger bridge: a validated document posts a balanced entry, a
   cancelled one reverses it, and a reconciliation page lists what differs;
10. the monthly consolidated document for sales no buyer asked an
    individual document for, and self-billed documents the company issues
    as the buyer.

The signed proof with a real certificate (format version 1.1 against the
sandbox) waits for the certificate; sandbox testing submits unsigned
version 1.0 documents. The production cutover comes later.

## Public API

Call `Bilimbi.Finance.Einvoice` with a validated `Bilimbi.Base.Tenancy.Scope`
and an explicit company ID. Results are plain maps; the schemas are private.

| Function | Capability | Does |
| --- | --- | --- |
| `issue_document/3` | `finance.einvoice.documents.issue` | Records a document (or a note naming its `original_document_id`, or a self-billed document naming its `supplier`) from plain attributes, with an `issued` status event |
| `consolidation_candidates/3` | `finance.einvoice.view` | A month's documents a consolidated document would cover, those the authority's limits keep out, their totals, and the window for issuing it |
| `issue_consolidated_document/3` | `finance.einvoice.documents.issue` | Records the month's consolidated document, the documents each line covers, and a `consolidated` event on each |
| `get_document/3` | `finance.einvoice.view` | One document with its lines, status events, current `status`, the authority's identifiers, validation link, ledger entries, and `attention` flags |
| `list_documents/3` | `finance.einvoice.view` | Documents newest first; `limit` and `before` page them |
| `page_documents/3` | `finance.einvoice.view` | One page for a list, filtered by `search`, `status`, `document_type`, and `environment` |
| `submit_document/3` | `finance.einvoice.documents.submit` | Queues the submission as the signed-in user, after checking credentials and the signing key |
| `refresh_status/3` | `finance.einvoice.documents.submit` | Reads the status at the authority and records what changed |
| `cancel_document/4` | `finance.einvoice.documents.cancel` | Cancels a validated document inside its 72-hour window, then reverses its entry |
| `reconciliation/2` | `finance.einvoice.view` | Valid (or rejected) documents without an entry, and cancelled documents whose entry was not reversed |
| `retry_posting/3`, `retry_reversal/3` | `finance.einvoice.documents.submit` and `finance.ledger.entries.post` | Posts or reverses the entry of a listed document once its cause is fixed; idempotent, and an audit action names each try |
| `generate_pdf/3`, `read_pdf/3` | `finance.einvoice.view` | Renders and reads the printable document through Base Artifacts |
| `list_codes/3` | `finance.einvoice.view` | The company's active codes in one of the authority's lists |
| `override_code/5` | `finance.einvoice.settings.manage` | Renames, retires, or adds a code for the company |
| `setup/3` | `finance.einvoice.settings.manage` | What the company has configured, never a secret |
| `test_connection/2` | `finance.einvoice.settings.manage` | Logs in to the authority and records the outcome |

Every call authorizes its capability through
`Bilimbi.Core.Company.authorize_company_target/3` when it runs, and writes
take `Company.lock_writable_company/2`, as the ledger does. A system scope is
`{:error, :unauthorized}`. The Tenant Owner role holds all five
capabilities.

`issue_document/3` takes plain attributes, so a form, an import, an agent
operation, and later receivables all issue through it: `document_type`,
`code_number`, optional `issued_at`, `currency_code`, `buyer` (name, TIN,
registration type and number, contact, address) or, for a self-billed
document, `supplier` (the same plus industry code and business activity),
optional payment means,
terms, and billing period, for a note the `original_document_id`, and
`lines` (description, classification code, quantity, unit price, tax type
and rate, optional unit, discount, charge, exemption reason, tariff code,
origin country). A line states its tax rate
explicitly, never defaulting it; a blank discount or charge is none. The
company's own party (the supplier, or the buyer of a self-billed
document) comes from its settings and the environment from its current
setting. The list and the document views name the `counterparty_name`
(the buyer, or the supplier of a self-billed document).

Amounts are derived, never taken: a line's subtotal is quantity times unit
price, its amount is the subtotal less its discount plus its charge, and its
tax is that amount times the rate, each rounded half up to two places; the
document's totals are the sums. An amount finer than its column is refused,
not rounded. The draft (`Draft`) checks the shape every authority shares;
the authority (`Authority.validate/3`) then checks codes against the
company's code lists and its own rules, and names any supplier-profile field
still missing. A code number is unique per company and environment.

## Consolidated documents

`Bilimbi.Finance.Einvoice.Consolidation` reports, in one document, a
month's sales that no buyer asked an individual document for (receipts
recorded with `issue_document/3` and never submitted). Its sources are the
company's documents issued in the month, in the authority's calendar, in
the current environment, whose status is `issued` or `released`, that
were never submitted on their own, have no submit job waiting, and pass
the authority's limits (`Authority.consolidation_refusal/1`: MyInvois
takes only ringgit invoices of at most RM10,000). `consolidation_candidates/3`
lists them, the ones kept out with the reason, and their totals.

`issue_consolidated_document/3` takes the `month`, a `code_number`,
optionally the `document_ids` to cover (default all), and a `grouping`:
`"document"` (a line per source and tax, described by the source's code
number) or `"summary"` (a line per tax over every source, described by
their count and first and last code numbers). It is issued at the moment
of asking, which must fall inside the window the authority sets
(`Authority.consolidation_window/1`; MyInvois: from the end of the month
in Malaysian time to seven days later, else `:period_not_ended` or
`:consolidation_window_closed`). The authority shapes the document
(`Authority.consolidated_document/1`; MyInvois: an invoice to the general
public buyer `EI00000000010` with its contact and address "NA",
classification `004`, unit `C62`, and the month as a "Monthly" billing
period). Each line's amount and tax are the exact sums of its sources'
lines, so the consolidated totals equal the sources' totals; this is the
one place `Draft` takes a line's tax rather than deriving it from the
rate. An individual document never carries the consolidated
classification.

Recording it writes a `finance_einvoice_consolidated_sources` row per
source and line it covers, and a `consolidated` status event on each
source, which can then not be submitted on its own. The consolidated
document is submitted, polled, posted, and cancelled like any invoice.
When the authority refuses it, finds it invalid, or it is cancelled,
`Documents.record_event!/4` releases its sources in the same transaction
(`released`, after which they may be consolidated again or submitted on
their own), and the consolidated document, whose bytes and issue date
never change, is never sent again. MyInvois refuses a document issued
more than 72 hours before it is submitted (CF321), so a consolidated
document is submitted as soon as it is issued. Its view lists the documents
it covers (`sources`, with the lines carrying each), and a covered
document's view names its holder (`consolidated_by`). Issuing one is the
audit action `finance.einvoice.document.consolidated`.

## Self-billed documents

A self-billed document (MyInvois types `11` to `14`) is issued by the
company as the buyer, for the purchases the authority lists (foreign
suppliers, agents and distributors, individuals not in business, and
others): `issue_document/3` takes the counterparty as `supplier`, with its
industry code and business activity (MyInvois: `00000` and "NOT
APPLICABLE" for a supplier abroad), and refuses a `buyer`; the company's
own profile is recorded as the buyer. A supplier outside Malaysia without
a Malaysian TIN takes the general TIN `EI00000000030`, which MyInvois
refuses for a supplier in Malaysia. A self-billed credit, debit, or refund
note references a validated self-billed invoice, and an ordinary note an
ordinary invoice. Submission, polling, cancellation, the PDF, and the
ledger bridge are the same paths.

## Clearance

`Bilimbi.Finance.Einvoice.Clearance` owns what happens between a recorded
document and the authority's verdict; its moduledoc is the contract.
`submit_document/3` queues `Bilimbi.Finance.Einvoice.SubmitWorker` with
`Bilimbi.Base.Queue.enqueue_for/3`, so the job runs as the user who asked
and every event, audit action, and ledger entry names them. It refuses
with `:already_queued` while a submit job for the document is waiting or
running, and the page hides its submit button meanwhile. The job
commits a submission row with the exact bytes before the HTTP call,
records the authority's answer as a status event (`submitted`, `refused`,
`duplicate`, `rate_limited`, or `unavailable`), and never resubmits a
document the authority accepted: a 2xx ends the job. An outcome is
recorded under the company lock only while the document is still
submittable, so two overlapping jobs leave one `submitted` event and one
poll job. After a
`DuplicateSubmission` answer, or an outage that may have hidden an
accepted request, it asks the authority for the document by its code number
(`Authority.find_submission/4`; MyInvois lists the documents the taxpayer
recently sent) and records the UID and UUID it finds as `submitted`, with
the authority's own entry, and queues the poll. Only when nothing is found
does a duplicate stop the job for an operator, and an outage retry. The
search runs from a minute before the oldest attempt without a final answer
to a minute past the moment of asking, ignoring any document whose UUID
this document already recorded, and it also runs before any retry that
finds such an attempt (a crash, an outage, or an earlier search that could
not answer): the bytes go out again only on a clean not-found, and not at
all while the search is rate limited, unavailable, refused, or too long to
read within MyInvois' ten pages (recorded as `search_deferred`). A rate limit or outage retries under Base Queue's
backoff (Base Queue has no snooze, so the authority's `Retry-After` is
recorded on the event rather than honoured to the second); an outage that
has lasted 72 hours records `overdue` and the audit action
`finance.einvoice.submission.overdue` once, which the document page and
list show. `PollWorker` reads the submission's progress a few seconds
apart (`:poll_interval_ms`, 4 seconds), a bounded number of reads per job,
and records `valid` (with the long ID that completes the validation link)
or `invalid` (with the validation results), then posts the ledger entry.
A status change is decided from the document as read under the company's
lock, so a refresh and a poll cannot both record it. The ledger work it
leaves (posting or reversing) runs
after that transaction commits, never inside it: the ledger rolls back
its own transaction on a refusal, which would take the status with it.

A refresh (`refresh_status/3`) reads the document at the authority and
records a buyer's rejection request as `rejected`, a cancellation made on
the portal as `cancelled`, or an unchanged status as `status_checked`.
There is no scheduled status sync yet: a rejection request is noticed
when someone refreshes the document. A cancellation (`cancel_document/4`)
is guarded locally (valid or rejected, inside the 72 hours after
validation, no note the authority holds referencing it) before the
authority is asked; its refusal is recorded as `cancellation_refused`.

Every clearance call (the jobs, a refresh, a cancellation, a ledger retry)
checks that the company is writable before it asks the authority anything,
so an archived company is `{:error, :company_archived}` (a cancelled job)
rather than an authority answer that cannot be recorded.

Audit actions per outcome: `finance.einvoice.submission.queued`,
`.submitted`, `.refused`, `.submission.duplicate`, `.submission.overdue`,
`.validated`, `.invalid`, `.rejected`, `.cancelled`,
`.cancellation.refused`, `.posting.retried`, and `.pdf.generated`, each
carrying the document ID, code number, environment, and the authority's
identifiers.

## Ledger bridge

`Bilimbi.Finance.Einvoice.Posting` posts one balanced entry through
`Bilimbi.Finance.Ledger.post_entry/3` when a document is validated, dated
the issue date, with the code number and authority UUID in the entry's
`reference`, and records the entry's ID on a `posted` status event; a
cancellation reverses it with `Ledger.reverse_entry/4` and records
`posting_reversed`. The accounts are the company's
`finance.einvoice.posting.*` settings, by account code in its own chart,
and the authority's `posting_rule/1` names which each type uses.
An invoice or debit note debits the receivable account and credits
revenue and tax; a credit note posts the mirror image; a refund note
debits revenue and tax and credits the settlement account. A self-billed
invoice or debit note is a purchase: it credits the payable account and
debits expense and purchase tax; a self-billed credit note posts the
mirror image, and a self-billed refund note debits the settlement account
and credits expense and purchase tax. A tax of zero posts no tax line.
A consolidated document posts as one invoice; its sources never post. A posting that cannot happen (accounts unset or
unknown, book not open or in another currency, missing grant) records
`posting_failed` or `reversal_failed` with the reason, and
`reconciliation/2` lists the document until it is resolved. The user who
submits needs `finance.ledger.entries.post` for the posting to happen. A
document posts once: the entry and the `posted` event are one transaction
under the company's writable lock, so there is never an entry without its
event, a second attempt is a no-op, and partial unique indexes make the
database refuse a second `posted` or `posting_reversed` event. A refused
entry rolls that transaction back, and the failure event is recorded
afterwards. Only a database failure that may pass at once
(a lost connection, a timeout, lock contention) is tried a second time as
a fresh transaction and recorded as one failure; a ledger refusal or a
configuration or grant failure is final and waits for `retry_posting/3`
or `retry_reversal/3`, which the reconciliation page offers to a user
holding both the e-invoice and the ledger grants. A status read never
posts again. A rejected document stays valid at the authority, so its entry stands and a
note corrects it.

## Pages

- `/finance/einvoice/documents` (Finance › E-invoices): the company's
  documents, newest first, searched by number or buyer and filtered by
  status, type, and environment; page state lives in the URL.
- `/finance/einvoice/documents/:id`: the document, its parties, lines,
  totals, the authority's identifiers, the validation link with its QR code
  (`QrCode`, through `eqrcode`) and a copy control, every status event,
  the ledger entries, the attention flags, and the actions: submit,
  refresh, cancel with a reason, generate and download the PDF.
- `/finance/einvoice/documents/:id/pdf/:artifact_id`: the PDF download,
  read through Base Artifacts on every request.
- `/finance/einvoice/consolidation` (Finance › E-invoice Consolidation):
  a month's candidates (`?month=YYYY-MM`, by default the latest month that
  has ended), the documents that need an individual e-invoice and why,
  their totals, the issuing window, and a form that issues the
  consolidated document while the window is open. A consolidated
  document's page lists what it covers, and a covered document's page
  names the consolidated document and offers no submit.
- `/finance/einvoice/reconciliation` (Finance › E-invoice Reconciliation).
- `/finance/einvoice/setup` (Finance › E-invoice Setup): see Settings.

The PDF is rendered by `Bilimbi.Finance.Einvoice.ArtifactOwner` with Base
Artifacts' pure PDF serializer, so it needs no browser; it carries the
validation link in text, and the QR code is on the page. Base Artifacts
needs a storage root and retention period configured (Operator Settings)
before a PDF can be stored. The `pdf_generated` event keeps the sequence of
the last other event the PDF was rendered from; asking again while the
document has gained none returns the stored artifact and records no new
artifact, event, or audit action.

## Authority

`Bilimbi.Finance.Einvoice.Authority` is the seam between the meta-term facade
and one authority's rules. Everything MyInvois defines sits in
`Bilimbi.Finance.Einvoice.MyInvois`:

- `MyInvois` validates a draft (invoices and notes in ringgit) and maps a
  recorded document to the builder's input, a note carrying the original's
  code number and UUID as a `BillingReference`. Its API callbacks translate
  the authority's answers into the outcomes `Clearance` records
  (`:accepted`, `:rejected`, `:refused`, `:duplicate`, `:rate_limited`,
  `:unavailable`), keeping each raw response beside them. It alone defines the
  authority's field shapes (TIN, phone as a plus sign and 8 to 20 digits in
  20 characters, industry, state, and country codes), which the settings
  validators and the buyer's checks both ask (`valid_format?/2`), so supplier
  and buyer follow one rule each. It also ties a line's rate to its tax type:
  types `01` to `05` need a rate above zero, and `06` and `E` need zero (`E`
  also needs its exemption reason). Its login, the missing supplier fields,
  and the identity a certificate's subject carries are reached through
  `Authority` callbacks, not named by the facade. So are the posting side
  of each document type (`posting_rule/1`), its human name
  (`document_type_name/1`), the cancellation window
  (`cancellation_window_hours/0`, 72 for MyInvois), the outage
  allowance before the operator notice (`outage_notice_hours/0`, 72),
  the self-billed types (`self_billed_document_types/0`), and the
  consolidated document's window, limits, and shape
  (`consolidation_window/1`, `consolidation_refusal/1`,
  `consolidated_document/1`);
  `Posting`, `Documents`, `Clearance`, the pages, and the PDF name no
  document type code and no window.
- `MyInvois.Builder` writes UBL 2.1 JSON in the element order of the SDK's
  samples, and `test/builder_golden_test.exs` rebuilds all four SDK version
  1.1 samples byte for byte. It maps and never computes, which is why it can
  reproduce samples whose own figures do not add up.
- `MyInvois.Json` keeps key order and each number's written form (`1500.0`
  stays `1500.0`). The authority hashes and signs exact bytes, so UBL JSON is
  never written with `Jason.encode!/1` of a map.
- `MyInvois.Signer` follows the SDK's "Signing a JSON document" steps: the
  document without `UBLExtensions` and `Signature`, minified, is hashed and
  signed with RSA PKCS#1 v1.5 and SHA-256; the certificate's DER is hashed;
  the signed properties carry the UTC signing time and the issuer name and
  serial number; their minified `{"Target", "SignedProperties"}` object is
  hashed. The issuer name is written as .NET renders it (attributes in
  reverse DER order), which is what both SDK certificates show.
  `test/signer_test.exs` verifies the SDK's four signed samples, rebuilds
  their signed properties from the SDK certificate, and signs and verifies
  with a generated certificate.
- `MyInvois.Client` calls the API through `Bilimbi.Base.Integration.request/3`
  with the caller's scope: login, submit, submission status, document
  details, the recently sent documents (searched by `find_submission`),
  cancel, and TIN validation. The validation link is
  `{portal}/{uuid}/share/{longId}`, with the portal per environment a
  platform setting (`finance.einvoice.<environment>.portal_url`). `MyInvois.TokenCache` keeps one token
  per company, environment, and client ID in ETS until two minutes before it
  expires; a 401 drops it. The client never retries: a 2xx submission must
  not be resent, and a 422 or 429 returns the `Retry-After` seconds to the
  caller that recorded the submission.

Foreign-currency documents are refused for now: the SDK's sample writes tax
amounts in ringgit beside document-currency totals without saying how they
convert, so the rule is confirmed against the sandbox first. The builder
already writes `TaxExchangeRate`.

## Settings

Company-scoped Base Settings in the editable group `finance.einvoice`, each
guarded by `finance.einvoice.settings.manage`, are edited on the Settings
screen with the company chosen:

- `finance.einvoice.environment`: `sandbox` (default) or `production`;
- `finance.einvoice.document_version`: the authority's format version
  (`1.1`, signed, the default; or `1.0`, unsigned, for sandbox testing
  before the certificate arrives);
- `finance.einvoice.posting.*`: the account codes a validated document
  posts to (`receivable_account`, `revenue_account`, `tax_account`,
  `settlement_account`, and for self-billed purchases `payable_account`,
  `expense_account`, `purchase_tax_account`), none set by default;
- per environment, `client_id`, `client_secret` (encrypted), and
  `secret_expires_on`;
- `certificate_pem` and `private_key_pem` (both encrypted), validated as one
  X.509 certificate and one unencrypted RSA private key; Erlang reads PEM but
  not PKCS#12, so the company exports both from its `.p12`;
- `expiry_alert_days` (default 30);
- the supplier profile, `finance.einvoice.supplier.*`: name (blank uses the
  company's), TIN, registration type (BRN for a business; NRIC, PASSPORT,
  or ARMY for an individual) and number, sales and service tax and tourism
  tax registrations, industry classification code, business activity,
  phone, email, and address with the authority's state code and the ISO
  country code.

Encrypted values use Base Settings' envelope, are masked on screen, and are
revealed only through its password-checked reveal. `Configuration.credentials/2`
is the only function that returns a secret, and only the client calls it.
The API's base URL per environment is a platform setting
(`finance.einvoice.<environment>.api_url`) defaulting to the SDK's hosts.

The setup page, `/finance/einvoice/setup` (Finance › E-invoice Setup), shows
the signed-in company's environment, which credentials are set, the
certificate's issuer, serial, subject TIN and registration number, validity
and days left, whether the private key and supplier TIN match it, what the
supplier profile lacks, and a renewal alert when the certificate or client
secret expires within the alert window. Its "Test connection" logs in afresh.

## Code lists

`priv/code_lists/myinvois.json` holds the authority's nine lists (document
types, tax types, classifications, states, countries, currencies, units,
industry codes, payment means) as read from the SDK on 12 October 2026, with
each list's source URL. They are compiled into `CodeLists` as the reference
data every company starts from, so a refreshed list is a new file in a
release, reviewed like code, and no seed has to run. A company's override
(`override_code/5`, stored in `finance_einvoice_code_overrides`) renames a
code, retires it, or adds one the file lacks yet, for that company only, so a
list change the authority announces need not wait for a release. A code a
later file drops still names what recorded documents carry.

## Database

The migrations `20261012200000`, `20261013090000`, `20261013143000`
(one `posted` and one `posting_reversed` event per document), and
`20261013221500` (consolidation) are `:bilimbi_only`:

- `finance_einvoice_documents`: authority, environment, type, code number,
  issue instant (UTC), currency and rate, supplier and buyer snapshots as
  they stood, optional details, original document, totals, who issued it,
  and the database's `recorded_at`;
- `finance_einvoice_document_lines`: each line's codes, quantity, prices,
  discount, charge, and tax;
- `finance_einvoice_submissions`: the signed payload bytes exactly as sent,
  their SHA-256, environment, format, version, and who submitted them;
- `finance_einvoice_status_events`: every status change and answer, with the
  authority's status, submission UID, document UUID, long ID, reason, HTTP
  status, response body, and the ledger entry a `posted` or
  `posting_reversed` event names;
- `finance_einvoice_consolidated_sources`: which documents each line of a
  consolidated document covers;
- `finance_einvoice_code_overrides`: a company's renamed, retired, or added
  codes.

PostgreSQL enforces what the facade checks:

- triggers refuse UPDATE, DELETE, and TRUNCATE on documents, lines,
  submissions, and status events, so a cancellation or rejection is a new
  event;
- a trigger refuses a line added to a document recorded in an earlier
  transaction, and a deferred trigger refuses a commit in which a document
  has no lines or its totals differ from its lines';
- checks keep each line's amount equal to its subtotal less discount plus
  charge, and each document's totals consistent;
- a check keeps a submission's `payload_sha256` equal to the SHA-256 of its
  stored bytes;
- triggers stamp `recorded_at` with the database clock and number a
  document's events 1, 2, 3, ...; a unique index refuses a reused number;
- composite `(id, company_id)` foreign keys keep lines, submissions, events,
  an original document, and a consolidated document's sources in one
  company;
- a source is covered by one consolidated document at a time (a second is
  refused unless the first was refused, invalid, or cancelled), never one
  that was submitted on its own, and never another consolidated document;
  a submission of a source a consolidated document holds, or of a
  consolidated document that released its sources, is refused; and a
  deferred trigger refuses a commit in which a consolidated document's
  totals differ from its sources'. The consolidation migration's
  `statements(temporary: true)` builds the module tests' copy of its
  table and triggers.

`Bilimbi.Finance.Einvoice.SchemaContract` is not registered in the
descriptor, for the ledger's reason; `test/schema_contract_test.exs` verifies
it against a fresh database and proves the triggers outside the sandbox.

## Standards addressed

- **Immutable records with actor and time.** A recorded document, its lines,
  submissions, and status events are never edited or deleted (see Database).
  Each records who acted (user and impersonator, or a named system
  principal) and the database's own timestamp; a document's events carry a
  gapless sequence.
- **Reported once.** A sale reaches the authority either on its own or in
  one consolidated document, never both and never twice: the database
  refuses the overlap, a consolidated document's totals equal what it
  covers, and every move in or out of one is a status event on the source.
- **Exactly what was sent.** A submission stores the signed payload bytes and
  their SHA-256, and PostgreSQL checks one against the other, so what the
  authority validated can be shown byte for byte.
- **Every answer kept.** Each authority response and status change is a
  status event with its raw response body; Base Integration records each HTTP
  exchange, redacted, with bodies and secrets omitted.
- **Audit trail.** Every write is a Repo write that Base Audit records with
  its actor (ADR 0013). Issuing a document records the action
  `finance.einvoice.document.issued`, each connection test
  `finance.einvoice.connection.tested` with its outcome, and each code
  override `finance.einvoice.code.overridden` with the list, code,
  description, and active flag it set. Each outcome the authority decides
  is an audit action too (see Clearance), recorded by the job as the user
  it runs for.
- **Ledger tie-in.** A validated document's entry carries the code number
  and UUID, the document records the entry ID, and both are immutable, so
  an auditor walks document to UUID to entry to trial balance; the
  reconciliation page lists what does not tie (see Ledger bridge).
- **Retention.** Nothing is deleted and there is no purge path; unmounting
  Finance keeps every row. Malaysia requires seven years (Income Tax Act 1967
  section 82); how long a company keeps records is law, not code.
- **Secrets.** Credentials, certificate, and key are encrypted settings,
  masked on screen, and never in code, logs, audit payloads, or exchange
  records; access tokens live only in node-local memory.

## Tests

Module tests run on temporary copies of the tables, constraints and triggers
included, from `test/support/test_fixtures.ex`; change them with the
migration. `setup_einvoice!/0` builds two tenants' companies, the settings,
audit, exchange, artifacts, and ledger tables, and a contribution snapshot.
The jobs are exercised by calling their `handle_job/2` with an
`Execution` carrying the signed-in scope, against `Req.Test` stubs
(`stub_authority!/1`); `validate!/4` records the events a validation
would have, for tests that start from a valid document. Party data is the SDK's placeholder data, and certificates are
generated (`test_certificate!/1`). Authority calls answer from `Req.Test`
stubs set in `test_helper.exs`; no test reaches the authority. The SDK's
signed samples are in `test/fixtures/sdk/`, signed with the SDK's dummy test
certificate. `web_test/` covers the setup, document list and page, PDF download,
consolidation, and reconciliation pages against the real host.
