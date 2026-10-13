defmodule Bilimbi.Finance.Reconciliation.Web.ReconciliationLive do
  @moduledoc """
  One reconciliation: the statement balance, the book balance, the items
  that explain the difference, and the difference itself. An open
  reconciliation reads its figures now, follows the ledger's postings, lets
  a statement line the books lack be posted as a bank charge or interest,
  and is finalised once the difference is zero or abandoned with a reason;
  a finalised one shows the figures and items it was finalised with, which
  never change. Every write is a facade call that re-asks its capability.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Reconciliation
  alias Bilimbi.Finance.Reconciliation.Web.Format

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope.scope
    company_id = Scope.actor(scope).company_id

    socket =
      socket
      |> assign(:page_title, "Reconciliation")
      |> assign(:active_nav, "finance.reconciliation")
      |> assign(:company_id, company_id)
      |> assign(:reconciliation_id, Params.positive_integer(id, 0))
      |> assign(:abandoning, false)
      |> assign(:abandon_form, to_form(%{"reason" => ""}, as: :abandon))

    if connected?(socket), do: Ledger.subscribe_postings(scope, company_id)

    {:ok, load(socket)}
  end

  defp load(socket) do
    %{
      current_scope: %{scope: scope} = current_scope,
      company_id: company_id,
      reconciliation_id: id
    } = socket.assigns

    with {:ok, report} <- Reconciliation.get_reconciliation(scope, company_id, id),
         {:ok, account} <-
           Reconciliation.get_bank_account(scope, company_id, report.bank_account_id) do
      socket
      |> assign(:report, report)
      |> assign(:account, account)
      |> assign(:refusal, nil)
      |> assign(:page_title, "#{account.name}: reconciliation #{report.reconciliation_number}")
      |> assign(
        :can_finalise?,
        LiveAuthorization.allowed_now?(
          current_scope,
          Reconciliation.finalise_reconciliations_capability()
        )
      )
      |> assign(
        :can_abandon?,
        LiveAuthorization.allowed_now?(
          current_scope,
          Reconciliation.manage_reconciliations_capability()
        )
      )
      |> assign(
        :can_post?,
        LiveAuthorization.allowed_now?(
          current_scope,
          Reconciliation.post_statement_lines_capability()
        ) and
          LiveAuthorization.allowed_now?(current_scope, Ledger.post_entries_capability())
      )
    else
      {:error, reason} ->
        socket |> assign(:report, nil) |> assign(:account, nil) |> assign(:refusal, reason)
    end
  end

  @impl true
  def handle_event("finalise", _params, socket) do
    case LiveAuthorization.authorize_event(
           socket,
           Reconciliation.finalise_reconciliations_capability()
         ) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        case Reconciliation.finalise_reconciliation(
               socket.assigns.current_scope.scope,
               socket.assigns.company_id,
               socket.assigns.reconciliation_id
             ) do
          {:ok, reconciliation} ->
            {:noreply,
             socket
             |> put_flash(
               :success,
               "Reconciliation #{reconciliation.reconciliation_number} finalised; its figures are now fixed."
             )
             |> load()}

          {:error, reason} ->
            {:noreply, socket |> put_flash(:error, Format.refusal(reason)) |> load()}
        end
    end
  end

  def handle_event("post", %{"line" => line_id, "kind" => kind}, socket) do
    with {:ok, socket} <-
           LiveAuthorization.authorize_event(
             socket,
             Reconciliation.post_statement_lines_capability()
           ),
         {:ok, socket} <-
           LiveAuthorization.authorize_event(socket, Ledger.post_entries_capability()) do
      case Reconciliation.post_statement_line(
             socket.assigns.current_scope.scope,
             socket.assigns.company_id,
             Params.positive_integer(line_id, 0),
             %{kind: kind}
           ) do
        {:ok, %{entry: entry}} ->
          {:noreply,
           socket
           |> put_flash(:success, "Posted as entry #{entry.entry_number} and matched.")
           |> load()}

        {:error, reason} ->
          {:noreply, socket |> put_flash(:error, Format.refusal(reason)) |> load()}
      end
    else
      {:denied, socket} -> {:noreply, socket}
    end
  end

  def handle_event("abandoning", _params, socket),
    do: {:noreply, assign(socket, :abandoning, true)}

  def handle_event("cancel_abandon", _params, socket),
    do: {:noreply, assign(socket, :abandoning, false)}

  def handle_event("abandon_change", %{"abandon" => params}, socket),
    do: {:noreply, assign(socket, :abandon_form, to_form(params, as: :abandon))}

  def handle_event("abandon", %{"abandon" => params}, socket) do
    case LiveAuthorization.authorize_event(
           socket,
           Reconciliation.manage_reconciliations_capability()
         ) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        case Reconciliation.abandon_reconciliation(
               socket.assigns.current_scope.scope,
               socket.assigns.company_id,
               socket.assigns.reconciliation_id,
               %{reason: params["reason"]}
             ) do
          {:ok, _reconciliation} ->
            {:noreply,
             socket
             |> put_flash(:info, "The reconciliation was abandoned.")
             |> assign(:abandoning, false)
             |> load()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:abandon_form, to_form(params, as: :abandon))
             |> put_flash(:error, Format.refusal(reason))}
        end
    end
  end

  # An open reconciliation follows the books; a finalised one cannot change.
  @impl true
  def handle_info({:finance_ledger_posted, _notice}, socket) do
    drain_notices()

    case socket.assigns.report do
      %{status: "open"} -> {:noreply, load(socket)}
      _other -> {:noreply, socket}
    end
  end

  defp drain_notices do
    receive do
      {:finance_ledger_posted, _notice} -> drain_notices()
    after
      0 -> :ok
    end
  end

  defp status_kind("open"), do: :warning
  defp status_kind("finalised"), do: :success
  defp status_kind("abandoned"), do: :neutral

  defp kind_label("statement_line"), do: "On the statement, not in the books"
  defp kind_label("entry"), do: "In the books, not on the statement"
  defp kind_label("timing"), do: "Matched, cleared after the statement date"

  defp zero?(%Decimal{} = value), do: Decimal.equal?(value, 0)

  defp event_label("opened"), do: "Opened"
  defp event_label("finalised"), do: "Finalised"
  defp event_label("abandoned"), do: "Abandoned"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="reconciliation" variant={:detail}>
        <.back_link
          id="reconciliation-back"
          navigate={
            if @account,
              do: ~p"/finance/reconciliation/accounts/#{@account.id}",
              else: ~p"/finance/reconciliation"
          }
          title={if @account, do: @account.name, else: "Bank accounts"}
        />

        <.empty_state
          :if={@refusal}
          id="reconciliation-refusal"
          title="Reconciliation unavailable"
          reason={Format.refusal(@refusal)}
        />

        <%= if @report do %>
          <.header>
            Reconciliation {@report.reconciliation_number} as of {@report.end_date}
            <:subtitle>
              <span id="reconciliation-status"><.badge kind={status_kind(@report.status)}>
                {@report.status}
              </.badge></span>
              <span :if={@report[:through_entry_number]} id="reconciliation-through" class="ml-2">
                through entry {@report.through_entry_number}, statement {@report.through_statement_number}, match event {@report.through_match_event_number}
              </span>
            </:subtitle>
            <:actions>
              <.link
                id="reconciliation-matching"
                navigate={~p"/finance/reconciliation/accounts/#{@account.id}/matching"}
              >
                Match statement lines
              </.link>
            </:actions>
          </.header>

          <.card
            id="reconciliation-figures"
            inner_class="p-5 sm:p-6"
            role="region"
            aria-labelledby="reconciliation-figures-heading"
          >
            <.section_heading id="reconciliation-figures-heading" title="Figures" />
            <.list id="reconciliation-facts">
              <:item title="Balance per statement" id="figure-statement-balance">
                <span class="tabular-nums">{Format.money(
                  @report.statement_balance,
                  @report[:minor_units] || 2
                )} {@report[:currency_code]}</span>
              </:item>
              <:item :if={@report[:book_balance]} title="Balance per books" id="figure-book-balance">
                <span class="tabular-nums">{Format.money(@report.book_balance, @report.minor_units)}</span>
              </:item>
              <:item :if={@report[:difference]} title="Unexplained difference" id="figure-difference">
                <span class="tabular-nums">{Format.money(@report.difference, @report.minor_units)}</span>
                <.badge :if={zero?(@report.difference)} kind={:success} class="ml-2">
                  explained
                </.badge>
                <.badge :if={!zero?(@report.difference)} kind={:warning} class="ml-2">
                  not yet explained
                </.badge>
              </:item>
            </.list>

            <div :if={@report.status == "open"} class="mt-4 flex flex-wrap gap-2">
              <.button
                :if={@can_finalise?}
                id="reconciliation-finalise"
                variant="primary"
                phx-click="finalise"
                disabled={!zero?(@report.difference)}
              >
                Finalise
              </.button>
              <.button :if={@can_abandon?} id="reconciliation-abandon" phx-click="abandoning">Abandon</.button>
            </div>
            <.empty_state
              :if={@report.status == "open" and !@can_finalise?}
              id="reconciliation-finalise-forbidden"
              forbidden="finalise reconciliations"
              class="mt-4"
            />
          </.card>

          <.card
            :if={@report[:items]}
            id="reconciliation-items"
            inner_class="p-0"
            role="region"
            aria-labelledby="reconciliation-items-heading"
          >
            <.section_heading
              id="reconciliation-items-heading"
              title="Items explaining the difference"
              count={length(@report.items)}
              class="p-5 pb-0"
            >
              <:description>
                Statement lines the books lack, entries the statement lacks, and matches that cleared after the end date.
              </:description>
            </.section_heading>
            <.table
              id="reconciliation-items-table"
              rows={Enum.with_index(@report.items, 1)}
              framed={false}
              row_id={fn {_item, index} -> "item-#{index}" end}
              row_item={fn {item, _index} -> item end}
            >
              <:col :let={item} label="Kind">{kind_label(item.kind)}</:col>
              <:col :let={item} label="Date">{item.item_date}</:col>
              <:col :let={item} label="Description">
                {item.description}
                <span :if={item.reference} class="block text-xs text-ink-muted">{item.reference}</span>
              </:col>
              <:col :let={item} label="Amount" align={:right}>
                <span class="tabular-nums">{Format.money(item.amount, @report.minor_units)}</span>
              </:col>
              <:action :let={item}>
                <%= if @report.status == "open" and item.kind == "statement_line" and @can_post? do %>
                  <.button
                    :if={Decimal.negative?(item.amount)}
                    id={"item-#{item.statement_line_id}-post-charge"}
                    phx-click="post"
                    phx-value-line={item.statement_line_id}
                    phx-value-kind="charge"
                  >
                    Post as bank charge
                  </.button>
                  <.button
                    :if={Decimal.positive?(item.amount)}
                    id={"item-#{item.statement_line_id}-post-interest"}
                    phx-click="post"
                    phx-value-line={item.statement_line_id}
                    phx-value-kind="interest"
                  >
                    Post as interest
                  </.button>
                <% end %>
              </:action>
              <:empty
                title="Nothing to explain"
                reason="Every statement line through the end date is matched, and so is every entry."
              />
            </.table>
          </.card>

          <.card
            id="reconciliation-events"
            inner_class="p-0"
            role="region"
            aria-labelledby="reconciliation-events-heading"
          >
            <.section_heading id="reconciliation-events-heading" title="History" class="p-5 pb-0" />
            <.table
              id="reconciliation-events-table"
              rows={@report.events}
              framed={false}
              row_id={&"event-#{&1.event_number}"}
            >
              <:col :let={event} label="Event">{event_label(event.action)}</:col>
              <:col :let={event} label="By">
                user {event.recorded_by_user_id}{if event.recorded_by_impersonator_id,
                  do: " (impersonated by #{event.recorded_by_impersonator_id})"}
              </:col>
              <:col :let={event} label="When">
                <.datetime
                  id={"event-#{event.event_number}-at"}
                  value={event.recorded_at}
                  precision={:second}
                />
              </:col>
              <:col :let={event} label="Reason">{event.reason}</:col>
            </.table>
          </.card>

          <.modal
            :if={@abandoning}
            id="abandon-modal"
            title="Abandon this reconciliation"
            on_cancel={JS.push("cancel_abandon")}
          >
            <:description>
              It stays on record as abandoned with this reason, and a new one can be opened.
            </:description>
            <.form
              for={@abandon_form}
              id="abandon-form"
              phx-change="abandon_change"
              phx-submit="abandon"
              class="space-y-3"
            >
              <.input
                field={@abandon_form[:reason]}
                id="abandon-reason"
                label="Reason"
                maxlength="500"
                required
              />
              <div class="flex gap-2">
                <.button type="submit" id="abandon-submit" variant="danger">Abandon</.button>
                <.button type="button" id="abandon-cancel" phx-click="cancel_abandon">Cancel</.button>
              </div>
            </.form>
          </.modal>
        <% end %>
      </.page>
    </Layouts.app>
    """
  end
end
