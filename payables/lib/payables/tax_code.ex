defmodule Bilimbi.Finance.Payables.TaxCode do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # numeric(7, 4): a percentage below 1000 with four decimal places.
  @rate_limit Decimal.new(1000)

  schema "finance_payables_tax_codes" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:rate, :decimal)
    field(:account_id, :integer)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  def create_changeset(tax_code, attributes) do
    tax_code
    |> cast(attributes, [:code, :name, :rate, :account_id, :active])
    |> update_change(:code, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :code])
    |> validate_length(:code, min: 1, max: 50)
    |> details()
    |> unique_constraint(:code, name: :finance_payables_tax_codes_company_code_unique)
  end

  # The code identifies the tax code on every document that used it.
  def update_changeset(tax_code, attributes) do
    tax_code
    |> cast(attributes, [:name, :rate, :account_id, :active])
    |> details()
  end

  defp details(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :rate, :account_id, :active])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_number(:rate, greater_than_or_equal_to: 0, less_than: @rate_limit)
    |> validate_change(:rate, fn :rate, rate ->
      if Decimal.equal?(Decimal.round(rate, 4), rate),
        do: [],
        else: [rate: "has more than 4 decimal places"]
    end)
  end
end
