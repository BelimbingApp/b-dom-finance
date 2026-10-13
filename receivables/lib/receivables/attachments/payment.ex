defmodule Bilimbi.Finance.Receivables.Attachments.Payment do
  @moduledoc """
  A payment received as a record source documents support: the customer's
  remittance advice, the bank's credit note. Read through
  `Bilimbi.Finance.Receivables.get_payment/3` with the caller's scope, so
  `finance.receivables.view` is also needed. A payment posts as it is
  recorded, so it is always final: attachments are added, never replaced or
  removed.
  """

  @behaviour Bilimbi.Finance.Attachments.Source

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Receivables

  @impl true
  def source_id, do: "finance/receivables/payment"

  @impl true
  def source_label, do: "Payment received"

  @impl true
  def document(%Scope{} = scope, company_id, payment_id) do
    with {:ok, payment} <- Receivables.get_payment(scope, company_id, payment_id) do
      {:ok,
       %{
         label: "Payment #{payment.payment_number}",
         date: payment.payment_date,
         final?: true
       }}
    end
  end
end
