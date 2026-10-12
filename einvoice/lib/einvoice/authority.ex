defmodule Bilimbi.Finance.Einvoice.Authority do
  @moduledoc """
  The clearance authority a company's documents go to.

  The facade, tables, and pages speak only of fiscal documents, parties,
  submissions, and status events. Everything one authority defines (its
  rules, code lists, document format, signature, and API) sits behind this
  behaviour in that authority's own namespace.
  """

  @doc "The authority's stable ID, stored on each document and code list entry."
  @callback id() :: String.t()

  @doc "The document types `Bilimbi.Finance.Einvoice.issue_document/3` accepts."
  @callback issuable_document_types() :: [String.t()]

  @doc """
  Adds the authority's own errors to a valid `Draft` changeset: codes outside
  the company's code lists, fields its rules require, and a supplier profile
  missing what every document carries. `codes` returns one list's active
  codes for the company.
  """
  @callback validate(Ecto.Changeset.t(), supplier :: map(), codes :: (String.t() -> map())) ::
              Ecto.Changeset.t()

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
  @callback login(scope :: Bilimbi.Base.Tenancy.Scope.t(), company_id :: pos_integer(), map()) ::
              :ok | {:error, term()}

  @doc """
  The signed payload for a recorded document: its format, the format version,
  and the exact bytes to submit.
  """
  @callback payload(document :: map(), signing_key :: map(), signing_time :: DateTime.t()) ::
              %{format: String.t(), version: String.t(), bytes: binary()}
end
