defmodule Bilimbi.Finance.Receivables.Document do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Receivables.{DocumentLine, TaxLine, Text}

  @kinds ~w(invoice credit_note)

  schema "finance_receivables_documents" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:kind, :string)
    field(:status, :string, default: "draft")
    field(:series_id, :integer)
    field(:customer_id, :integer)
    field(:credited_document_id, :integer)
    field(:receivable_account_id, :integer)
    field(:currency_code, :string)
    field(:issue_date, :date)
    field(:due_date, :date)
    field(:description, :string)
    field(:subtotal, :decimal)
    field(:tax_total, :decimal)
    field(:total, :decimal)
    field(:document_number, :integer)
    field(:document_reference, :string)
    field(:party_name, :string)
    field(:party_tax_identifier, :string)
    field(:party_registration_identifier, :string)
    field(:party_email, :string)
    field(:party_phone, :string)
    field(:party_line1, :string)
    field(:party_line2, :string)
    field(:party_line3, :string)
    field(:party_locality, :string)
    field(:party_postcode, :string)
    field(:party_admin1_code, :string)
    field(:party_country_iso, :string)
    field(:ledger_entry_id, :integer)
    field(:ledger_entry_number, :integer)
    field(:issued_by_user_id, :integer)
    field(:issued_by_impersonator_id, :integer)
    # The database stamps both (see the migration).
    field(:issued_at, :utc_datetime_usec, read_after_writes: true)
    field(:discarded_by_user_id, :integer)
    field(:discarded_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:lines, DocumentLine, on_replace: :delete)
    has_many(:tax_lines, TaxLine, on_replace: :delete)
    timestamps(type: :naive_datetime)
  end

  @doc "The kinds of document: an invoice, and the credit note that corrects one."
  def kinds, do: @kinds

  def create_changeset(document, attributes) do
    document
    |> cast(attributes, [:kind])
    |> update_change(:kind, &Text.trim/1)
    |> validate_required([:kind])
    |> validate_inclusion(:kind, @kinds)
    |> draft_changeset(attributes)
  end

  def update_changeset(document, attributes),
    do: document |> change() |> draft_changeset(attributes)

  # The kind is fixed once the draft exists; only a credit note names the
  # invoice it credits.
  defp draft_changeset(changeset, attributes) do
    fields =
      [:series_id, :customer_id, :issue_date, :due_date, :description] ++
        if(get_field(changeset, :kind) == "credit_note", do: [:credited_document_id], else: [])

    changeset
    |> cast(attributes, fields)
    |> update_change(:description, &Text.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :currency_code,
      :series_id,
      :customer_id
    ])
    |> validate_length(:description, max: 500)
    |> validate_credit_note()
    |> validate_due_date()
  end

  defp validate_credit_note(changeset) do
    if get_field(changeset, :kind) == "credit_note",
      do: validate_required(changeset, [:credited_document_id]),
      else: changeset
  end

  defp validate_due_date(changeset) do
    issue_date = get_field(changeset, :issue_date)
    due_date = get_field(changeset, :due_date)

    if issue_date && due_date && Date.before?(due_date, issue_date),
      do: add_error(changeset, :due_date, "cannot be before the issue date"),
      else: changeset
  end
end
