defmodule Bilimbi.Finance.Payroll.PostingEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @source_kinds ~w(payroll_run claim)
  @events ~w(posted posting_failed reversed reversal_failed)

  schema "finance_payroll_posting_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:source_kind, :string)
    field(:source_id, :integer)
    field(:source_reference, :string)
    field(:event, :string)
    field(:entry_id, :integer)
    field(:entry_number, :integer)
    field(:entry_date, :date)
    field(:total, :decimal)
    field(:currency_code, :string)
    field(:reason, :string)
    field(:actor_user_id, :integer)
    field(:actor_impersonator_id, :integer)
    # The database stamps it on insert (see the migration).
    field(:occurred_at, :utc_datetime_usec, read_after_writes: true)
  end

  @doc "The source kinds: `payroll_run` and `claim`."
  def source_kinds, do: @source_kinds

  @doc "The events: `posted`, `posting_failed`, `reversed`, `reversal_failed`."
  def events, do: @events

  def changeset(event, attributes) do
    event
    |> cast(attributes, [
      :source_kind,
      :source_id,
      :source_reference,
      :event,
      :entry_id,
      :entry_number,
      :entry_date,
      :total,
      :currency_code,
      :reason
    ])
    |> update_change(:source_reference, &String.slice(&1, 0, 100))
    |> update_change(:reason, &(&1 && String.slice(&1, 0, 500)))
    |> validate_required([
      :tenant_id,
      :company_id,
      :source_kind,
      :source_id,
      :source_reference,
      :event,
      :actor_user_id
    ])
    |> validate_inclusion(:source_kind, @source_kinds)
    |> validate_inclusion(:event, @events)
    |> unique_constraint([:source_kind, :source_id],
      name: :finance_payroll_posting_events_posted_unique,
      error_key: :source_id,
      message: "is already posted"
    )
    |> unique_constraint([:source_kind, :source_id],
      name: :finance_payroll_posting_events_reversed_unique,
      error_key: :source_id,
      message: "is already reversed"
    )
    |> unique_constraint(:entry_id, name: :finance_payroll_posting_events_entry_unique)
  end
end
