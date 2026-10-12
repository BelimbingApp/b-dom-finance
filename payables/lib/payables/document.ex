defmodule Bilimbi.Finance.Payables.Document do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Payables.{DocumentLine, TaxLine}

  @types ~w(bill debit_note)
  @statuses ~w(draft approved posted voided)

  schema "finance_payables_documents" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:document_type, :string)
    field(:status, :string)
    # The database assigns the number and every step's time (see the migration).
    field(:document_number, :integer, read_after_writes: true)
    field(:corrects_document_id, :integer)
    field(:party_key, :string)
    field(:party_name, :string)
    field(:party_tax_id, :string)
    field(:party_registration_id, :string)
    field(:party_address, :string)
    field(:party_document_number, :string)
    field(:document_date, :date)
    field(:due_date, :date)
    field(:currency_code, :string)
    field(:description, :string)
    field(:total_net, :decimal)
    field(:total_tax, :decimal)
    field(:total, :decimal)
    field(:created_by_user_id, :integer)
    field(:created_by_impersonator_id, :integer)
    field(:created_at, :utc_datetime_usec, read_after_writes: true)
    field(:approved_by_user_id, :integer)
    field(:approved_by_impersonator_id, :integer)
    field(:approved_at, :utc_datetime_usec, read_after_writes: true)
    field(:posted_by_user_id, :integer)
    field(:posted_by_impersonator_id, :integer)
    field(:posted_at, :utc_datetime_usec, read_after_writes: true)
    field(:payable_account_id, :integer)
    field(:entry_id, :integer)
    field(:entry_number, :integer)
    field(:voided_by_user_id, :integer)
    field(:voided_by_impersonator_id, :integer)
    field(:voided_at, :utc_datetime_usec, read_after_writes: true)
    field(:void_reason, :string)
    has_many(:lines, DocumentLine)
    has_many(:tax_lines, TaxLine)
  end

  def types, do: @types
  def statuses, do: @statuses

  @doc """
  A draft's party snapshot, dates, and description. A bill needs the party's
  own document number; the due date defaults to the document date.
  """
  def changeset(document, attributes) do
    document
    |> cast(attributes, [
      :party_key,
      :party_name,
      :party_tax_id,
      :party_registration_id,
      :party_address,
      :party_document_number,
      :document_date,
      :due_date,
      :description
    ])
    |> trim([
      :party_key,
      :party_name,
      :party_tax_id,
      :party_registration_id,
      :party_address,
      :party_document_number,
      :description
    ])
    |> default_due_date()
    |> validate_required([
      :tenant_id,
      :company_id,
      :document_type,
      :party_key,
      :party_name,
      :document_date,
      :due_date,
      :currency_code,
      :created_by_user_id
    ])
    |> then(fn changeset ->
      if get_field(changeset, :document_type) == "bill",
        do: validate_required(changeset, [:party_document_number]),
        else: changeset
    end)
    |> validate_length(:party_key, min: 1, max: 100)
    |> validate_length(:party_name, min: 1, max: 200)
    |> validate_length(:party_tax_id, max: 50)
    |> validate_length(:party_registration_id, max: 50)
    |> validate_length(:party_address, max: 1000)
    |> validate_length(:party_document_number, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_due_date()
    |> unique_constraint(:party_document_number,
      name: :finance_payables_documents_party_document_unique,
      message: "is already recorded for this party"
    )
  end

  defp validate_due_date(changeset) do
    with %Date{} = date <- get_field(changeset, :document_date),
         %Date{} = due_date <- get_field(changeset, :due_date),
         :lt <- Date.compare(due_date, date) do
      add_error(changeset, :due_date, "cannot be before the document date")
    else
      _ordered -> changeset
    end
  end

  defp default_due_date(changeset) do
    if is_nil(get_field(changeset, :due_date)),
      do: put_change(changeset, :due_date, get_field(changeset, :document_date)),
      else: changeset
  end

  defp trim(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      update_change(changeset, field, fn
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> nil
            trimmed -> trimmed
          end

        value ->
          value
      end)
    end)
  end

  def void_changeset(document, attributes, actor) do
    document
    |> cast(attributes, [:void_reason])
    |> trim([:void_reason])
    |> put_change(:status, "voided")
    |> put_change(:voided_by_user_id, actor.user_id)
    |> put_change(:voided_by_impersonator_id, actor.impersonator_id)
    |> validate_required([:void_reason])
    |> validate_length(:void_reason, max: 500)
  end
end
