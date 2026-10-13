defmodule Bilimbi.Finance.Payables.Attachments.Payment do
  @moduledoc """
  A payment request as a record source documents support: the remittance
  advice, the bank's confirmation. The request is the payment's record from
  its submission on, so an attachment made before approval stays with the
  payment it posts. Read through
  `Bilimbi.Finance.Payables.get_payment_request/3` with the caller's scope,
  so `finance.payables.view` is also needed. A request is final once decided
  (posted or rejected); while submitted its attachments can be replaced or
  removed.
  """

  @behaviour Bilimbi.Finance.Attachments.Source

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Payables

  @impl true
  def source_id, do: "finance/payables/payment"

  @impl true
  def source_label, do: "Payment request"

  @impl true
  def document(%Scope{} = scope, company_id, request_id) do
    with {:ok, request} <- Payables.get_payment_request(scope, company_id, request_id) do
      {:ok,
       %{
         label: "Payment request #{request.request_number}",
         date: request.payment_date,
         final?: request.status != "submitted"
       }}
    end
  end
end
