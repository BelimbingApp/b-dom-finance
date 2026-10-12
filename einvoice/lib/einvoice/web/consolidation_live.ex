defmodule Bilimbi.Finance.Einvoice.Web.ConsolidationLive do
  @moduledoc """
  A month's consolidated document: the documents it would cover (recorded
  in the month, never submitted on their own, not held by another
  consolidated document), the ones the authority's limits keep out and
  why, their totals, the window in which it may be issued, and a form
  that issues it. The month lives in the URL (`?month=YYYY-MM`) and
  defaults to the latest month that has ended. Issuing is a facade call
  that re-asks its capability; `can_issue?` only decides whether the form
  shows.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.Configuration
  alias Bilimbi.Finance.Einvoice.Consolidation
  alias Bilimbi.Finance.Einvoice.Web.DocumentsLive

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope.scope

    {:ok,
     socket
     |> assign(:page_title, "E-invoice Consolidation")
     |> assign(:active_nav, "finance.einvoice.consolidation")
     |> assign(:company_id, Scope.actor(scope).company_id)
     |> assign(:can_issue?, Authz.can(scope, Einvoice.issue_capability()).allowed)
     |> assign(:issue_form, to_form(%{"code_number" => "", "grouping" => "document"}, as: :issue))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    month =
      case Consolidation.parse_month(params["month"]) do
        {:ok, month} -> month
        :error -> latest_ended_month(DateTime.utc_now())
      end

    {:noreply, socket |> assign(:month, month) |> load()}
  end

  @impl true
  def handle_event("month", %{"month" => month}, socket) do
    {:noreply, push_patch(socket, to: ~p"/finance/einvoice/consolidation?#{[month: month]}")}
  end

  def handle_event("issue_change", %{"issue" => params}, socket) do
    {:noreply, assign(socket, :issue_form, to_form(params, as: :issue))}
  end

  def handle_event("issue", %{"issue" => params}, socket) do
    attributes = %{
      month: month_param(socket.assigns.month),
      code_number: params["code_number"],
      grouping: params["grouping"]
    }

    case Einvoice.issue_consolidated_document(
           socket.assigns.current_scope.scope,
           socket.assigns.company_id,
           attributes
         ) do
      {:ok, document} ->
        {:noreply,
         socket
         |> put_flash(:success, "Consolidated document #{document.code_number} issued.")
         |> push_navigate(to: ~p"/finance/einvoice/documents/#{document.id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:issue_form, to_form(params, as: :issue))
         |> put_flash(:error, issue_message(reason))
         |> load()}
    end
  end

  # The latest month whose consolidation window has opened, in the
  # authority's calendar: on its first days a month still counts as the
  # one before until it has ended there.
  defp latest_ended_month(now) do
    this_month = now |> DateTime.to_date() |> Date.beginning_of_month()
    previous = this_month |> Date.add(-1) |> Date.beginning_of_month()

    Enum.find([this_month, previous], previous, fn month ->
      DateTime.compare(Configuration.authority().consolidation_window(month).until, now) != :gt
    end)
  end

  defp month_param(month), do: Calendar.strftime(month, "%Y-%m")

  defp load(socket) do
    case Einvoice.consolidation_candidates(
           socket.assigns.current_scope.scope,
           socket.assigns.company_id,
           socket.assigns.month
         ) do
      {:ok, candidates} -> assign(socket, :candidates, candidates)
      {:error, _reason} -> assign(socket, :candidates, nil)
    end
  end

  defp issue_message(:period_not_ended),
    do: "The month has not ended yet; its consolidated document is issued after it ends."

  defp issue_message(:consolidation_window_closed),
    do: "The time the authority allows for this month's consolidated document has passed."

  defp issue_message(:nothing_to_consolidate),
    do: "No document of this month can be consolidated."

  defp issue_message(:code_number_taken), do: "That number is already used in this environment."
  defp issue_message(:unauthorized), do: "You do not have permission to issue documents."
  defp issue_message(:company_archived), do: "The company is archived."

  defp issue_message({:not_consolidatable, id}),
    do: "Document ##{id} can no longer be consolidated; reload the page."

  defp issue_message(%Ecto.Changeset{} = changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, _options} -> message end)
      |> flatten_errors([])

    "The consolidated document was refused: " <> Enum.join(errors, "; ") <> "."
  end

  defp issue_message(reason),
    do: "The consolidated document could not be issued (#{inspect(reason)})."

  defp flatten_errors(errors, path) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} -> flatten_errors(value, path ++ [to_string(key)]) end)
  end

  defp flatten_errors([first | _] = messages, path) when is_binary(first),
    do: ["#{Enum.join(path, " ")} #{Enum.join(messages, ", ")}"]

  defp flatten_errors(errors, path) when is_list(errors) do
    errors
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {error, index} -> flatten_errors(error, path ++ ["#{index}"]) end)
  end

  defp money(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="einvoice-consolidation">
        <.header>
          E-invoice Consolidation
          <:subtitle>
            One consolidated document reports a month's sales that no buyer asked an individual e-invoice for.
          </:subtitle>
          <:actions>
            <.link id="einvoice-consolidation-documents" navigate={~p"/finance/einvoice/documents"}>
              All documents
            </.link>
          </:actions>
        </.header>

        <.form for={%{}} id="einvoice-consolidation-month" phx-change="month" phx-submit="month">
          <.input
            type="month"
            name="month"
            id="einvoice-consolidation-month-input"
            value={month_param(@month)}
            label="Month"
          />
        </.form>

        <.empty_state
          :if={is_nil(@candidates)}
          id="einvoice-consolidation-unavailable"
          title="Consolidation unavailable"
          reason="This company's documents cannot be read with your current access."
        />

        <%= if @candidates do %>
          <.card
            id="einvoice-consolidation-summary"
            inner_class="p-5 sm:p-6"
            role="region"
            aria-labelledby="einvoice-consolidation-summary-heading"
          >
            <.section_heading id="einvoice-consolidation-summary-heading" title="Window and totals" />
            <.list id="einvoice-consolidation-facts">
              <:item title="Covers documents issued">
                <.datetime id="einvoice-consolidation-from" value={@candidates.from} /> to
                <.datetime id="einvoice-consolidation-until" value={@candidates.until} />
              </:item>
              <:item title="May be issued until">
                <.datetime id="einvoice-consolidation-closes" value={@candidates.closes_at} />
                <span :if={@candidates.open?} id="einvoice-consolidation-open" class="ml-2">
                  <.badge kind={:success}>open now</.badge>
                </span>
                <span :if={!@candidates.open?} id="einvoice-consolidation-closed" class="ml-2">
                  <.badge kind={:warning}>not open now</.badge>
                </span>
              </:item>
              <:item title="Environment">{@candidates.environment}</:item>
              <:item title="Documents">{length(@candidates.documents)}</:item>
              <:item title="Tax exclusive">{money(@candidates.line_extension_amount)}</:item>
              <:item title="Tax">{money(@candidates.tax_amount)}</:item>
              <:item title="Payable">{money(@candidates.payable_amount)}</:item>
            </.list>

            <.form
              :if={@can_issue? and @candidates.open? and @candidates.documents != []}
              for={@issue_form}
              id="einvoice-consolidation-issue"
              phx-change="issue_change"
              phx-submit="issue"
              class="mt-4 space-y-3"
            >
              <.input
                field={@issue_form[:code_number]}
                id="einvoice-consolidation-code-number"
                label="Number of the consolidated document"
                maxlength="50"
                required
              />
              <.input
                type="select"
                field={@issue_form[:grouping]}
                id="einvoice-consolidation-grouping"
                label="Lines"
                options={[
                  {"One line per document and tax", "document"},
                  {"One line per tax, summarising every document", "summary"}
                ]}
              />
              <.button
                type="submit"
                id="einvoice-consolidation-submit"
                variant="primary"
                phx-disable-with="Issuing…"
              >
                Issue consolidated document
              </.button>
            </.form>
          </.card>

          <.card
            id="einvoice-consolidation-candidates"
            inner_class="p-0"
            role="region"
            aria-labelledby="einvoice-consolidation-candidates-heading"
          >
            <.section_heading
              id="einvoice-consolidation-candidates-heading"
              title="Documents it would cover"
              class="p-5 pb-0"
            />
            <.table
              id="einvoice-consolidation-candidates-table"
              rows={@candidates.documents}
              framed={false}
              row_id={&"einvoice-candidate-#{&1.id}"}
              caption="Documents it would cover"
            >
              <:col :let={document} label="Number">
                <.link
                  navigate={~p"/finance/einvoice/documents/#{document.id}"}
                  class="font-medium text-ink-strong hover:underline"
                >
                  {document.code_number}
                </.link>
              </:col>
              <:col :let={document} label="Issued">
                <.datetime id={"einvoice-candidate-issued-#{document.id}"} value={document.issued_at} />
              </:col>
              <:col :let={document} label="Buyer">{document.counterparty_name}</:col>
              <:col :let={document} label="Status">
                <.badge kind={DocumentsLive.status_kind(document.status)}>{document.status}</.badge>
              </:col>
              <:col :let={document} label="Payable" align={:right}>
                <span class="tabular-nums">{money(document.payable_amount)} {document.currency_code}</span>
              </:col>
              <:empty>No document of this month is waiting to be consolidated.</:empty>
            </.table>
          </.card>

          <.card
            :if={@candidates.refused != []}
            id="einvoice-consolidation-refused"
            inner_class="p-0"
            role="region"
            aria-labelledby="einvoice-consolidation-refused-heading"
          >
            <.section_heading
              id="einvoice-consolidation-refused-heading"
              title="Documents that need an individual e-invoice"
              class="p-5 pb-0"
            />
            <.table
              id="einvoice-consolidation-refused-table"
              rows={@candidates.refused}
              framed={false}
              row_id={&"einvoice-refused-#{&1.document.id}"}
              caption="Documents that need an individual e-invoice"
            >
              <:col :let={row} label="Number">
                <.link
                  navigate={~p"/finance/einvoice/documents/#{row.document.id}"}
                  class="font-medium text-ink-strong hover:underline"
                >
                  {row.document.code_number}
                </.link>
              </:col>
              <:col :let={row} label="Payable" align={:right}>
                <span class="tabular-nums">{money(row.document.payable_amount)} {row.document.currency_code}</span>
              </:col>
              <:col :let={row} label="Why">It {row.reason}.</:col>
            </.table>
          </.card>
        <% end %>
      </.page>
    </Layouts.app>
    """
  end
end
