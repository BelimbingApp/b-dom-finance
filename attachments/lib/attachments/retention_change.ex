defmodule Bilimbi.Finance.Attachments.RetentionChange do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # One change of a company's retention setting: the years a source document
  # is kept after the end of its financial year. The latest change is the
  # setting; the database numbers and stamps it and refuses a shorter one.
  schema "finance_attachments_retention_changes" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:change_number, :integer, read_after_writes: true)
    field(:years, :integer)
    field(:reason, :string)
    field(:changed_by_user_id, :integer)
    field(:changed_by_impersonator_id, :integer)
    field(:changed_at, :utc_datetime_usec, read_after_writes: true)
  end

  def changeset(change, attributes) do
    change
    |> cast(attributes, [:years, :reason])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :years, :reason, :changed_by_user_id])
    |> validate_number(:years, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_length(:reason, min: 1, max: 500)
  end
end
