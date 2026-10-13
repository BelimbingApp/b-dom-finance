defmodule Bilimbi.Finance.Payables.MatchEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Payables.MatchLine

  @events ~w(held exception_approved posted)

  schema "finance_payables_match_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:document_id, :integer)
    field(:event, :string)
    field(:reason, :string)
    field(:held_event_id, :integer)
    field(:actor_user_id, :integer)
    field(:actor_impersonator_id, :integer)
    # The database stamps it on insert (see the migration).
    field(:occurred_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:lines, MatchLine, foreign_key: :event_id)
  end

  def events, do: @events

  def changeset(event, attributes) do
    event
    |> cast(attributes, [:reason, :held_event_id])
    |> update_change(:reason, &String.trim/1)
    |> validate_length(:reason, max: 500)
    |> validate_required([:tenant_id, :company_id, :document_id, :event, :actor_user_id])
    |> validate_inclusion(:event, @events)
    |> then(fn changeset ->
      if get_field(changeset, :event) == "exception_approved",
        do: validate_required(changeset, [:reason, :held_event_id]),
        else: changeset
    end)
  end
end
