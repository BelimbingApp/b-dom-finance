defmodule Bilimbi.Finance.Ledger.Book do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_ledger_books" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:currency_code, :string)
    field(:minor_units, :integer)
    timestamps(type: :naive_datetime, updated_at: false)
  end

  def changeset(book, attributes) do
    book
    |> cast(attributes, [:currency_code, :minor_units])
    |> update_change(:currency_code, &(&1 |> String.trim() |> String.upcase()))
    |> validate_required([:tenant_id, :company_id, :currency_code, :minor_units])
    |> validate_format(:currency_code, ~r/^[A-Z]{3}$/)
    |> validate_number(:minor_units, greater_than_or_equal_to: 0, less_than_or_equal_to: 4)
    |> unique_constraint(:company_id, name: :finance_ledger_books_company_unique)
  end
end
