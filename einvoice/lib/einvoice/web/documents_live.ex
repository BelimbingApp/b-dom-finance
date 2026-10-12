defmodule Bilimbi.Finance.Einvoice.Web.DocumentsLive do
  @moduledoc """
  The signed-in company's fiscal documents, newest first, filtered by
  status, type, and environment and searched by code number or
  counterparty (the buyer, or the supplier of a self-billed document).
  Page, search, filters, and page size live in the URL
  (`Bilimbi.Base.UI.ListState`).
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.UI.ListColumns
  alias Bilimbi.Base.UI.ListState
  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.Configuration

  @statuses Einvoice.status_events()
  @types Configuration.authority().issuable_document_types()

  @list ListState.spec!(
          page_sizes: Einvoice.page_sizes(),
          default_page_size: 25,
          page_size_param: "page_size",
          filters: [
            status: {:one_of, @statuses, ""},
            document_type: {:one_of, @types, ""},
            environment: {:one_of, ~w(sandbox production), ""}
          ]
        )

  @builtins [
    %{id: "code_number", label: "Number", type: :string},
    %{id: "document_type", label: "Type", type: :string},
    %{id: "issued_at", label: "Issued", type: :datetime},
    %{id: "buyer", label: "Counterparty", type: :string},
    %{id: "payable_amount", label: "Payable", type: :string, align: :right},
    %{id: "status", label: "Status", type: :string},
    %{id: "environment", label: "Environment", type: :string}
  ]

  @impl true
  def mount(_params, _session, socket) do
    company_id = Scope.actor(socket.assigns.current_scope.scope).company_id

    {:ok,
     socket
     |> assign(:page_title, "E-invoices")
     |> assign(:active_nav, "finance.einvoice.documents")
     |> assign(:company_id, company_id)
     |> assign(:status_options, [{"All statuses", ""} | Enum.map(@statuses, &{&1, &1})])
     |> assign(:type_options, [{"All types", ""} | Enum.map(@types, &{type_label(&1), &1})])
     |> assign(:columns, ListColumns.mount("einvoice-documents-table", @builtins))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, ListState.parse(params, @list))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters = if is_map(params), do: Map.get(params, "filters", %{}), else: %{}
    {:noreply, push_state(socket, ListState.apply_filters(socket.assigns.state, filters))}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, push_state(socket, ListState.put_page(socket.assigns.state, page))}
  end

  def handle_event("grid", params, socket) do
    case ListColumns.handle(socket.assigns.columns, params) do
      {:update, columns} -> {:noreply, assign(socket, :columns, columns)}
      _other -> {:noreply, socket}
    end
  end

  defp push_state(socket, state) do
    push_patch(socket, to: ~p"/finance/einvoice/documents?#{ListState.to_params(state)}")
  end

  defp load(socket, state) do
    result =
      Einvoice.page_documents(socket.assigns.current_scope.scope, socket.assigns.company_id,
        page: state.page,
        page_size: state.page_size,
        search: Params.blank_to_nil(state.search),
        status: Params.blank_to_nil(state.filters.status),
        document_type: Params.blank_to_nil(state.filters.document_type),
        environment: Params.blank_to_nil(state.filters.environment)
      )

    case result do
      {:ok, page} ->
        corrected = ListState.clamp_to_last_page(state, page)

        if corrected.page != state.page do
          load(socket, corrected)
        else
          socket
          |> assign(:state, state)
          |> assign(:page, page)
          |> assign(:unavailable?, false)
          |> assign(:columns, ListColumns.load(socket.assigns.columns, page.entries, & &1.id))
          |> assign(:filters_form, ListState.filters_form(state))
        end

      {:error, _reason} ->
        socket
        |> assign(:state, state)
        |> assign(:page, ListState.paginate([], state))
        |> assign(:unavailable?, true)
        |> assign(:columns, ListColumns.load(socket.assigns.columns, [], & &1.id))
        |> assign(:filters_form, ListState.filters_form(state))
    end
  end

  @doc false
  def type_label(type), do: Configuration.authority().document_type_name(type)

  @doc false
  def status_kind("valid"), do: :success
  def status_kind("submitted"), do: :info
  def status_kind("issued"), do: :default
  def status_kind("consolidated"), do: :info
  def status_kind("released"), do: :default
  def status_kind("cancelled"), do: :warning
  def status_kind("rejected"), do: :warning
  def status_kind(_other), do: :danger

  @doc false
  def status_label(nil), do: "recorded"
  def status_label(status), do: status

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="einvoice-documents">
        <.header>
          E-invoices
          <:subtitle>Fiscal documents this company issued, newest first.</:subtitle>
          <:actions>
            <.link
              id="einvoice-documents-consolidation"
              navigate={~p"/finance/einvoice/consolidation"}
            >
              Consolidation
            </.link>
            <.link
              id="einvoice-documents-reconciliation"
              navigate={~p"/finance/einvoice/reconciliation"}
            >
              Reconciliation
            </.link>
          </:actions>
        </.header>

        <.filter_toolbar id="einvoice-documents-filters" form={@filters_form} event="filter">
          <:control
            type={:search}
            field={@filters_form[:search]}
            id="einvoice-documents-search"
            label="Search documents"
            placeholder="Search by number or counterparty…"
          />
          <:control
            type={:select}
            field={@filters_form[:status]}
            id="einvoice-documents-status"
            label="Filter by status"
            options={@status_options}
          />
          <:control
            type={:select}
            field={@filters_form[:document_type]}
            id="einvoice-documents-type"
            label="Filter by type"
            options={@type_options}
          />
          <:control
            type={:select}
            field={@filters_form[:environment]}
            id="einvoice-documents-environment"
            label="Filter by environment"
            options={[{"All environments", ""}, {"Sandbox", "sandbox"}, {"Production", "production"}]}
          />
        </.filter_toolbar>

        <.empty_state
          :if={@unavailable?}
          id="einvoice-documents-unavailable"
          title="Documents unavailable"
          reason="This company's documents cannot be read with your current access."
        />

        <div :if={!@unavailable?} class="mt-4">
          <.flex_table
            id="einvoice-documents-table"
            framed={false}
            columns={@columns.column_views}
            rows={@columns.rows}
            mode={@columns.mode}
            zoom={@columns.zoom}
            suggestions={@columns.suggestions}
            add_query={@columns.add_query}
            row_id={&"einvoice-document-#{&1}"}
            caption="E-invoices"
          >
            <:col :let={%{record: document}} id="code_number">
              <.record_link
                workspace={@workspace}
                kind="finance/einvoice"
                record_id={document.id}
                navigate={~p"/finance/einvoice/documents/#{document.id}"}
                class="font-medium text-ink-strong hover:underline"
              >
                {document.code_number}
              </.record_link>
            </:col>
            <:col :let={%{record: document}} id="document_type">
              <.badge dot={false}>{type_label(document.document_type)}</.badge>
            </:col>
            <:col :let={%{record: document}} id="issued_at">
              <.datetime id={"einvoice-document-issued-#{document.id}"} value={document.issued_at} />
            </:col>
            <:col :let={%{record: document}} id="buyer">{document.counterparty_name}</:col>
            <:col :let={%{record: document}} id="payable_amount">
              <span class="tabular-nums">
                {Decimal.to_string(document.payable_amount, :normal)} {document.currency_code}
              </span>
            </:col>
            <:col :let={%{record: document}} id="status">
              <.badge kind={status_kind(document.status)}>{status_label(document.status)}</.badge>
            </:col>
            <:col :let={%{record: document}} id="environment">{document.environment}</:col>
            <:empty :if={@page.total_entries == 0}>
              No documents match the current filters. Documents are issued through the e-invoicing API.
            </:empty>
          </.flex_table>

          <.pagination
            id="einvoice-documents-pagination"
            page={@page}
            page_sizes={Einvoice.page_sizes()}
            filters_form={@filters_form}
            filters_event="filter"
          />
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
