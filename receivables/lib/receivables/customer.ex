defmodule Bilimbi.Finance.Receivables.Customer do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # The party fields a document snapshots when it is issued. The address
  # fields follow Core Address's names.
  @party_fields [
    :name,
    :tax_identifier,
    :registration_identifier,
    :email,
    :phone,
    :line1,
    :line2,
    :line3,
    :locality,
    :postcode,
    :admin1_code,
    :country_iso
  ]

  @lengths %{
    name: 200,
    tax_identifier: 50,
    registration_identifier: 50,
    email: 255,
    phone: 50,
    line1: 255,
    line2: 255,
    line3: 255,
    locality: 100,
    postcode: 20,
    admin1_code: 20
  }

  schema "finance_receivables_customers" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:tax_identifier, :string)
    field(:registration_identifier, :string)
    field(:email, :string)
    field(:phone, :string)
    field(:line1, :string)
    field(:line2, :string)
    field(:line3, :string)
    field(:locality, :string)
    field(:postcode, :string)
    field(:admin1_code, :string)
    field(:country_iso, :string)
    field(:payment_terms_days, :integer, default: 0)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  @doc "The fields an issued document copies from its customer."
  def party_fields, do: @party_fields

  def create_changeset(customer, attributes) do
    customer
    |> cast(attributes, [:code | details_fields()])
    |> update_change(:code, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :code])
    |> validate_length(:code, min: 1, max: 50)
    |> details()
    |> unique_constraint(:code, name: :finance_receivables_customers_company_code_unique)
  end

  # The code is the customer's identity; everything else may change, and an
  # issued document keeps the party as it was when it was issued.
  def update_changeset(customer, attributes) do
    customer
    |> cast(attributes, details_fields())
    |> details()
  end

  defp details_fields, do: @party_fields ++ [:payment_terms_days, :active]

  defp details(changeset) do
    changeset =
      Enum.reduce(@party_fields, changeset, fn field, acc ->
        update_change(acc, field, &String.trim/1)
      end)

    changeset
    |> update_change(:country_iso, &String.upcase/1)
    |> validate_required([:name, :payment_terms_days, :active])
    |> validate_length(:name, min: 1)
    |> validate_lengths()
    |> validate_format(:country_iso, ~r/^[A-Z]{2}$/)
    |> validate_number(:payment_terms_days,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 3650
    )
  end

  defp validate_lengths(changeset) do
    Enum.reduce(@lengths, changeset, fn {field, max}, acc ->
      validate_length(acc, field, max: max)
    end)
  end
end
