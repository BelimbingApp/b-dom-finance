defmodule Bilimbi.Finance.Einvoice.Web.ReconciliationLive do
  @moduledoc """
  Documents whose ledger side disagrees with their status: validated
  documents without a ledger entry, and documents no longer valid whose
  entry stands. Each names the entry IDs and the reason the last posting
  or reversal failed.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.Web.DocumentsLive

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope.scope
    company_id = Scope.actor(scope).company_id

    {:ok,
     socket
     |> assign(:page_title, "E-invoice Reconciliation")
     |> assign(:active_nav, "finance.einvoice.reconciliation")
     |> assign(:company_id, company_id)
     |> load()}
  end

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
            Validated documents without a ledger entry, and entries whose document is no longer valid.
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
              title="Entries whose document is no longer valid"
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
              <:empty>Every entry of a cancelled document has been reversed.</:empty>
            </.table>
          </.card>
        <% end %>
      </.page>
    </Layouts.app>
    """
  end
end
