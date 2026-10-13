defmodule Bilimbi.Finance.Payables.Web.BillsLive do
  @moduledoc """
  The signed-in company's payables documents, newest first, filtered by
  status and type and searched by party or the party's document number.
  "Held bills" is the status filter set to `held`: the bills whose three-way
  match found exceptions nobody has approved yet. Page, search, filters, and
  page size live in the URL (`Bilimbi.Base.UI.ListState`).
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.UI.ListColumns
  alias Bilimbi.Base.UI.ListState
  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Finance.Payables

  @statuses Payables.document_statuses()
  @types Payables.document_types()

  @list ListState.spec!(
          page_sizes: Payables.page_sizes(),
          default_page_size: 25,
          page_size_param: "page_size",
          filters: [
            status: {:one_of, @statuses, ""},
            document_type: {:one_of, @types, ""}
          ]
        )

  @builtins [
    %{id: "number", label: "Number", type: :string},
    %{id: "document_type", label: "Type", type: :string},
    %{id: "party", label: "Party", type: :string},
    %{id: "party_document_number", label: "Party's number", type: :string},
    %{id: "document_date", label: "Date", type: :string},
    %{id: "total", label: "Total", type: :string, align: :right},
    %{id: "status", label: "Status", type: :string},
    %{id: "match_status", label: "Match", type: :string}
  ]

  @impl true
  def mount(_params, _session, socket) do
    company_id = Scope.actor(socket.assigns.current_scope.scope).company_id

    {:ok,
     socket
     |> assign(:page_title, "Bills")
     |> assign(:active_nav, "finance.payables.bills")
     |> assign(:company_id, company_id)
     |> assign(:status_options, [{"All statuses", ""} | Enum.map(@statuses, &{&1, &1})])
     |> assign(:type_options, [{"All types", ""} | Enum.map(@types, &{type_label(&1), &1})])
     |> assign(:columns, ListColumns.mount("payables-bills-table", @builtins))}
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
    push_patch(socket, to: ~p"/finance/payables/bills?#{ListState.to_params(state)}")
  end

  defp load(socket, state) do
    result =
      Payables.page_documents(socket.assigns.current_scope.scope, socket.assigns.company_id,
        page: state.page,
        page_size: state.page_size,
        search: Params.blank_to_nil(state.search),
        status: Params.blank_to_nil(state.filters.status),
        document_type: Params.blank_to_nil(state.filters.document_type)
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
  def type_label("bill"), do: "Bill"
  def type_label("debit_note"), do: "Debit note"
  def type_label(type), do: type

  @doc false
  def status_kind("posted"), do: :success
  def status_kind("held"), do: :warning
  def status_kind("voided"), do: :danger
  def status_kind(_other), do: :neutral

  @doc false
  def match_kind("matched"), do: :success
  def match_kind("held"), do: :warning
  def match_kind("exception_approved"), do: :neutral
  def match_kind("posted_with_exceptions"), do: :warning
  def match_kind(_other), do: :neutral

  @doc false
  def match_label("pending"), do: "not yet matched"
  def match_label("held"), do: "held"
  def match_label("exception_approved"), do: "exception approved"
  def match_label("matched"), do: "matched"
  def match_label("posted_with_exceptions"), do: "posted with exceptions"
  def match_label(nil), do: "—"

  @doc false
  def number(%{document_number: nil}), do: "—"
  def number(%{document_number: number}), do: "##{number}"

  @doc false
  # Figures as recorded, without trailing zeros: 25, 2.5, 0.0125.
  def money(%Decimal{} = value), do: value |> Decimal.normalize() |> Decimal.to_string(:normal)
  def money(nil), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="payables-bills">
        <.header>
          Bills
          <:subtitle>Bills and debit notes from this company's parties, newest first.</:subtitle>
          <:actions>
            <.link
              id="payables-bills-held"
              patch={~p"/finance/payables/bills?#{ListState.to_params(ListState.apply_filters(@state, %{"status" => "held"}))}"}
            >
              Held bills
            </.link>
          </:actions>
        </.header>

        <.filter_toolbar id="payables-bills-filters" form={@filters_form} event="filter">
          <:control
            type={:search}
            field={@filters_form[:search]}
            id="payables-bills-search"
            label="Search bills"
            placeholder="Search by party or party's number…"
          />
          <:control
            type={:select}
            field={@filters_form[:status]}
            id="payables-bills-status"
            label="Filter by status"
            options={@status_options}
          />
          <:control
            type={:select}
            field={@filters_form[:document_type]}
            id="payables-bills-type"
            label="Filter by type"
            options={@type_options}
          />
        </.filter_toolbar>

        <.empty_state
          :if={@unavailable?}
          id="payables-bills-unavailable"
          title="Bills unavailable"
          reason="This company's bills cannot be read with your current access."
        />

        <div :if={!@unavailable?} class="mt-4">
          <.flex_table
            id="payables-bills-table"
            framed={false}
            columns={@columns.column_views}
            rows={@columns.rows}
            mode={@columns.mode}
            zoom={@columns.zoom}
            suggestions={@columns.suggestions}
            add_query={@columns.add_query}
            row_id={&"payables-bill-#{&1}"}
            caption="Bills"
          >
            <:col :let={%{record: document}} id="number">
              <.record_link
                workspace={@workspace}
                kind="finance/payables"
                record_id={document.id}
                navigate={~p"/finance/payables/bills/#{document.id}"}
                class="font-medium text-ink-strong hover:underline"
              >
                {number(document)}
              </.record_link>
            </:col>
            <:col :let={%{record: document}} id="document_type">
              <.badge dot={false}>{type_label(document.document_type)}</.badge>
            </:col>
            <:col :let={%{record: document}} id="party">{document.party_name}</:col>
            <:col :let={%{record: document}} id="party_document_number">
              {document.party_document_number || "—"}
            </:col>
            <:col :let={%{record: document}} id="document_date">{document.document_date}</:col>
            <:col :let={%{record: document}} id="total">
              <span class="tabular-nums">{money(document.total)} {document.currency_code}</span>
            </:col>
            <:col :let={%{record: document}} id="status">
              <.badge kind={status_kind(document.status)}>{document.status}</.badge>
            </:col>
            <:col :let={%{record: document}} id="match_status">
              <.badge :if={document.match_status} kind={match_kind(document.match_status)}>
                {match_label(document.match_status)}
              </.badge>
              <span :if={!document.match_status}>—</span>
            </:col>
            <:empty :if={@page.total_entries == 0}>
              No documents match the current filters. Bills are recorded through the payables API.
            </:empty>
          </.flex_table>

          <.pagination
            id="payables-bills-pagination"
            page={@page}
            page_sizes={Payables.page_sizes()}
            filters_form={@filters_form}
            filters_event="filter"
          />
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
