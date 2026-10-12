defmodule Bilimbi.Finance.Einvoice.Authority do
  @moduledoc """
  The clearance authority a company's documents go to.

  The facade, tables, workers, and pages speak only of fiscal documents,
  parties, submissions, and status events. Everything one authority defines
  (its rules, code lists, document format, signature, API, and the shape of
  its answers) sits behind this behaviour in that authority's own namespace.
  Each API callback returns the authority's answer in meta-terms, with the
  raw response kept beside it so the caller can store it as the record.
  """

  alias Bilimbi.Base.Tenancy.Scope

  @typedoc """
  An answer the authority gave, kept whole: the HTTP status and decoded
  body (both `nil` when the authority was never reached), the seconds it
  asked the caller to wait, and a short reason in the authority's words.
  """
  @type answer :: %{
          optional(:http_status) => pos_integer() | nil,
          optional(:response) => term(),
          optional(:retry_after) => non_neg_integer() | nil,
          optional(:reason) => String.t() | nil,
          optional(atom()) => term()
        }

  @typedoc """
  What became of a submitted document: `:accepted` carries the submission
  and document identifiers; `:rejected` means the authority took the
  submission but refused this document; `:refused` a request the authority
  explained; `:duplicate` the same bytes submitted again inside the
  authority's window; `:rate_limited` a breach of its limits; and
  `:unavailable` an outage or transport failure worth retrying.
  """
  @type submission_outcome ::
          {:accepted, answer()}
          | {:rejected, answer()}
          | {:refused, answer()}
          | {:duplicate, answer()}
          | {:rate_limited, answer()}
          | {:unavailable, answer()}

  @typedoc "A document's status as the authority reports it."
  @type document_status :: :submitted | :valid | :invalid | :cancelled

  @doc "The authority's stable ID, stored on each document and code list entry."
  @callback id() :: String.t()

  @doc "The document types `Bilimbi.Finance.Einvoice.issue_document/3` accepts."
  @callback issuable_document_types() :: [String.t()]

  @doc "The document types that reference an original document (credit, debit, and refund notes)."
  @callback note_document_types() :: [String.t()]

  @doc """
  How a validated document of this type posts to the ledger: the side
  (`:debit` or `:credit`) the document's counter-account takes, and which
  account that is, the `:receivable_account` or the `:settlement_account`.
  Revenue and tax take the opposite side. `nil` for a type with no rule.
  """
  @callback posting_rule(document_type :: String.t()) ::
              {:debit | :credit, :receivable_account | :settlement_account} | nil

  @doc "The human name of a document type, as the pages and the PDF show it."
  @callback document_type_name(document_type :: String.t()) :: String.t()

  @doc "Hours after validation in which the supplier may still cancel a document."
  @callback cancellation_window_hours() :: pos_integer()

  @doc "Hours of unbroken outage after which an operator is told a submission is overdue."
  @callback outage_notice_hours() :: pos_integer()

  @doc "The document format versions a company may choose, and whether each needs a signature."
  @callback document_versions() :: [%{version: String.t(), signed: boolean()}]

  @doc """
  Adds the authority's own errors to a valid `Draft` changeset: codes outside
  the company's code lists, fields its rules require, a supplier profile
  missing what every document carries, and a note whose original is not
  one the authority lets it reference. `context` carries `supplier`,
  `codes` (one list's active codes for the company), and `original` (the
  original document's view, or `nil`).
  """
  @callback validate(Ecto.Changeset.t(), context :: map()) :: Ecto.Changeset.t()

  @doc """
  Whether `value` has the shape the authority requires of a field of this
  kind: `:tax_id`, `:phone`, `:industry_code`, `:state_code`, or
  `:country_code`. Settings validators and document validation both ask here.
  """
  @callback valid_format?(kind :: atom(), value :: term()) :: boolean()

  @doc "What `valid_format?/2` requires of a field of this kind, for an error message."
  @callback format_message(kind :: atom()) :: String.t()

  @doc "The supplier profile fields every document carries that `supplier` leaves blank."
  @callback supplier_missing(supplier :: map()) :: [atom()]

  @doc """
  The tax ID and registration number a signing certificate's subject
  carries, as the authority writes them there.
  """
  @callback certificate_identity(subject :: map()) :: %{
              tax_id: String.t() | nil,
              registration_number: String.t() | nil
            }

  @doc """
  Logs in to the authority with the company's credentials: `:ok`, or
  `{:error, reason}` where `reason` is `:missing_credentials`,
  `{:http, status, body}`, or `{:transport, exception}`.
  """
  @callback login(scope :: Scope.t(), company_id :: pos_integer(), map()) ::
              :ok | {:error, term()}

  @doc """
  The payload for a recorded document in `version` of the authority's
  format: its format, version, and the exact bytes to submit. A version
  that needs a signature takes `signing_key` (`%{certificate, key}`) and is
  `{:error, :signing_key_required}` without one.
  """
  @callback payload(
              document :: map(),
              options :: %{version: String.t(), signing_key: map() | nil},
              signing_time :: DateTime.t()
            ) ::
              {:ok, %{format: String.t(), version: String.t(), bytes: binary()}}
              | {:error, :signing_key_required | :unsupported_version}

  @doc "Submits one document's payload (`%{format, bytes, code_number}`) and reports what became of it."
  @callback submit(Scope.t(), pos_integer(), credentials :: map(), payload :: map()) ::
              submission_outcome()

  @doc """
  Whether a submission has finished processing: `{:done, answer}` or
  `{:in_progress, answer}`, or `{:refused | :rate_limited | :unavailable,
  answer}`.
  """
  @callback submission_progress(Scope.t(), pos_integer(), credentials :: map(), String.t()) ::
              {:done | :in_progress | :refused | :rate_limited | :unavailable, answer()}

  @doc """
  Looks up a document the authority may already hold, by the company's code
  number, among what the submitter sent between `since` and `until`,
  leaving out any whose document UUID is in `exclude` (identifiers this
  document already recorded, which belong to an earlier cycle):
  `{:found, answer}` where the answer carries `submission_uid` and
  `document_uuid` and the authority's own entry as `response`, or
  `{:not_found | :refused | :rate_limited | :unavailable, answer}`. Used
  after a duplicate or an unknown outcome, so a submission is never
  repeated once the authority accepted it.
  """
  @callback find_submission(
              Scope.t(),
              pos_integer(),
              credentials :: map(),
              lookup :: %{
                required(:code_number) => String.t(),
                required(:since) => DateTime.t(),
                required(:until) => DateTime.t(),
                optional(:exclude) => [String.t()]
              }
            ) ::
              {:found | :not_found | :refused | :rate_limited | :unavailable, answer()}

  @doc """
  A document's current status: `{:ok, answer}` where the answer carries
  `status` (`t:document_status/0`), `long_id`, `validated_at`,
  `rejection_requested_at`, and `reason`; or `{:refused | :rate_limited |
  :unavailable, answer}`.
  """
  @callback document_status(Scope.t(), pos_integer(), credentials :: map(), String.t()) ::
              {:ok | :refused | :rate_limited | :unavailable, answer()}

  @doc """
  Cancels a validated document with a reason: `{:ok, answer}`, or
  `{:refused, answer}` whose `reason_code` is `:period_over`,
  `:incorrect_state`, `:active_referencing_documents`, or `:other`, or
  `{:rate_limited | :unavailable, answer}`.
  """
  @callback cancel(Scope.t(), pos_integer(), credentials :: map(), String.t(), String.t()) ::
              {:ok | :refused | :rate_limited | :unavailable, answer()}

  @doc "The public link that shows a validated document on the authority's portal."
  @callback validation_url(
              environment :: String.t(),
              document_uuid :: String.t(),
              long_id :: String.t()
            ) ::
              String.t()
end
