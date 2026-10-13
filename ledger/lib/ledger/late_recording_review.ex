defmodule Bilimbi.Finance.Ledger.LateRecordingReview do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # An independent reviewer's explanation of an entry recorded late. Appended
  # once per entry; the database stamps the time (see the migration).
  schema "finance_ledger_late_recording_reviews" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:entry_id, :integer)
    field(:reason, :string)
    field(:reviewed_by_user_id, :integer)
    field(:reviewed_by_impersonator_id, :integer)
    field(:reviewed_at, :utc_datetime_usec, read_after_writes: true)
  end

  @doc "Casts the reason, which every review needs."
  def changeset(review, attributes) do
    review
    |> cast(attributes, [:reason])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :entry_id, :reviewed_by_user_id, :reason])
    |> validate_length(:reason, max: 500)
  end
end
