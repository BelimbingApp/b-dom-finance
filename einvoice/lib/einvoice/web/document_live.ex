defmodule Bilimbi.Finance.Einvoice.Web.DocumentLive do
  @moduledoc """
  One fiscal document: its parties, lines, totals, the authority's
  identifiers, its validation link with the QR code a buyer scans, every
  status event, and the ledger entries it posted. Actions: submit to the
  authority, refresh the status, cancel with a reason inside the 72-hour
  window, generate and download the PDF, and copy the share link.

  The record is read-first; nothing on it is edited. Every action is a
  facade call that re-asks its capability, and the `can_*` assigns only
  decide which controls show.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Base.UI.Workspace
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.QrCode
  alias Bilimbi.Finance.Einvoice.Web.DocumentsLive

  @submit "finance.einvoice.documents.submit"
  @cancel "finance.einvoice.documents.cancel"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope.scope
    company_id = Scope.actor(scope).company_id

    socket =
      socket
      |> assign(:active_nav, "finance.einvoice.documents")
      |> assign(:company_id, company_id)
      |> assign(:document_id, Params.positive_integer(id, 0))
      |> assign(:cancel_reason, "")
      |> assign(:cancelling?, false)
      |> assign(:copy, nil)
      |> assign(:can_submit?, Authz.can(scope, @submit).allowed)
      |> assign(:can_cancel?, Authz.can(scope, @cancel).allowed)
      |> load()

    socket =
      if socket.assigns.document,
        do:
          Workspace.announce(socket, %{kind: "finance/einvoice", id: socket.assigns.document.id}),
        else: socket

    {:ok, socket}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    socket =
      case Einvoice.submit_document(
             scope(socket),
             socket.assigns.company_id,
             socket.assigns.document_id
           ) do
        {:ok, _job} ->
          put_flash(
            socket,
            :success,
            "Submission queued. The status updates as the authority answers."
          )

        {:error, reason} ->
          put_flash(socket, :error, submit_message(reason))
      end

    {:noreply, load(socket)}
  end

  def handle_event("refresh", _params, socket) do
    socket =
      case Einvoice.refresh_status(
             scope(socket),
             socket.assigns.company_id,
             socket.assigns.document_id
           ) do
        {:ok, document} ->
          put_flash(socket, :info, "Status read from the authority: #{document.status}.")

        {:error, reason} ->
          put_flash(socket, :error, refresh_message(reason))
      end

    {:noreply, load(socket)}
  end

  def handle_event("open_cancel", _params, socket) do
    {:noreply, socket |> clear_flash() |> assign(:cancelling?, true)}
  end

  def handle_event("close_cancel", _params, socket) do
    {:noreply, assign(socket, cancelling?: false, cancel_reason: "")}
  end

  def handle_event("cancel_reason", %{"cancel" => %{"reason" => reason}}, socket) do
    {:noreply, assign(socket, :cancel_reason, reason)}
  end

  def handle_event("cancel", %{"cancel" => %{"reason" => reason}}, socket) do
    socket =
      case Einvoice.cancel_document(
             scope(socket),
             socket.assigns.company_id,
             socket.assigns.document_id,
             reason
           ) do
        {:ok, _document} ->
          socket
          |> assign(cancelling?: false, cancel_reason: "")
          |> put_flash(:success, "The authority cancelled the document.")

        {:error, reason} ->
          socket |> assign(:cancelling?, false) |> put_flash(:error, cancel_message(reason))
      end

    {:noreply, load(socket)}
  end

  def handle_event("generate_pdf", _params, socket) do
    socket =
      case Einvoice.generate_pdf(
             scope(socket),
             socket.assigns.company_id,
             socket.assigns.document_id
           ) do
        {:ok, _stored} -> put_flash(socket, :success, "PDF generated.")
        {:error, reason} -> put_flash(socket, :error, pdf_message(reason))
      end

    {:noreply, load(socket)}
  end

  # The clipboard hook reports whether the browser took the text; the page
  # says "Copied" only then.
  def handle_event("link-copied", %{"copied" => copied}, socket) when is_boolean(copied) do
    {:noreply, assign(socket, :copy, if(copied, do: :copied, else: :failed))}
  end

  defp scope(socket), do: socket.assigns.current_scope.scope

  defp load(socket) do
    case Einvoice.get_document(
           scope(socket),
           socket.assigns.company_id,
           socket.assigns.document_id
         ) do
      {:ok, document} ->
        socket
        |> assign(:document, document)
        |> assign(
          :page_title,
          "#{DocumentsLive.type_label(document.document_type)} #{document.code_number}"
        )
        |> assign(:qr_svg, QrCode.svg(document.validation_url))

      {:error, _reason} ->
        socket
        |> assign(:document, nil)
        |> assign(:page_title, "E-invoice")
        |> assign(:qr_svg, nil)
    end
  end

  defp submit_message(:not_submittable),
    do: "Only a recorded, refused, or invalid document can be submitted."

  defp submit_message(:missing_credentials),
    do: "Set the client ID and secret for this environment in the e-invoice settings first."

  defp submit_message(:signing_key_required),
    do:
      "The chosen format version needs the certificate and matching private key in the e-invoice settings, or choose the unsigned version."

  defp submit_message(:unauthorized), do: "You do not have permission to submit documents."

  defp submit_message(:company_archived),
    do: "This company is archived; nothing can be submitted for it."

  defp submit_message(reason), do: "The submission could not be queued (#{inspect(reason)})."

  defp refresh_message(:not_submitted),
    do: "The authority has not given this document a UUID yet; submit it first."

  defp refresh_message({:authority, :rate_limited}),
    do: "The authority is limiting requests. Try again in a minute."

  defp refresh_message({:authority, :authority_unavailable}),
    do: "The authority could not be reached. Try again later."

  defp refresh_message({:authority, _reason}),
    do: "The authority did not answer with a status; the answer is recorded on the document."

  defp refresh_message(:unauthorized), do: "You do not have permission to read the status."
  defp refresh_message(:company_archived), do: "The company is archived."
  defp refresh_message(reason), do: "The status could not be refreshed (#{inspect(reason)})."

  defp cancel_message(:not_cancellable), do: "Only a validated document can be cancelled."
  defp cancel_message(:company_archived), do: "The company is archived."

  defp cancel_message(:cancellation_period_over),
    do: "The 72-hour cancellation window has closed; issue a credit note instead."

  defp cancel_message(:active_referencing_documents),
    do: "A note the authority holds references this document; cancel the note first."

  defp cancel_message(:invalid_reason), do: "Give a reason of 1 to 300 characters."

  defp cancel_message({:refused, :period_over, _}),
    do: "The authority refused: the cancellation window has closed."

  defp cancel_message({:refused, :incorrect_state, _}),
    do: "The authority refused: the document is not in a state it can cancel. Refresh the status."

  defp cancel_message({:refused, :active_referencing_documents, _}),
    do: "The authority refused: an active document references this one."

  defp cancel_message({:refused, _code, reason}),
    do: "The authority refused the cancellation#{if reason, do: ": " <> reason, else: "."}"

  defp cancel_message(:rate_limited),
    do: "The authority is limiting requests. Try again in a minute."

  defp cancel_message(:authority_unavailable),
    do: "The authority could not be reached. Try again later."

  defp cancel_message(:unauthorized), do: "You do not have permission to cancel documents."
  defp cancel_message(reason), do: "The document could not be cancelled (#{inspect(reason)})."

  defp pdf_message(:unauthorized), do: "You do not have permission to generate the PDF."

  defp pdf_message(:storage_unavailable),
    do: "Base Artifacts has no storage root configured; an operator sets it in Operator Settings."

  defp pdf_message(reason), do: "The PDF could not be generated (#{inspect(reason)})."

  defp attention_text(:overdue),
    do:
      "Not submitted within 72 hours of the authority becoming unavailable; the submission keeps retrying."

  defp attention_text(:rejection_requested),
    do: "The buyer requested rejection. Cancel within the 72-hour window, or issue a credit note."

  defp attention_text(:unposted), do: "Validated but not yet posted to the ledger."

  defp attention_text(:posting_failed),
    do: "The ledger posting failed; see the last posting event."

  defp attention_text(:unreversed), do: "Cancelled but its ledger entry has not been reversed."

  defp attention_text(:reversal_failed),
    do: "The ledger reversal failed; see the last reversal event."

  defp money(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp money(nil), do: "—"

  defp party_lines(party) do
    address = party["address"] || %{}

    [
      party["name"],
      "TIN #{party["tax_id"]}",
      party["registration_number"] &&
        "#{party["registration_type"] || "Reg."} #{party["registration_number"]}",
      Enum.join(List.wrap(address["lines"]), ", "),
      Enum.join(
        Enum.reject(
          [address["postcode"], address["city"], address["state_code"], address["country_code"]],
          &is_nil/1
        ),
        " "
      ),
      party["phone"],
      party["email"]
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
  end

  defp event_detail(event) do
    [
      event.authority_status && "status #{event.authority_status}",
      event.submission_uid && "submission #{event.submission_uid}",
      event.document_uuid && "UUID #{event.document_uuid}",
      event.ledger_entry_id && "entry ##{event.ledger_entry_id}",
      event.http_status && "HTTP #{event.http_status}",
      event.reason
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp actor_text(%{actor_type: "user", actor_user_id: id, actor_impersonator_id: nil}),
    do: "User ##{id}"

  defp actor_text(%{actor_type: "user", actor_user_id: id, actor_impersonator_id: by}),
    do: "User ##{id} (impersonated by ##{by})"

  defp actor_text(%{actor_type: "system", system_principal: name}), do: "System · #{name}"
  defp actor_text(_event), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="einvoice-document" variant={:detail}>
        <.empty_state
          :if={is_nil(@document)}
          id="einvoice-document-missing"
          title="Document not found"
          reason="There is no such document for this company, or it cannot be read with your current access."
        >
          <:action>
            <.link navigate={~p"/finance/einvoice/documents"}>All documents</.link>
          </:action>
        </.empty_state>

        <%= if @document do %>
          <.header>
            {DocumentsLive.type_label(@document.document_type)} {@document.code_number}
            <:subtitle>
              <.badge kind={DocumentsLive.status_kind(@document.status)}>
                {DocumentsLive.status_label(@document.status)}
              </.badge>
              <span class="ml-2 text-ink-muted">{@document.environment}</span>
            </:subtitle>
            <:actions>
              <.link id="einvoice-document-back" navigate={~p"/finance/einvoice/documents"}>All documents</.link>
              <.button
                :if={@can_submit? and @document.status in ["issued", "refused", "invalid"]}
                id="einvoice-document-submit"
                phx-click="submit"
                variant="primary"
              >
                Submit to authority
              </.button>
              <.button
                :if={@can_submit? and @document.document_uuid}
                id="einvoice-document-refresh"
                phx-click="refresh"
              >
                Refresh status
              </.button>
              <.button
                :if={@can_cancel? and @document.status in ["valid", "rejected"]}
                id="einvoice-document-open-cancel"
                phx-click="open_cancel"
                variant="danger"
              >
                Cancel document
              </.button>
              <.button id="einvoice-document-generate-pdf" phx-click="generate_pdf">
                Generate PDF
              </.button>
              <.link
                :if={@document.pdf_artifact_id}
                id="einvoice-document-download-pdf"
                href={
                  ~p"/finance/einvoice/documents/#{@document.id}/pdf/#{@document.pdf_artifact_id}"
                }
                download="e-invoice-#{@document.id}.pdf"
              >
                Download PDF
              </.link>
            </:actions>
          </.header>

          <.card
            :if={@document.attention != []}
            id="einvoice-document-attention"
            inner_class="p-5 sm:p-6"
            role="alert"
          >
            <.section_heading id="einvoice-document-attention-heading" title="Needs attention" />
            <ul class="mt-2 list-disc space-y-1 pl-5 text-sm text-ink">
              <li :for={flag <- @document.attention} id={"einvoice-attention-#{flag}"}>
                {attention_text(flag)}
              </li>
            </ul>
          </.card>

          <div class="grid gap-4 lg:grid-cols-3">
            <.card
              id="einvoice-document-supplier"
              inner_class="p-5 sm:p-6"
              role="region"
              aria-labelledby="einvoice-document-supplier-heading"
            >
              <.section_heading id="einvoice-document-supplier-heading" title="Supplier" />
              <p :for={line <- party_lines(@document.supplier)} class="text-sm text-ink">{line}</p>
            </.card>
            <.card
              id="einvoice-document-buyer"
              inner_class="p-5 sm:p-6"
              role="region"
              aria-labelledby="einvoice-document-buyer-heading"
            >
              <.section_heading id="einvoice-document-buyer-heading" title="Buyer" />
              <p :for={line <- party_lines(@document.buyer)} class="text-sm text-ink">{line}</p>
            </.card>
            <.card
              id="einvoice-document-validation"
              inner_class="p-5 sm:p-6"
              role="region"
              aria-labelledby="einvoice-document-validation-heading"
            >
              <.section_heading id="einvoice-document-validation-heading" title="Validation" />
              <.list id="einvoice-document-authority-facts">
                <:item title="Submission UID">{@document.submission_uid || "—"}</:item>
                <:item title="Document UUID">{@document.document_uuid || "—"}</:item>
                <:item title="Validated">
                  <.datetime
                    :if={@document.validated_at}
                    id="einvoice-document-validated-at"
                    value={@document.validated_at}
                    precision={:second}
                  />
                  <span :if={!@document.validated_at}>—</span>
                </:item>
                <:item title="Cancellable until">
                  <.datetime
                    :if={@document.cancellable_until}
                    id="einvoice-document-cancellable-until"
                    value={@document.cancellable_until}
                    precision={:second}
                  />
                  <span :if={!@document.cancellable_until}>—</span>
                </:item>
                <:item title="Ledger entry">
                  {if @document.ledger_entry_id, do: "##{@document.ledger_entry_id}", else: "—"}
                  {if @document.reversal_entry_id,
                    do: " (reversed by ##{@document.reversal_entry_id})",
                    else: ""}
                </:item>
              </.list>
              <div
                :if={@document.validation_url}
                id="einvoice-document-share"
                phx-hook="ClipboardCopy"
                data-copy-event="link-copied"
                class="mt-4 space-y-2"
              >
                <div
                  id="einvoice-document-qr"
                  class="w-40"
                  aria-label="QR code of the validation link"
                >
                  {Phoenix.HTML.raw(@qr_svg)}
                </div>
                <a
                  id="einvoice-document-validation-link"
                  href={@document.validation_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="break-all text-sm text-action hover:underline"
                >
                  {@document.validation_url}
                </a>
                <div class="flex items-center gap-2">
                  <.button
                    id="einvoice-document-copy-link"
                    type="button"
                    data-copy-text={@document.validation_url}
                  >
                    Copy share link
                  </.button>
                  <span
                    :if={@copy == :copied}
                    id="einvoice-document-copied"
                    class="text-xs text-ink-muted"
                  >Copied</span>
                  <span
                    :if={@copy == :failed}
                    id="einvoice-document-copy-failed"
                    class="text-xs text-danger"
                  >The browser refused the copy; select the link instead.</span>
                </div>
              </div>
              <p
                :if={!@document.validation_url}
                id="einvoice-document-no-link"
                class="mt-4 text-sm text-ink-muted"
              >
                The validation link and its QR code appear once the authority validates the document.
              </p>
            </.card>
          </div>

          <.card
            id="einvoice-document-lines"
            inner_class="p-0"
            role="region"
            aria-labelledby="einvoice-document-lines-heading"
          >
            <.section_heading id="einvoice-document-lines-heading" title="Lines" class="p-5 pb-0" />
            <.table
              id="einvoice-document-lines-table"
              rows={@document.lines}
              framed={false}
              row_id={&"einvoice-line-#{&1.line_number}"}
              caption="Lines"
            >
              <:col :let={line} label="#">{line.line_number}</:col>
              <:col :let={line} label="Description">{line.description}</:col>
              <:col :let={line} label="Classification">{line.classification_code}</:col>
              <:col :let={line} label="Quantity" align={:right}>
                {money(line.quantity)} {line.unit_code}
              </:col>
              <:col :let={line} label="Unit price" align={:right}>{money(line.unit_price)}</:col>
              <:col :let={line} label="Amount" align={:right}>
                {money(line.line_extension_amount)}
              </:col>
              <:col :let={line} label="Tax" align={:right}>
                {line.tax_type} {money(line.tax_rate)}% = {money(line.tax_amount)}
              </:col>
            </.table>
            <div class="p-5">
              <.list id="einvoice-document-totals">
                <:item title="Tax exclusive">
                  {money(@document.tax_exclusive_amount)} {@document.currency_code}
                </:item>
                <:item title="Tax">{money(@document.tax_amount)} {@document.currency_code}</:item>
                <:item title="Tax inclusive">
                  {money(@document.tax_inclusive_amount)} {@document.currency_code}
                </:item>
                <:item title="Payable">
                  {money(@document.payable_amount)} {@document.currency_code}
                </:item>
              </.list>
            </div>
          </.card>

          <.card
            id="einvoice-document-events"
            inner_class="p-0"
            role="region"
            aria-labelledby="einvoice-document-events-heading"
          >
            <.section_heading id="einvoice-document-events-heading" title="History" class="p-5 pb-0" />
            <.table
              id="einvoice-document-events-table"
              rows={@document.events}
              framed={false}
              row_id={&"einvoice-event-#{&1.sequence}"}
              caption="Status events"
            >
              <:col :let={event} label="#">{event.sequence}</:col>
              <:col :let={event} label="When">
                <.datetime
                  id={"einvoice-event-at-#{event.sequence}"}
                  value={event.recorded_at}
                  precision={:second}
                />
              </:col>
              <:col :let={event} label="Event">
                <.badge dot={false}>{event.event}</.badge>
              </:col>
              <:col :let={event} label="Detail">
                <span class="break-words text-xs text-ink-muted">{event_detail(event)}</span>
              </:col>
              <:col :let={event} label="By">{actor_text(event)}</:col>
            </.table>
          </.card>

          <.modal
            :if={@cancelling?}
            id="einvoice-document-cancel-modal"
            title="Cancel this document"
            on_cancel={JS.push("close_cancel")}
          >
            <:description>
              The authority marks the document cancelled; it cannot be undone. Its ledger entry is reversed.
            </:description>
            <.form
              for={%{}}
              as={:cancel}
              id="einvoice-document-cancel-form"
              phx-change="cancel_reason"
              phx-submit="cancel"
            >
              <.input
                type="textarea"
                name="cancel[reason]"
                id="einvoice-document-cancel-reason"
                value={@cancel_reason}
                label="Reason (1 to 300 characters)"
                maxlength="300"
                required
              />
              <div class="mt-4 flex justify-end gap-2">
                <.button type="button" id="einvoice-document-cancel-close" phx-click="close_cancel">Keep document</.button>
                <.button
                  type="submit"
                  id="einvoice-document-cancel-confirm"
                  variant="danger"
                  phx-disable-with="Cancelling…"
                >Cancel document</.button>
              </div>
            </.form>
          </.modal>
        <% end %>
      </.page>
    </Layouts.app>
    """
  end
end
