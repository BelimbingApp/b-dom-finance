defmodule Bilimbi.Finance.Attachments.Web.IndexLive do
  @moduledoc """
  The company's source documents: every attachment by number with the record
  it supports, its file, SHA-256, retain-until, and capture, a download link
  each, and the company's retention setting with its change history. The
  list is filtered by the kind of record and by standing; an auditor reads
  the index here and downloads any file. Lengthening the retention is a
  facade call that re-asks its capability.

  Attaching a file happens on the record's own page (a bill, a bank
  account's statements); records with no page (receivables, manual
  journals) take attachments through the facade.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Attachments
  alias Bilimbi.Finance.Attachments.Web.Format

  @manage_retention Attachments.manage_retention_capability()
  @page 200

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope.scope

    {:ok,
     socket
     |> assign(:page_title, "Source documents")
     |> assign(:active_nav, "finance.attachments")
     |> assign(:company_id, Scope.actor(scope).company_id)
     |> assign(:source, nil)
     |> assign(:status, "standing")
     |> assign(:retention_form, to_form(%{"years" => "", "reason" => ""}, as: :retention))
     |> load()}
  end

  defp load(socket) do
    %{current_scope: %{scope: scope} = current_scope, company_id: company_id} = socket.assigns

    attachments =
      case Attachments.list_company_attachments(scope, company_id,
             source: socket.assigns.source,
             status: socket.assigns.status,
             limit: @page
           ) do
        {:ok, attachments} -> attachments
        {:error, _reason} -> []
      end

    sources =
      case Attachments.list_company_attachments(scope, company_id, status: "all", limit: 500) do
        {:ok, all} ->
          all
          |> Enum.map(&{&1.source_label || &1.source, &1.source})
          |> Enum.uniq()
          |> Enum.sort()

        {:error, _reason} ->
          []
      end

    {retention, changes} =
      with {:ok, retention} <- Attachments.get_retention(scope, company_id),
           {:ok, changes} <- Attachments.list_retention_changes(scope, company_id) do
        {retention, Enum.reverse(changes)}
      else
        {:error, _reason} -> {nil, []}
      end

    socket
    |> assign(:attachments, attachments)
    |> assign(:more?, length(attachments) == @page)
    |> assign(:sources, sources)
    |> assign(:retention, retention)
    |> assign(:changes, changes)
    |> assign(:can_manage?, LiveAuthorization.allowed_now?(current_scope, @manage_retention))
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    source = if filter["source"] in [nil, ""], do: nil, else: filter["source"]

    status =
      if filter["status"] in ["all" | Attachments.statuses()],
        do: filter["status"],
        else: "standing"

    {:noreply, socket |> assign(source: source, status: status) |> load()}
  end

  def handle_event("more", _params, socket) do
    %{current_scope: %{scope: scope}, company_id: company_id, attachments: shown} = socket.assigns
    last = List.last(shown)

    case last &&
           Attachments.list_company_attachments(scope, company_id,
             source: socket.assigns.source,
             status: socket.assigns.status,
             limit: @page,
             after: last.attachment_number
           ) do
      {:ok, more} ->
        {:noreply, assign(socket, attachments: shown ++ more, more?: length(more) == @page)}

      _none ->
        {:noreply, assign(socket, :more?, false)}
    end
  end

  def handle_event("retention_change", %{"retention" => params}, socket),
    do: {:noreply, assign(socket, :retention_form, to_form(params, as: :retention))}

  def handle_event("set_retention", %{"retention" => params}, socket) do
    case LiveAuthorization.authorize_event(socket, @manage_retention) do
      {:denied, socket} -> {:noreply, socket}
      {:ok, socket} -> {:noreply, set_retention(socket, params)}
    end
  end

  defp set_retention(socket, params) do
    years =
      case Integer.parse(to_string(params["years"] || "")) do
        {years, ""} -> years
        _other -> params["years"]
      end

    case Attachments.set_retention(
           socket.assigns.current_scope.scope,
           socket.assigns.company_id,
           %{years: years, reason: params["reason"]}
         ) do
      {:ok, retention} ->
        socket
        |> put_flash(
          :success,
          "Source documents are now kept #{retention.years} years after the end of their financial year."
        )
        |> assign(:retention_form, to_form(%{"years" => "", "reason" => ""}, as: :retention))
        |> load()

      {:error, reason} ->
        put_flash(socket, :error, Format.refusal(reason))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="finance-attachments">
        <.header>
          Source documents
          <:subtitle>
            The original files behind the company's records, each kept as a records-grade document until its retain-until date.
          </:subtitle>
        </.header>

        <.card id="attachments-retention" inner_class="p-5 sm:p-6" role="region" aria-labelledby="attachments-retention-heading">
          <.section_heading id="attachments-retention-heading" title="Retention">
            <:description>
              How long a source document is kept after the end of the financial year its record falls in. It is only ever lengthened.
            </:description>
          </.section_heading>
          <p :if={@retention} id="attachments-retention-years" class="mt-3 text-sm">
            <span class="font-medium">{@retention.years} years</span>
            <span :if={@retention.change} class="text-ink-muted">
              since <.datetime id="attachments-retention-since" value={@retention.change.changed_at} />: {@retention.change.reason}
            </span>
            <span :if={is_nil(@retention.change)} class="text-ink-muted">(the default; the company has not set its own)</span>
          </p>

          <.form
            :if={@can_manage?}
            for={@retention_form}
            id="attachments-retention-form"
            phx-change="retention_change"
            phx-submit="set_retention"
            class="mt-4 grid gap-3 sm:grid-cols-3"
          >
            <.input field={@retention_form[:years]} type="number" label="Years" min="1" max="100" required />
            <.input field={@retention_form[:reason]} type="text" label="Reason" maxlength="500" required />
            <div class="flex items-end">
              <.button type="submit" id="attachments-retention-submit" variant="primary" phx-disable-with="Saving…">
                Lengthen retention
              </.button>
            </div>
          </.form>

          <.table :if={@changes != []} id="attachments-retention-changes" rows={@changes} framed={false} row_id={&"retention-change-#{&1.id}"}>
            <:col :let={change} label="#">{change.change_number}</:col>
            <:col :let={change} label="Years" align={:right}>{change.years}</:col>
            <:col :let={change} label="Reason">{change.reason}</:col>
            <:col :let={change} label="Changed">
              <.datetime id={"retention-change-#{change.id}-at"} value={change.changed_at} />
            </:col>
          </.table>
        </.card>

        <.card id="attachments" inner_class="p-0" role="region" aria-labelledby="attachments-heading">
          <.section_heading id="attachments-heading" title="Attachments" count={length(@attachments)} class="p-5 pb-0">
            <:actions>
              <.form for={%{}} as={:filter} id="attachments-filter" phx-change="filter" class="flex gap-2">
                <.input
                  type="select"
                  name="filter[source]"
                  id="attachments-filter-source"
                  value={@source}
                  prompt="Every kind of record"
                  options={@sources}
                />
                <.input
                  type="select"
                  name="filter[status]"
                  id="attachments-filter-status"
                  value={@status}
                  options={[{"Standing", "standing"}, {"Replaced", "replaced"}, {"Removed", "removed"}, {"All", "all"}]}
                />
              </.form>
            </:actions>
          </.section_heading>
          <.table id="attachments-table" rows={@attachments} framed={false} row_id={&"attachment-#{&1.id}"}>
            <:col :let={attachment} label="#">{attachment.attachment_number}</:col>
            <:col :let={attachment} label="Record">
              {attachment.source_label || attachment.source} · {attachment.document_label}
            </:col>
            <:col :let={attachment} label="Dated">{attachment.document_date}</:col>
            <:col :let={attachment} label="File">
              <.link
                id={"attachment-#{attachment.id}-download"}
                href={~p"/finance/attachments/#{attachment.id}/download"}
                download={attachment.file_name}
              >
                {attachment.file_name}
              </.link>
              <span class="text-ink-muted">({Format.bytes(attachment.byte_size)})</span>
            </:col>
            <:col :let={attachment} label="SHA-256">
              <span class="font-mono" title={attachment.sha256}>{Format.short_hash(attachment.sha256)}</span>
            </:col>
            <:col :let={attachment} label="Kept until">{Format.retain_until(attachment.retain_until)}</:col>
            <:col :let={attachment} label="Captured">
              <.datetime id={"attachment-#{attachment.id}-captured"} value={attachment.captured_at} />
            </:col>
            <:col :let={attachment} label="Standing">
              <.badge kind={if attachment.status == "standing", do: :success, else: :neutral}>{attachment.status}</.badge>
            </:col>
            <:empty title="No source documents" reason="Nothing matching has been attached to this company's records." />
          </.table>
          <div :if={@more?} class="p-4">
            <.button type="button" id="attachments-more" phx-click="more">Show more</.button>
          </div>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
