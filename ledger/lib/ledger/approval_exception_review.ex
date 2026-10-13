defmodule Bilimbi.Finance.Ledger.ApprovalExceptionReview do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # An independent reviewer's reading of one approval exception, appended
  # once. The database stamps it and refuses a reviewer who approved or
  # prepared what the exception records (see the migration).
  schema "finance_ledger_approval_exception_reviews" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:exception_id, :integer)
    field(:note, :string)
    field(:reviewed_by_user_id, :integer)
    field(:reviewed_by_impersonator_id, :integer)
    field(:reviewed_at, :utc_datetime_usec, read_after_writes: true)
  end

  def changeset(review, attributes) do
    review
    |> cast(attributes, [:note])
    |> update_change(:note, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :exception_id, :reviewed_by_user_id])
    |> validate_length(:note, max: 500)
    |> unique_constraint(:exception_id,
      name: :finance_ledger_approval_exception_reviews_exception_unique,
      message: "is already reviewed"
    )
  end
end
