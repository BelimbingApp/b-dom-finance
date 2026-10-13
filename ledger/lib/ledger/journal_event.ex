defmodule Bilimbi.Finance.Ledger.JournalEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # The one decision on a journal: `approved` with the entry it posted, or
  # `rejected` with a reason. The database stamps it and refuses an approval
  # by the journal's submitter without its same-person exception.
  schema "finance_ledger_journal_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:journal_id, :integer)
    field(:event, :string)
    field(:reason, :string)
    field(:entry_id, :integer)
    field(:actor_user_id, :integer)
    field(:actor_impersonator_id, :integer)
    field(:occurred_at, :utc_datetime_usec, read_after_writes: true)
  end

  def changeset(event, attributes) do
    event
    |> cast(attributes, [:reason])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :journal_id, :event, :actor_user_id])
    |> validate_inclusion(:event, ~w(approved rejected))
    |> validate_length(:reason, max: 500)
    |> then(fn changeset ->
      if get_field(changeset, :event) == "rejected",
        do: validate_required(changeset, :reason, message: "is required to reject a journal"),
        else: changeset
    end)
    |> unique_constraint(:journal_id,
      name: :finance_ledger_journal_events_journal_unique,
      message: "is already decided"
    )
  end
end
