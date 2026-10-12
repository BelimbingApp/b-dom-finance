defmodule Bilimbi.Finance.Einvoice.Draft.Address do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:lines, {:array, :string}, default: [])
    field(:city, :string)
    field(:postcode, :string)
    field(:state_code, :string)
    field(:country_code, :string)
  end

  def changeset(address, attributes) do
    address
    |> cast(attributes, [:lines, :city, :postcode, :state_code, :country_code])
    |> update_change(:lines, fn lines ->
      lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end)
    |> validate_required([:lines, :city, :state_code, :country_code])
    |> validate_length(:lines, min: 1, max: 3)
    |> validate_change(:lines, fn :lines, lines ->
      if Enum.all?(lines, &(String.length(&1) <= 150)),
        do: [],
        else: [lines: "each line must be at most 150 characters"]
    end)
    |> validate_length(:city, max: 50)
    |> validate_length(:postcode, max: 50)
  end
end
