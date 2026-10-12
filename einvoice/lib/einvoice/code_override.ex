defmodule Bilimbi.Finance.Einvoice.CodeOverride do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_einvoice_code_overrides" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:authority, :string)
    field(:list, :string)
    field(:code, :string)
    field(:description, :string)
    field(:active, :boolean, default: true)
    timestamps(type: :naive_datetime)
  end

  def changeset(override, attributes) do
    override
    |> cast(attributes, [:description, :active])
    |> update_change(:description, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :authority, :list, :code, :active])
    |> validate_length(:description, min: 1, max: 500)
    |> unique_constraint([:company_id, :authority, :list, :code],
      name: :finance_einvoice_code_overrides_unique
    )
  end
end
