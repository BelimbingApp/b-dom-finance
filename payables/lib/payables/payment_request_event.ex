defmodule Bilimbi.Finance.Payables.PaymentRequestEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # The one decision on a payment request: `posted` with the payment its
  # approval posted, or `rejected` with a reason. The database stamps it and
  # checks the payment pays what was requested (see the migration).
  schema "finance_payables_payment_request_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:request_id, :integer)
    field(:event, :string)
    field(:reason, :string)
    field(:payment_id, :integer)
    field(:actor_user_id, :integer)
    field(:actor_impersonator_id, :integer)
    field(:occurred_at, :utc_datetime_usec, read_after_writes: true)
  end

  def changeset(event, attributes) do
    event
    |> cast(attributes, [:reason])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :request_id, :event, :actor_user_id])
    |> validate_inclusion(:event, ~w(posted rejected))
    |> validate_length(:reason, max: 500)
    |> then(fn changeset ->
      if get_field(changeset, :event) == "rejected",
        do: validate_required(changeset, :reason, message: "is required to reject a payment"),
        else: changeset
    end)
    |> unique_constraint(:request_id,
      name: :finance_payables_payment_request_events_request_unique,
      message: "is already decided"
    )
  end
end
