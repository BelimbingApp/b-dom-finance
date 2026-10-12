defmodule Bilimbi.Finance.Ledger.Entry do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Ledger.Line

  schema "finance_ledger_entries" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    # The database assigns both on insert (see the migration).
    field(:entry_number, :integer, read_after_writes: true)
    field(:entry_date, :date)
    field(:description, :string)
    field(:reference, :string)
    field(:currency_code, :string)
    field(:reverses_entry_id, :integer)
    field(:posted_by_user_id, :integer)
    field(:posted_by_impersonator_id, :integer)
    field(:posted_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:lines, Line)
  end

  def changeset(entry, attributes) do
    entry
    |> cast(attributes, [:entry_date, :description, :reference])
    |> update_change(:description, &String.trim/1)
    |> update_change(:reference, &String.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :entry_date,
      :description,
      :currency_code,
      :posted_by_user_id
    ])
    |> validate_length(:description, min: 1, max: 500)
    |> validate_length(:reference, max: 100)
    |> unique_constraint(:reverses_entry_id, name: :finance_ledger_entries_reversed_once)
  end
end
