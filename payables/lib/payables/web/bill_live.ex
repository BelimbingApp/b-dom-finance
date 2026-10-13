defmodule Bilimbi.Finance.Payables.Web.BillLive do
  @moduledoc """
  One payables document: its party, lines with any order line each names,
  tax lines, totals, who recorded, approved, posted, or voided it, and, for
  a bill naming order lines, its three-way match: the match status, the
  exceptions its last match found with the figures compared, and every
  match event. Actions: approve a draft, post an approved or held document,
  approve a held bill's exceptions with a reason, and void with a reason.

  The record is read-first; nothing on it is edited. Every action is a
  facade call that re-asks its capability, and the `can_*` assigns only
  decide which controls show.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Base.UI.Workspace
  alias Bilimbi.Finance.Payables
  alias Bilimbi.Finance.Payables.Web.BillsLive

  @approve Payables.approve_documents_capability()
  @post Payables.post_documents_capability()
  @approve_exceptions Payables.approve_match_exceptions_capability()

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope.scope
    company_id = Scope.actor(scope).company_id

    socket =
      socket
      |> assign(:active_nav, "finance.payables.bills")
      |> assign(:company_id, company_id)
      |> assign(:document_id, Params.positive_integer(id, 0))
      |> assign(:dialog, nil)
      |> assign(:reason, "")
      |> assign(:can_approve?, Authz.can(scope, @approve).allowed)
      |> assign(:can_post?, Authz.can(scope, @post).allowed)
      |> assign(:can_approve_exceptions?, Authz.can(scope, @approve_exceptions).allowed)
      |> load()

    socket =
      if socket.assigns.document,
        do:
          Workspace.announce(socket, %{kind: "finance/payables", id: socket.assigns.document.id}),
        else: socket

    {:ok, socket}
  end

  @impl true
  def handle_event("approve", _params, socket) do
    socket =
      case Payables.approve_document(
             scope(socket),
             socket.assigns.company_id,
             socket.assigns.document_id
           ) do
        {:ok, _document} -> put_flash(socket, :success, "Document approved.")
        {:error, reason} -> put_flash(socket, :error, approve_message(reason))
      end

    {:noreply, load(socket)}
  end

  def handle_event("post", _params, socket) do
    socket =
      case Payables.post_document(
             scope(socket),
             socket.assigns.company_id,
             socket.assigns.document_id
           ) do
        {:ok, %{status: "held"} = document} ->
          put_flash(socket, :warning, held_message(document))

        {:ok, document} ->
          put_flash(socket, :success, "Posted as number #{document.document_number}.")

        {:error, reason} ->
          put_flash(socket, :error, post_message(reason))
      end

    {:noreply, load(socket)}
  end

  def handle_event("open_dialog", %{"dialog" => dialog}, socket)
      when dialog in ["approve_exception", "void"] do
    {:noreply, socket |> clear_flash() |> assign(dialog: dialog, reason: "")}
  end

  def handle_event("close_dialog", _params, socket) do
    {:noreply, assign(socket, dialog: nil, reason: "")}
  end

  def handle_event("reason", %{"dialog" => %{"reason" => reason}}, socket) do
    {:noreply, assign(socket, :reason, reason)}
  end

  def handle_event("approve_exception", %{"dialog" => %{"reason" => reason}}, socket) do
    socket =
      case Payables.approve_match_exception(
             scope(socket),
             socket.assigns.company_id,
             socket.assigns.document_id,
             %{reason: reason, held_event_id: held_event_id(socket.assigns.last_match)}
           ) do
        {:ok, _document} ->
          socket
          |> assign(dialog: nil, reason: "")
          |> put_flash(:success, "Match exceptions approved; the bill may now be posted.")

        {:error, reason} ->
          socket |> assign(:dialog, nil) |> put_flash(:error, exception_message(reason))
      end

    {:noreply, load(socket)}
  end

  def handle_event("void", %{"dialog" => %{"reason" => reason}}, socket) do
    socket =
      case Payables.void_document(
             scope(socket),
             socket.assigns.company_id,
             socket.assigns.document_id,
             %{void_reason: reason}
           ) do
        {:ok, _document} ->
          socket |> assign(dialog: nil, reason: "") |> put_flash(:success, "Document voided.")

        {:error, reason} ->
          socket |> assign(:dialog, nil) |> put_flash(:error, void_message(reason))
      end

    {:noreply, load(socket)}
  end

  defp held_event_id(%{event: "held", id: id}), do: id
  defp held_event_id(_last_match), do: nil

  defp scope(socket), do: socket.assigns.current_scope.scope

  defp load(socket) do
    case Payables.get_document(
           scope(socket),
           socket.assigns.company_id,
           socket.assigns.document_id
         ) do
      {:ok, document} ->
        socket
        |> assign(:document, document)
        |> assign(
          :last_match,
          List.last(Enum.filter(document.match_events, &(&1.event != "exception_approved")))
        )
        |> assign(:page_title, title(document))

      {:error, _reason} ->
        socket
        |> assign(:document, nil)
        |> assign(:last_match, nil)
        |> assign(:page_title, "Bill")
    end
  end

  defp title(document) do
    "#{BillsLive.type_label(document.document_type)} #{BillsLive.number(document)} from #{document.party_name}"
  end

  defp held_message(document) do
    count =
      document.match_events
      |> List.last()
      |> Map.get(:lines)
      |> Enum.flat_map(& &1.exceptions)
      |> length()

    "Not posted: the three-way match found #{count} exception(s), so the bill is held."
  end

  defp approve_message(:not_draft), do: "Only a draft can be approved."

  defp approve_message(:same_person),
    do:
      "This company separates duties: someone other than whoever recorded the document " <>
        "must approve it."

  defp approve_message(:unauthorized), do: "You do not have permission to approve documents."
  defp approve_message(:company_archived), do: "This company is archived."
  defp approve_message(reason), do: "The document could not be approved (#{inspect(reason)})."

  defp post_message(:not_approved), do: "Only an approved or held document can be posted."
  defp post_message(:unauthorized), do: "You do not have permission to post documents."
  defp post_message(:company_archived), do: "This company is archived."

  defp post_message(:payables_not_configured),
    do: "Set the payable account in the payables settings first."

  defp post_message(:exceeds_outstanding),
    do: "The debit note exceeds what is still owed on its bill."

  defp post_message(:exceeds_billed_quantity),
    do: "The debit note takes back more than its bill billed on an order line."

  defp post_message({:order_source, :unauthorized}),
    do: "You do not have permission to read the purchase orders the bill is matched against."

  defp post_message({:order_source, reason}),
    do: "The order source refused the match (#{inspect(reason)})."

  defp post_message(%Ecto.Changeset{}), do: "The ledger refused the entry; check the accounts."
  defp post_message(reason), do: "The document could not be posted (#{inspect(reason)})."

  defp exception_message(:not_held), do: "Only a held bill has exceptions to approve."
  defp exception_message(:already_approved), do: "These exceptions are already approved."

  defp exception_message(:stale_hold),
    do:
      "The bill was matched again since this page loaded. Review the new figures and approve again."

  defp exception_message(:same_person),
    do:
      "This company separates duties: someone other than whoever recorded the bill or " <>
        "tried to post it must approve its exceptions."

  defp exception_message(:unauthorized),
    do: "You do not have permission to approve match exceptions."

  defp exception_message(%Ecto.Changeset{}), do: "Give a reason of 1 to 500 characters."
  defp exception_message(reason), do: "The exceptions could not be approved (#{inspect(reason)})."

  defp void_message(:not_voidable), do: "Only a draft, approved, or held document can be voided."
  defp void_message(:unauthorized), do: "You do not have permission to void documents."
  defp void_message(%Ecto.Changeset{}), do: "Give a reason of 1 to 500 characters."
  defp void_message(reason), do: "The document could not be voided (#{inspect(reason)})."

  defp actor_text(nil, _impersonator), do: "—"
  defp actor_text(user_id, nil), do: "User ##{user_id}"
  defp actor_text(user_id, by), do: "User ##{user_id} (impersonated by ##{by})"

  defp event_label("held"), do: "held"
  defp event_label("exception_approved"), do: "exception approved"
  defp event_label("posted"), do: "posted"

  defp tolerance(nil, _value), do: "exact"
  defp tolerance("percent", value), do: "#{money(value)}%"
  defp tolerance("amount", value), do: money(value)

  defp money(value), do: BillsLive.money(value)

  defp exceptions_of(event), do: for(line <- event.lines, x <- line.exceptions, do: {line, x})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="payables-bill" variant={:detail}>
        <.empty_state
          :if={is_nil(@document)}
          id="payables-bill-missing"
          title="Document not found"
          reason="There is no such document for this company, or it cannot be read with your current access."
        >
          <:action>
            <.link navigate={~p"/finance/payables/bills"}>All bills</.link>
          </:action>
        </.empty_state>

        <%= if @document do %>
          <.header>
            {BillsLive.type_label(@document.document_type)} {BillsLive.number(@document)}
            <:subtitle>
              <.badge kind={BillsLive.status_kind(@document.status)}>{@document.status}</.badge>
              <span :if={@document.match_status} id="payables-bill-match-status" class="ml-2">
                <.badge kind={BillsLive.match_kind(@document.match_status)}>
                  Match: {BillsLive.match_label(@document.match_status)}
                </.badge>
              </span>
            </:subtitle>
            <:actions>
              <.link id="payables-bill-back" navigate={~p"/finance/payables/bills"}>All bills</.link>
              <.button
                :if={@can_approve? and @document.status == "draft"}
                id="payables-bill-approve"
                phx-click="approve"
                variant="primary"
              >
                Approve
              </.button>
              <.button
                :if={@can_post? and @document.status in ["approved", "held"]}
                id="payables-bill-post"
                phx-click="post"
                variant="primary"
              >
                Post
              </.button>
              <.button
                :if={@can_approve_exceptions? and @document.match_status == "held"}
                id="payables-bill-open-approve-exception"
                phx-click="open_dialog"
                phx-value-dialog="approve_exception"
              >
                Approve exceptions
              </.button>
              <.button
                :if={@can_approve? and @document.status in ["draft", "approved", "held"]}
                id="payables-bill-open-void"
                phx-click="open_dialog"
                phx-value-dialog="void"
                variant="danger"
              >
                Void
              </.button>
            </:actions>
          </.header>

          <.card
            :if={@document.match_status in ["held", "exception_approved"]}
            id="payables-bill-attention"
            inner_class="p-5 sm:p-6"
            role="alert"
          >
            <.section_heading id="payables-bill-attention-heading" title="Held by the three-way match" />
            <p class="mt-2 text-sm text-ink">
              <%= if @document.match_status == "held" do %>
                The last match found exceptions nobody has approved. A user with the approve-exception
                permission approves them with a reason, or the bill is posted again once the goods
                arrive, or voided.
              <% else %>
                The exceptions are approved; post the bill to record it.
              <% end %>
            </p>
            <ul :if={@last_match} class="mt-3 list-disc space-y-1 pl-5 text-sm text-ink">
              <li
                :for={{line, exception} <- exceptions_of(@last_match)}
                id={"payables-exception-#{line.line_number}-#{exception.code}"}
              >
                Line {line.line_number}: {exception.detail}
                <span class="text-ink-muted">({exception.code})</span>
              </li>
            </ul>
          </.card>

          <div class="grid gap-4 lg:grid-cols-2">
            <.card
              id="payables-bill-party"
              inner_class="p-5 sm:p-6"
              role="region"
              aria-labelledby="payables-bill-party-heading"
            >
              <.section_heading id="payables-bill-party-heading" title="Party" />
              <.list id="payables-bill-party-facts">
                <:item title="Name">{@document.party_name}</:item>
                <:item title="Key">{@document.party_key}</:item>
                <:item title="Tax ID">{@document.party_tax_id || "—"}</:item>
                <:item title="Registration">{@document.party_registration_id || "—"}</:item>
                <:item title="Address">{@document.party_address || "—"}</:item>
              </.list>
            </.card>
            <.card
              id="payables-bill-facts"
              inner_class="p-5 sm:p-6"
              role="region"
              aria-labelledby="payables-bill-facts-heading"
            >
              <.section_heading id="payables-bill-facts-heading" title="Document" />
              <.list id="payables-bill-document-facts">
                <:item title="Party's number">{@document.party_document_number || "—"}</:item>
                <:item title="Date">{@document.document_date}</:item>
                <:item title="Due">{@document.due_date}</:item>
                <:item title="Description">{@document.description || "—"}</:item>
                <:item title="Corrects">
                  <.link
                    :if={@document.corrects_document_id}
                    navigate={~p"/finance/payables/bills/#{@document.corrects_document_id}"}
                    class="text-action hover:underline"
                  >
                    Bill #{@document.corrects_document_id}
                  </.link>
                  <span :if={!@document.corrects_document_id}>—</span>
                </:item>
                <:item title="Outstanding">
                  {money(@document.outstanding)} {if @document.outstanding, do: @document.currency_code}
                </:item>
                <:item title="Ledger entry">
                  {if @document.entry_number, do: "##{@document.entry_number}", else: "—"}
                </:item>
                <:item title="Recorded">
                  {actor_text(@document.created_by_user_id, @document.created_by_impersonator_id)} ·
                  <.datetime
                    id="payables-bill-created-at"
                    value={@document.created_at}
                    precision={:second}
                  />
                </:item>
                <:item title="Approved">
                  {actor_text(@document.approved_by_user_id, @document.approved_by_impersonator_id)}
                  <.datetime
                    :if={@document.approved_at}
                    id="payables-bill-approved-at"
                    value={@document.approved_at}
                    precision={:second}
                  />
                </:item>
                <:item title="Posted">
                  {actor_text(@document.posted_by_user_id, @document.posted_by_impersonator_id)}
                  <.datetime
                    :if={@document.posted_at}
                    id="payables-bill-posted-at"
                    value={@document.posted_at}
                    precision={:second}
                  />
                </:item>
                <:item :if={@document.status == "voided"} title="Voided">
                  {actor_text(@document.voided_by_user_id, @document.voided_by_impersonator_id)}
                  <.datetime
                    id="payables-bill-voided-at"
                    value={@document.voided_at}
                    precision={:second}
                  /> · {@document.void_reason}
                </:item>
              </.list>
            </.card>
          </div>

          <.card
            id="payables-bill-lines"
            inner_class="p-0"
            role="region"
            aria-labelledby="payables-bill-lines-heading"
          >
            <.section_heading id="payables-bill-lines-heading" title="Lines" class="p-5 pb-0" />
            <.table
              id="payables-bill-lines-table"
              rows={@document.lines}
              framed={false}
              row_id={&"payables-line-#{&1.line_number}"}
              caption="Lines"
            >
              <:col :let={line} label="#">{line.line_number}</:col>
              <:col :let={line} label="Description">{line.description}</:col>
              <:col :let={line} label="Account">#{line.account_id}</:col>
              <:col :let={line} label="Order line">
                {if line.order_line_id, do: "##{line.order_line_id}", else: line.external_order_line_id || "—"}
              </:col>
              <:col :let={line} label="Quantity" align={:right}>{money(line.quantity)}</:col>
              <:col :let={line} label="Amount" align={:right}>{money(line.amount)}</:col>
            </.table>
            <div class="p-5">
              <.list id="payables-bill-totals">
                <:item title="Net">{money(@document.total_net)} {@document.currency_code}</:item>
                <:item title="Tax">{money(@document.total_tax)} {@document.currency_code}</:item>
                <:item title="Total">{money(@document.total)} {@document.currency_code}</:item>
              </.list>
            </div>
          </.card>

          <.card
            :if={@last_match}
            id="payables-bill-match"
            inner_class="p-0"
            role="region"
            aria-labelledby="payables-bill-match-heading"
          >
            <.section_heading
              id="payables-bill-match-heading"
              title="Three-way match"
              class="p-5 pb-0"
            >
              <:description>
                What the last match compared, line by line: billed against ordered, and against
                what was received and not yet billed, within the tolerances in force.
              </:description>
            </.section_heading>
            <.table
              id="payables-bill-match-table"
              rows={@last_match.lines}
              framed={false}
              row_id={&"payables-match-line-#{&1.line_number}"}
              caption="Match lines"
            >
              <:col :let={line} label="#">{line.line_number}</:col>
              <:col :let={line} label="Order">
                {if line.order_number, do: "##{line.order_number}", else: "—"} line #{line.order_line_id}
              </:col>
              <:col :let={line} label="Billed" align={:right}>
                {money(line.billed_quantity)} at {money(line.billed_unit_price)}
              </:col>
              <:col :let={line} label="Ordered" align={:right}>
                {money(line.ordered_quantity)} at {money(line.ordered_unit_price)}
              </:col>
              <:col :let={line} label="Received" align={:right}>{money(line.received_quantity)}</:col>
              <:col :let={line} label="Billed before" align={:right}>
                {money(line.previously_billed_quantity)}
              </:col>
              <:col :let={line} label="Tolerances">
                qty {tolerance(line.quantity_tolerance_kind, line.quantity_tolerance)} · price {tolerance(
                  line.price_tolerance_kind,
                  line.price_tolerance
                )}
              </:col>
              <:col :let={line} label="Result">
                <.badge :if={line.exceptions == []} kind={:success}>matched</.badge>
                <span :for={exception <- line.exceptions} class="block text-xs text-ink">
                  {exception.detail}
                </span>
              </:col>
            </.table>
          </.card>

          <.card
            :if={@document.match_events != []}
            id="payables-bill-match-events"
            inner_class="p-0"
            role="region"
            aria-labelledby="payables-bill-match-events-heading"
          >
            <.section_heading
              id="payables-bill-match-events-heading"
              title="Match history"
              class="p-5 pb-0"
            />
            <.table
              id="payables-bill-match-events-table"
              rows={@document.match_events}
              framed={false}
              row_id={&"payables-match-event-#{&1.id}"}
              caption="Match events"
            >
              <:col :let={event} label="When">
                <.datetime
                  id={"payables-match-event-at-#{event.id}"}
                  value={event.occurred_at}
                  precision={:second}
                />
              </:col>
              <:col :let={event} label="Event">
                <.badge dot={false}>{event_label(event.event)}</.badge>
              </:col>
              <:col :let={event} label="Exceptions">
                {event.lines |> Enum.flat_map(& &1.exceptions) |> length()}
              </:col>
              <:col :let={event} label="Reason">{event.reason || "—"}</:col>
              <:col :let={event} label="By">
                {actor_text(event.actor_user_id, event.actor_impersonator_id)}
              </:col>
            </.table>
          </.card>

          <.modal
            :if={@dialog == "approve_exception"}
            id="payables-bill-approve-exception-modal"
            title="Approve the match exceptions"
            on_cancel={JS.push("close_dialog")}
          >
            <:description>
              The bill may then be posted over the exceptions its last hold recorded. The approval is kept with your name and the reason.
            </:description>
            <.form
              for={%{}}
              as={:dialog}
              id="payables-bill-approve-exception-form"
              phx-change="reason"
              phx-submit="approve_exception"
            >
              <.input
                type="textarea"
                name="dialog[reason]"
                id="payables-bill-approve-exception-reason"
                value={@reason}
                label="Reason (1 to 500 characters)"
                maxlength="500"
                required
              />
              <div class="mt-4 flex justify-end gap-2">
                <.button type="button" id="payables-bill-approve-exception-close" phx-click="close_dialog">
                  Keep held
                </.button>
                <.button
                  type="submit"
                  id="payables-bill-approve-exception-confirm"
                  variant="primary"
                  phx-disable-with="Approving…"
                >
                  Approve exceptions
                </.button>
              </div>
            </.form>
          </.modal>

          <.modal
            :if={@dialog == "void"}
            id="payables-bill-void-modal"
            title="Void this document"
            on_cancel={JS.push("close_dialog")}
          >
            <:description>
              The document stays on record as voided and cannot be approved or posted; it cannot be undone.
            </:description>
            <.form
              for={%{}}
              as={:dialog}
              id="payables-bill-void-form"
              phx-change="reason"
              phx-submit="void"
            >
              <.input
                type="textarea"
                name="dialog[reason]"
                id="payables-bill-void-reason"
                value={@reason}
                label="Reason (1 to 500 characters)"
                maxlength="500"
                required
              />
              <div class="mt-4 flex justify-end gap-2">
                <.button type="button" id="payables-bill-void-close" phx-click="close_dialog">
                  Keep document
                </.button>
                <.button
                  type="submit"
                  id="payables-bill-void-confirm"
                  variant="danger"
                  phx-disable-with="Voiding…"
                >
                  Void document
                </.button>
              </div>
            </.form>
          </.modal>
        <% end %>
      </.page>
    </Layouts.app>
    """
  end
end
