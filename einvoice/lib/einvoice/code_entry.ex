defmodule Bilimbi.Finance.Einvoice.CodeEntry do
  @moduledoc false
  use Ecto.Schema

  schema "finance_einvoice_code_entries" do
    field(:authority, :string)
    field(:list, :string)
    field(:code, :string)
    field(:description, :string)
    timestamps(type: :naive_datetime)
  end
end
