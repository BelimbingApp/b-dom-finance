defmodule Bilimbi.Finance.Receivables.SetupChange do
  @moduledoc false
  use Ecto.Schema

  # One account of the setup being set or changed. Append-only: the
  # database refuses to update or delete a row.
  schema "finance_receivables_setup_changes" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:field, :string)
    field(:old_value, :integer)
    field(:new_value, :integer)
    field(:changed_by_user_id, :integer)
    field(:changed_by_impersonator_id, :integer)
    # The database stamps it on insert (see the migration).
    field(:changed_at, :utc_datetime_usec, read_after_writes: true)
  end
end
