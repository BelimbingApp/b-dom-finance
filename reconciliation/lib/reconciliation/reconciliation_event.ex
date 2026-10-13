defmodule Bilimbi.Finance.Reconciliation.ReconciliationEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @actions ~w(opened finalised abandoned)

  # The database numbers and stamps an event (see the migration).
  schema "finance_reconciliation_reconciliation_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:event_number, :integer, read_after_writes: true)
    field(:reconciliation_id, :integer)
    field(:action, :string)
    field(:reason, :string)
    field(:book_balance, :decimal)
    field(:difference, :decimal)
    field(:through_entry_number, :integer)
    field(:through_statement_number, :integer)
    field(:through_match_event_number, :integer)
    field(:recorded_by_user_id, :integer)
    field(:recorded_by_impersonator_id, :integer)
    field(:recorded_at, :utc_datetime_usec, read_after_writes: true)
  end

  def actions, do: @actions

  def changeset(event, attributes) do
    event
    |> cast(attributes, [:reason])
    |> update_change(:reason, &blank_to_nil/1)
    |> validate_length(:reason, max: 500)
    |> validate_required([
      :tenant_id,
      :company_id,
      :reconciliation_id,
      :action,
      :recorded_by_user_id
    ])
    |> validate_inclusion(:action, @actions)
    |> validate_reason()
  end

  defp validate_reason(changeset) do
    if get_field(changeset, :action) == "abandoned" and is_nil(get_field(changeset, :reason)),
      do: add_error(changeset, :reason, "is needed to abandon a reconciliation"),
      else: changeset
  end

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
