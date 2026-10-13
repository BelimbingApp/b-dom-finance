defmodule Bilimbi.Finance.Ledger.ApprovalException do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Ledger.ApprovalExceptionReview

  @code ~r/^[a-z][a-z0-9_]*$/
  @source ~r/^[a-z][a-z0-9_\/-]*$/

  # One approval an independent reviewer should read: a same-person approval
  # while separation is off, or an override of a control. The database
  # numbers and stamps it and checks its kind (see the migration).
  schema "finance_ledger_approval_exceptions" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:exception_number, :integer, read_after_writes: true)
    field(:source, :string)
    field(:action, :string)
    field(:subject_type, :string)
    field(:subject_id, :integer)
    field(:subject, :string)
    field(:same_person, :boolean)
    field(:override, :boolean)
    field(:prepared_by_user_id, :integer)
    field(:prepared_by_impersonator_id, :integer)
    field(:approved_by_user_id, :integer)
    field(:approved_by_impersonator_id, :integer)
    field(:reason, :string)
    field(:separation_change_id, :integer)
    field(:recorded_at, :utc_datetime_usec, read_after_writes: true)
    has_one(:review, ApprovalExceptionReview, foreign_key: :exception_id)
  end

  def changeset(exception, attributes) do
    exception
    |> cast(attributes, [:source, :action, :subject_type, :subject_id, :subject, :reason])
    |> update_change(:subject, &(&1 |> String.trim() |> String.slice(0, 200)))
    |> update_change(:reason, &String.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :source,
      :action,
      :subject_type,
      :subject_id,
      :subject,
      :same_person,
      :override,
      :approved_by_user_id,
      :reason
    ])
    |> validate_format(:source, @source)
    |> validate_format(:action, @code)
    |> validate_format(:subject_type, @code)
    |> validate_length(:source, max: 64)
    |> validate_length(:action, max: 40)
    |> validate_length(:subject_type, max: 40)
    |> validate_number(:subject_id, greater_than: 0)
    |> validate_length(:reason, max: 500)
  end
end
