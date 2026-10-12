defmodule Bilimbi.Finance.Einvoice.Draft.Party do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Einvoice.Draft.Address

  @primary_key false
  embedded_schema do
    field(:name, :string)
    field(:tax_id, :string)
    field(:registration_type, :string)
    field(:registration_number, :string)
    field(:sales_tax_registration, :string)
    field(:email, :string)
    field(:phone, :string)
    embeds_one(:address, Address, on_replace: :update)
  end

  def changeset(party, attributes) do
    party
    |> cast(attributes, [
      :name,
      :tax_id,
      :registration_type,
      :registration_number,
      :sales_tax_registration,
      :email,
      :phone
    ])
    |> cast_embed(:address, required: true)
    |> validate_required([:name, :tax_id, :registration_type, :registration_number])
    |> validate_length(:name, max: 300)
    |> validate_length(:tax_id, max: 14)
    |> validate_length(:registration_number, max: 20)
    |> validate_length(:sales_tax_registration, max: 35)
    |> validate_length(:email, max: 320)
    |> validate_length(:phone, max: 20)
  end
end
