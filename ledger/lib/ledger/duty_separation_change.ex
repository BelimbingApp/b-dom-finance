defmodule Bilimbi.Finance.Ledger.DutySeparationChange do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # One change to a company's duty separation setting. The changes are
  # append-only and the latest decides; with none, separation is required.
  # The database numbers and stamps a change (see the migration).
  schema "finance_ledger_duty_separation_changes" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:change_number, :integer, read_after_writes: true)
    field(:required, :boolean)
    field(:reason, :string)
    field(:changed_by_user_id, :integer)
    field(:changed_by_impersonator_id, :integer)
    field(:changed_at, :utc_datetime_usec, read_after_writes: true)
  end

  @doc "Whether the latest change (or none) requires separation."
  def required?(nil), do: true
  def required?(%__MODULE__{required: required}), do: required

  @doc "Casts `required` and `reason`; turning separation off needs a reason."
  def changeset(change, attributes) do
    change
    |> cast(attributes, [:required, :reason])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :required, :changed_by_user_id])
    |> validate_length(:reason, max: 500)
    |> then(fn changeset ->
      if get_field(changeset, :required) == false,
        do: validate_required(changeset, :reason, message: "is required to turn separation off"),
        else: changeset
    end)
  end
end
