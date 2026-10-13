defmodule Bilimbi.Finance.Receivables.Attachments.Document do
  @moduledoc """
  A receivables document (an invoice or a credit note) as a record source
  documents support: the contract, the order, the delivery record. Read
  through `Bilimbi.Finance.Receivables.get_document/3` with the caller's
  scope, so `finance.receivables.view` is also needed. A document is final
  once issued or discarded; while a draft its attachments can be replaced
  or removed.
  """

  @behaviour Bilimbi.Finance.Attachments.Source

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Receivables

  @impl true
  def source_id, do: "finance/receivables/document"

  @impl true
  def source_label, do: "Receivables document"

  @impl true
  def view_capability, do: Receivables.view_capability()

  @impl true
  def document(%Scope{} = scope, company_id, document_id) do
    with {:ok, document} <- Receivables.get_document(scope, company_id, document_id) do
      {:ok,
       %{
         label: label(document),
         date: document.issue_date,
         final?: document.status != "draft"
       }}
    end
  end

  defp label(%{kind: kind, document_number: number}) when is_integer(number),
    do: "#{humanize(kind)} #{number}"

  defp label(%{kind: kind, id: id}), do: "#{humanize(kind)} (draft #{id})"

  defp humanize(kind), do: kind |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
