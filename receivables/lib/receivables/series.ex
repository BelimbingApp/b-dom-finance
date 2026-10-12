defmodule Bilimbi.Finance.Receivables.Series do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(invoice credit_note payment)

  schema "finance_receivables_series" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:code, :string)
    field(:name, :string)
    field(:kind, :string)
    field(:prefix, :string, default: "")
    field(:number_width, :integer, default: 1)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  @doc "The kinds of record a series numbers."
  def kinds, do: @kinds

  @doc "The reference a series gives its `number`th record: prefix and zero-padded number."
  def reference(%__MODULE__{prefix: prefix, number_width: width}, number),
    do: prefix <> String.pad_leading(Integer.to_string(number), width, "0")

  def create_changeset(series, attributes) do
    series
    |> cast(attributes, [:code, :name, :kind, :prefix, :number_width, :active])
    |> update_change(:code, &String.trim/1)
    |> update_change(:kind, &String.trim/1)
    |> put_blank_prefix(attributes)
    |> validate_required([:tenant_id, :company_id, :code, :kind, :number_width])
    |> validate_length(:code, min: 1, max: 50)
    |> validate_length(:prefix, max: 20)
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:number_width, greater_than_or_equal_to: 1, less_than_or_equal_to: 12)
    |> details()
    |> unique_constraint(:code, name: :finance_receivables_series_company_code_unique)
    |> unique_constraint(:prefix, name: :finance_receivables_series_company_prefix_unique)
  end

  # Code, kind, prefix, and width are the series' identity: the references
  # it has already given are built from them.
  def update_changeset(series, attributes) do
    series
    |> cast(attributes, [:name, :active])
    |> details()
  end

  # Ecto casts an empty string to nil; an empty prefix is a real choice here.
  defp put_blank_prefix(changeset, attributes) do
    case Map.get(attributes, :prefix, Map.get(attributes, "prefix")) do
      value when value in [nil, ""] -> put_change(changeset, :prefix, "")
      _value -> changeset
    end
  end

  defp details(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :active])
    |> validate_length(:name, min: 1, max: 200)
  end
end
