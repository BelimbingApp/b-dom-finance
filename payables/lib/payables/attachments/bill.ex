defmodule Bilimbi.Finance.Payables.Attachments.Bill do
  @moduledoc """
  A payables document (a bill or a debit note) as a record source documents
  support: the party's own invoice or note, the delivery record, the
  contract. Read through `Bilimbi.Finance.Payables.get_document/3` with the
  caller's scope, so `finance.payables.view` is also needed. A document is
  final from its approval on (approved, held, posted, voided); while a draft
  its attachments can be replaced or removed.
  """

  @behaviour Bilimbi.Finance.Attachments.Source

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Payables

  @impl true
  def source_id, do: "finance/payables/document"

  @impl true
  def source_label, do: "Payables document"

  @impl true
  def view_capability, do: Payables.view_capability()

  @impl true
  def document(%Scope{} = scope, company_id, document_id) do
    with {:ok, document} <- Payables.get_document(scope, company_id, document_id) do
      {:ok,
       %{
         label: label(document),
         date: document.document_date,
         final?: document.status != "draft"
       }}
    end
  end

  defp label(%{document_type: "bill", document_number: number}) when is_integer(number),
    do: "Bill #{number}"

  defp label(%{document_type: "debit_note", document_number: number}) when is_integer(number),
    do: "Debit note #{number}"

  # A document is numbered when it posts; until then its ID names it.
  defp label(%{document_type: type, id: id}), do: "#{humanize(type)} (record #{id})"

  defp humanize(type), do: type |> String.replace("_", " ") |> String.capitalize()
end
