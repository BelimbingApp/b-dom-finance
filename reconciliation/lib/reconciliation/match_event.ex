defmodule Bilimbi.Finance.Reconciliation.MatchEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @actions ~w(matched unmatched)

  # The database numbers and stamps an event (see the migration).
  schema "finance_reconciliation_match_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:event_number, :integer, read_after_writes: true)
    field(:match_id, :integer)
    field(:action, :string)
    field(:reason, :string)
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
    |> validate_required([:tenant_id, :company_id, :match_id, :action, :recorded_by_user_id])
    |> validate_inclusion(:action, @actions)
    |> validate_reason()
  end

  defp validate_reason(changeset) do
    if get_field(changeset, :action) == "unmatched" and is_nil(get_field(changeset, :reason)),
      do: add_error(changeset, :reason, "is needed to unmatch"),
      else: changeset
  end

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
