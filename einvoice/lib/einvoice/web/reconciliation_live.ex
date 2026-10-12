defmodule Bilimbi.Finance.Einvoice.Web.ReconciliationLive do
  @moduledoc """
  Documents whose ledger side disagrees with their status: validated
  documents without a ledger entry, and cancelled documents whose entry
  stands. Each names the entry IDs and the reason the last posting or
  reversal failed, and offers to try it again. The buttons are facade
  calls that re-ask the capabilities; the `can_retry?` assign only decides
  whether they show.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.Web.DocumentsLive
  alias Bilimbi.Finance.Ledger

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope.scope
    company_id = Scope.actor(scope).company_id

    {:ok,
     socket
     |> assign(:page_title, "E-invoice Reconciliation")
     |> assign(:active_nav, "finance.einvoice.reconciliation")
     |> assign(:company_id, company_id)
     |> assign(
       :can_retry?,
       Authz.can(scope, Einvoice.submit_capability()).allowed and
         Authz.can(scope, Ledger.post_entries_capability()).allowed
     )
     |> load()}
  end

  @impl true
  def handle_event("retry_posting", %{"id" => id}, socket),
    do: {:noreply, retry(socket, :retry_posting, id, "The entry was posted.")}

  def handle_event("retry_reversal", %{"id" => id}, socket),
    do: {:noreply, retry(socket, :retry_reversal, id, "The entry was reversed.")}

  defp retry(socket, operation, id, success) do
    result =
      apply(Einvoice, operation, [
        socket.assigns.current_scope.scope,
        socket.assigns.company_id,
        Params.positive_integer(id, 0)
      ])

    socket =
      case result do
        {:ok, _document} -> put_flash(socket, :success, success)
        {:error, reason} -> put_flash(socket, :error, retry_message(reason))
      end

    load(socket)
  end

  defp retry_message({:failed, reason}), do: "It failed again: #{reason}."
  defp retry_message(:unauthorized), do: "You need permission to post to the ledger."
  defp retry_message(:not_postable), do: "Only a valid document can be posted."
  defp retry_message(:not_reversible), do: "Only a cancelled document can be reversed."
  defp retry_message(:document_not_found), do: "The document no longer exists."
  defp retry_message(reason), do: "It could not be tried (#{inspect(reason)})."

  defp load(socket) do
    case Einvoice.reconciliation(socket.assigns.current_scope.scope, socket.assigns.company_id) do
      {:ok, result} -> assign(socket, :reconciliation, result)
      {:error, _reason} -> assign(socket, :reconciliation, nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="einvoice-reconciliation">
        <.header>
          E-invoice Reconciliation
          <:subtitle>
            Validated documents without a ledger entry, and entries whose document is cancelled.
          </:subtitle>
          <:actions>
            <.link id="einvoice-reconciliation-documents" navigate={~p"/finance/einvoice/documents"}>
              All documents
            </.link>
          </:actions>
        </.header>

        <.empty_state
          :if={is_nil(@reconciliation)}
          id="einvoice-reconciliation-unavailable"
          title="Reconciliation unavailable"
          reason="This company's documents cannot be read with your current access."
        />

        <%= if @reconciliation do %>
          <.card
            id="einvoice-unposted"
            inner_class="p-0"
            role="region"
            aria-labelledby="einvoice-unposted-heading"
          >
            <.section_heading
              id="einvoice-unposted-heading"
              title="Valid documents without a ledger entry"
              class="p-5 pb-0"
            />
            <.table
              id="einvoice-unposted-table"
              rows={@reconciliation.unposted}
              framed={false}
              row_id={&"einvoice-unposted-#{&1.id}"}
            >
              <:col :let={document} label="Number">
                <.link
                  navigate={~p"/finance/einvoice/documents/#{document.id}"}
                  class="font-medium text-ink-strong hover:underline"
                >
                  {document.code_number}
                </.link>
              </:col>
              <:col :let={document} label="Type">
                {DocumentsLive.type_label(document.document_type)}
              </:col>
              <:col :let={document} label="Payable">
                <span class="tabular-nums">{Decimal.to_string(document.payable_amount, :normal)} {document.currency_code}</span>
              </:col>
              <:col :let={document} label="Last failure">{document.reason || "not attempted"}</:col>
              <:col :let={document} label="">
                <.button
                  :if={@can_retry?}
                  id={"einvoice-retry-posting-#{document.id}"}
                  phx-click="retry_posting"
                  phx-value-id={document.id}
                >
                  Retry posting
                </.button>
              </:col>
              <:empty>Every validated document has its ledger entry.</:empty>
            </.table>
          </.card>

          <.card
            id="einvoice-unreversed"
            inner_class="p-0"
            role="region"
            aria-labelledby="einvoice-unreversed-heading"
          >
            <.section_heading
              id="einvoice-unreversed-heading"
              title="Entries whose document is cancelled"
              class="p-5 pb-0"
            />
            <.table
              id="einvoice-unreversed-table"
              rows={@reconciliation.unreversed}
              framed={false}
              row_id={&"einvoice-unreversed-#{&1.id}"}
            >
              <:col :let={document} label="Number">
                <.link
                  navigate={~p"/finance/einvoice/documents/#{document.id}"}
                  class="font-medium text-ink-strong hover:underline"
                >
                  {document.code_number}
                </.link>
              </:col>
              <:col :let={document} label="Status">
                <.badge kind={DocumentsLive.status_kind(document.status)}>{document.status}</.badge>
              </:col>
              <:col :let={document} label="Entry">#{document.ledger_entry_id}</:col>
              <:col :let={document} label="Last failure">{document.reason || "not attempted"}</:col>
              <:col :let={document} label="">
                <.button
                  :if={@can_retry?}
                  id={"einvoice-retry-reversal-#{document.id}"}
                  phx-click="retry_reversal"
                  phx-value-id={document.id}
                >
                  Retry reversal
                </.button>
              </:col>
              <:empty>Every entry of a cancelled document has been reversed.</:empty>
            </.table>
          </.card>
        <% end %>
      </.page>
    </Layouts.app>
    """
  end
end
