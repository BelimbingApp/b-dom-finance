defmodule Bilimbi.Finance.Sst.ReturnEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Sst.Text

  @actions ~w(opened finalised discarded)

  # The database numbers and stamps an event, and gives a finalised one its
  # version (see the migration).
  schema "finance_sst_return_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:event_number, :integer, read_after_writes: true)
    field(:return_id, :integer)
    field(:action, :string)
    field(:reason, :string)
    field(:version, :integer, read_after_writes: true)
    field(:through_entry_number, :integer)
    field(:through_mapping_number, :integer)
    field(:through_adjustment_number, :integer)
    field(:currency_code, :string)
    field(:minor_units, :integer)
    field(:tax_payable, :decimal)
    field(:recorded_by_user_id, :integer)
    field(:recorded_by_impersonator_id, :integer)
    field(:recorded_at, :utc_datetime_usec, read_after_writes: true)
  end

  def actions, do: @actions

  def changeset(event, attributes) do
    event
    |> cast(attributes, [:reason])
    |> update_change(:reason, &Text.blank_to_nil/1)
    |> validate_length(:reason, max: 500)
    |> validate_required([:tenant_id, :company_id, :return_id, :action, :recorded_by_user_id])
    |> validate_inclusion(:action, @actions)
    |> validate_reason()
  end

  defp validate_reason(changeset) do
    if get_field(changeset, :action) == "discarded" and is_nil(get_field(changeset, :reason)),
      do: add_error(changeset, :reason, "is needed to discard a return"),
      else: changeset
  end
end
