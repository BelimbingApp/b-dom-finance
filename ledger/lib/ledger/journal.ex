defmodule Bilimbi.Finance.Ledger.Journal do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Ledger.{JournalEvent, JournalLine}

  # A manual journal submitted for approval. It posts as an entry only when
  # someone approves it; its event decides its status. The database numbers
  # and stamps it (see the migration).
  schema "finance_ledger_journals" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:journal_number, :integer, read_after_writes: true)
    field(:entry_date, :date)
    field(:description, :string)
    field(:reference, :string)
    field(:currency_code, :string)
    field(:submitted_by_user_id, :integer)
    field(:submitted_by_impersonator_id, :integer)
    field(:submitted_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:lines, JournalLine)
    has_one(:event, JournalEvent)
  end

  @doc "A journal is `submitted` until its one event approves or rejects it."
  def status(%__MODULE__{event: nil}), do: "submitted"
  def status(%__MODULE__{event: %JournalEvent{event: event}}), do: event

  def statuses, do: ~w(submitted approved rejected)

  def changeset(journal, attributes) do
    journal
    |> cast(attributes, [:entry_date, :description, :reference])
    |> update_change(:description, &String.trim/1)
    |> update_change(:reference, &String.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :entry_date,
      :description,
      :currency_code,
      :submitted_by_user_id
    ])
    |> validate_length(:description, min: 1, max: 500)
    |> validate_length(:reference, max: 100)
  end
end
