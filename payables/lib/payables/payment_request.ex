defmodule Bilimbi.Finance.Payables.PaymentRequest do
  @moduledoc false
  use Ecto.Schema

  alias Bilimbi.Finance.Payables.{PaymentRequestAllocation, PaymentRequestEvent}

  # A payment submitted for approval, built from a payment changeset that
  # passed every check. It posts only when someone approves it; its one event
  # decides its status. The database numbers and stamps it (see the
  # migration).
  schema "finance_payables_payment_requests" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:request_number, :integer, read_after_writes: true)
    field(:payment_date, :date)
    field(:party_key, :string)
    field(:party_name, :string)
    field(:paid_from_account_id, :integer)
    field(:amount, :decimal)
    field(:currency_code, :string)
    field(:reference, :string)
    field(:description, :string)
    field(:submitted_by_user_id, :integer)
    field(:submitted_by_impersonator_id, :integer)
    field(:submitted_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:allocations, PaymentRequestAllocation, foreign_key: :request_id)
    has_one(:event, PaymentRequestEvent, foreign_key: :request_id)
  end

  @doc "A request is `submitted` until its one event posts or rejects it."
  def status(%__MODULE__{event: nil}), do: "submitted"
  def status(%__MODULE__{event: %PaymentRequestEvent{event: event}}), do: event

  def statuses, do: ~w(submitted posted rejected)
end
