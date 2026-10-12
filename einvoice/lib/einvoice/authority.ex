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
  The signed payload for a recorded document: its format, the format version,
  and the exact bytes to submit.
  """
  @callback payload(document :: map(), signing_key :: map(), signing_time :: DateTime.t()) ::
              %{format: String.t(), version: String.t(), bytes: binary()}
end
