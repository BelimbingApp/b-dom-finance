# E-invoicing

Module ID: `finance/einvoice`. A company's fiscal documents, cleared by a tax
authority: what it issued, what it submitted, and every answer the authority
gave. The first authority is Malaysia's LHDN MyInvois. Each company registers
with the authority and holds its own credentials and signing certificate;
Bilimbi is never an intermediary.

This release covers the work that needs no authority account (slices 1 to 5 of
the plan):

1. the module, its immutable tables, its facade, and its capabilities;
2. company settings for the environment, credentials, certificate, and
   supplier profile, a setup page, PEM validation, and "Test connection";
3. a UBL 2.1 JSON builder, the authority's code lists as shipped reference
   data each company can override, and field validation;
4. a JSON XAdES signer in Erlang's `:public_key` and `:crypto`;
5. a MyInvois API client behind Base Integration.

Submitting and polling (slice 6), the live sandbox proof (7), notes and the
cancellation guard (8), the printable visual (9), the ledger bridge (10),
and consolidated and self-billed documents (11) come later.

## Public API

Call `Bilimbi.Finance.Einvoice` with a validated `Bilimbi.Base.Tenancy.Scope`
and an explicit company ID. Results are plain maps; the schemas are private.

| Function | Capability | Does |
| --- | --- | --- |
| `issue_document/3` | `finance.einvoice.documents.issue` | Records a document from plain attributes, with an `issued` status event |
| `get_document/3` | `finance.einvoice.view` | One document with its lines, status events, and current `status` |
| `list_documents/3` | `finance.einvoice.view` | Documents newest first; `limit` and `before` page them |
| `list_codes/3` | `finance.einvoice.view` | The company's active codes in one of the authority's lists |
| `override_code/5` | `finance.einvoice.settings.manage` | Renames, retires, or adds a code for the company |
| `setup/3` | `finance.einvoice.settings.manage` | What the company has configured, never a secret |
| `test_connection/2` | `finance.einvoice.settings.manage` | Logs in to the authority and records the outcome |

Every call authorizes its capability through
`Bilimbi.Core.Company.authorize_company_target/3` when it runs, and writes
take `Company.lock_writable_company/2`, as the ledger does. A system scope is
`{:error, :unauthorized}`. The Tenant Owner role holds all three
capabilities.

`issue_document/3` takes plain attributes, so a form, an import, an agent
operation, and later receivables all issue through it: `document_type`,
`code_number`, optional `issued_at`, `currency_code`, `buyer` (name, TIN,
registration type and number, contact, address), optional payment means,
terms, and billing period, and `lines` (description, classification code,
quantity, unit price, tax type and rate, optional unit, discount, charge,
exemption reason, tariff code, origin country). The supplier comes from the
company's settings and the environment from its current setting.

Amounts are derived, never taken: a line's subtotal is quantity times unit
price, its amount is the subtotal less its discount plus its charge, and its
tax is that amount times the rate, each rounded half up to two places; the
document's totals are the sums. An amount finer than its column is refused,
not rounded. The draft (`Draft`) checks the shape every authority shares;
the authority (`Authority.validate/3`) then checks codes against the
company's code lists and its own rules, and names any supplier-profile field
still missing. A code number is unique per company and environment.

## Authority

`Bilimbi.Finance.Einvoice.Authority` is the seam between the meta-term facade
and one authority's rules. Everything MyInvois defines sits in
`Bilimbi.Finance.Einvoice.MyInvois`:

- `MyInvois` validates a draft (type `01` invoices in ringgit for now) and
  maps a recorded document to the builder's input.
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
  details, cancel, and TIN validation. `MyInvois.TokenCache` keeps one token
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
- per environment, `client_id`, `client_secret` (encrypted), and
  `secret_expires_on`;
- `certificate_pem` and `private_key_pem` (both encrypted), validated as one
  X.509 certificate and one unencrypted RSA private key; Erlang reads PEM but
  not PKCS#12, so the company exports both from its `.p12`;
- `expiry_alert_days` (default 30);
- the supplier profile, `finance.einvoice.supplier.*`: name (blank uses the
  company's), TIN, registration number, sales and service tax and tourism
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

The migration `20261012200000` is `:bilimbi_only`:

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
  status, and response body;
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
  and an original document in one company.

`Bilimbi.Finance.Einvoice.SchemaContract` is not registered in the
descriptor, for the ledger's reason; `test/schema_contract_test.exs` verifies
it against a fresh database and proves the triggers outside the sandbox.

## Standards addressed

- **Immutable records with actor and time.** A recorded document, its lines,
  submissions, and status events are never edited or deleted (see Database).
  Each records who acted (user and impersonator, or a named system
  principal) and the database's own timestamp; a document's events carry a
  gapless sequence.
- **Exactly what was sent.** A submission stores the signed payload bytes and
  their SHA-256, and PostgreSQL checks one against the other, so what the
  authority validated can be shown byte for byte.
- **Every answer kept.** Each authority response and status change is a
  status event with its raw response body; Base Integration records each HTTP
  exchange, redacted, with bodies and secrets omitted.
- **Audit trail.** Every write is a Repo write that Base Audit records with
  its actor (ADR 0013). Issuing a document records the action
  `finance.einvoice.document.issued` and each connection test
  `finance.einvoice.connection.tested` with its outcome. Submission outcomes
  (`finance.einvoice.submitted`, `.validated`, `.invalid`, `.cancelled`,
  `.rejected`) are recorded by the submit and poll workers in slice 6.
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
audit, and exchange tables, and a contribution snapshot. Party data is the SDK's placeholder data, and certificates are
generated (`test_certificate!/1`). Authority calls answer from `Req.Test`
stubs set in `test_helper.exs`; no test reaches the authority. The SDK's
signed samples are in `test/fixtures/sdk/`, signed with the SDK's dummy test
certificate. `web_test/` covers the setup page against the real host.
