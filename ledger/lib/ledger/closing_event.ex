defmodule Bilimbi.Finance.Ledger.ClosingEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @actions ~w(close reopen lock)

  # One entry in a company's closing log: a period's or (with no period) a
  # fiscal year's close, reopen, or lock. The log is append-only, and the
  # latest event decides each status.
  schema "finance_ledger_closing_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    # The database assigns both on insert (see the migration).
    field(:event_number, :integer, read_after_writes: true)
    field(:fiscal_year_id, :integer)
    field(:period_id, :integer)
    field(:action, :string)
    field(:reason, :string)
    field(:entry_id, :integer)
    field(:retained_earnings_account_id, :integer)
    field(:recorded_by_user_id, :integer)
    field(:recorded_by_impersonator_id, :integer)
    field(:recorded_at, :utc_datetime_usec, read_after_writes: true)
  end

  def actions, do: @actions

  @doc "The status an event leaves its period or year in; no event leaves it open."
  def status_after("close"), do: "closed"
  def status_after("lock"), do: "locked"
  def status_after(action) when action in ["reopen", nil], do: "open"

  @doc "Casts the caller's `reason`; a reopen needs one."
  def changeset(event, attributes) do
    event
    |> cast(attributes, [:reason])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :fiscal_year_id,
      :action,
      :recorded_by_user_id
    ])
    |> validate_inclusion(:action, @actions)
    |> validate_length(:reason, max: 500)
    |> validate_reason()
  end

  defp validate_reason(changeset) do
    if get_field(changeset, :action) == "reopen",
      do: validate_required(changeset, :reason, message: "is required to reopen"),
      else: changeset
  end
end
