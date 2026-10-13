defmodule Bilimbi.Finance.FixedAssets.Web.ListPage do
  @moduledoc false
  defmacro __using__(kind: kind) do
    quote do
      use Bilimbi.Base.UI, :live_view
      alias Bilimbi.Base.Authz.LiveAuthorization
      alias Bilimbi.Base.Tenancy.Scope
      alias Bilimbi.Base.UI.{ListColumns, ListState, Params, PeriodFilter}
      alias Bilimbi.Finance.FixedAssets
      alias Bilimbi.Finance.FixedAssets.Web.{Feedback, ListPage}
      @kind unquote(kind)
      @write_guard_opt_out ~w(filter page grid browser_timezone)
      @list ListState.spec!(
              page_sizes: [25, 50, 100],
              default_page_size: 25,
              page_size_param: "page_size"
            )

      @impl true
      def mount(_params, _session, socket) do
        {:ok,
         socket
         |> assign(:browser_timezone, nil)
         |> assign(:kind, @kind)
         |> assign(:page_title, ListPage.title(@kind))
         |> assign(:active_nav, "finance.fixed-assets.#{@kind}")
         |> assign(:company_id, Scope.actor(socket.assigns.current_scope.scope).company_id)
         |> assign(:columns, ListColumns.mount("assets-#{@kind}-table", ListPage.columns(@kind)))
         |> assign(:form, to_form(%{}, as: "asset"))
         |> assign(:report, nil)}
      end

      @impl true
      def handle_params(params, _uri, socket) do
        state = ListState.parse(params, @list)

        clock =
          PeriodFilter.clock(
            socket.assigns.current_scope.shell_preferences,
            socket.assigns.browser_timezone
          )

        period = PeriodFilter.parse(params, clock.today)

        options =
          for key <-
                ~w(through_entry_number through_asset_number through_event_number through_category_revision_id),
              {:ok, value} <- [Ecto.Type.cast(:integer, params[key])],
              is_integer(value) and value >= 0,
              do: {String.to_existing_atom(key), value}

        {:noreply,
         socket
         |> assign(:period_params, params)
         |> assign(:clock, clock)
         |> assign(:period, period)
         |> assign(:report_options, options)
         |> load(state)}
      end

      @impl true
      def handle_event("browser_timezone", %{"timezone" => timezone}, socket) do
        handle_params(
          socket.assigns.period_params,
          nil,
          assign(socket, :browser_timezone, timezone)
        )
      end

      def handle_event("filter", params, socket) do
        state = ListState.apply_filters(socket.assigns.state, Map.get(params, "filters", %{}))
        {:noreply, patch_state(socket, state)}
      end

      def handle_event("page", %{"page" => page}, socket),
        do: {:noreply, patch_state(socket, ListState.put_page(socket.assigns.state, page))}

      def handle_event("grid", params, socket) do
        case ListColumns.handle(socket.assigns.columns, params) do
          {:update, columns} -> {:noreply, assign(socket, :columns, columns)}
          _ -> {:noreply, socket}
        end
      end

      def handle_event("save", %{"asset" => attrs}, socket) do
        case LiveAuthorization.authorize_event(socket, ListPage.write_capability(@kind)) do
          {:denied, socket} ->
            {:noreply, socket}

          {:ok, socket} ->
            result =
              ListPage.save(
                @kind,
                socket.assigns.current_scope.scope,
                socket.assigns.company_id,
                attrs
              )

            case result do
              {:ok, saved} ->
                {level, text} = ListPage.recorded_flash(@kind, saved)

                {:noreply,
                 socket
                 |> put_flash(level, text)
                 |> assign(:form, to_form(%{}, as: "asset"))
                 |> load(socket.assigns.state)}

              {:error, reason} ->
                {:noreply,
                 socket
                 |> assign(:form, to_form(attrs, as: "asset"))
                 |> put_flash(:error, Feedback.message(reason))}
            end
        end
      end

      def handle_event("reverse", %{"asset" => attrs}, socket) do
        case LiveAuthorization.authorize_event(socket, FixedAssets.reverse_capability()) do
          {:denied, socket} ->
            {:noreply, socket}

          {:ok, socket} ->
            case FixedAssets.reverse_run(
                   socket.assigns.current_scope.scope,
                   socket.assigns.company_id,
                   Params.positive_integer(attrs["run_id"]),
                   attrs
                 ) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> put_flash(:success, "Depreciation reversed.")
                 |> load(socket.assigns.state)}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, Feedback.message(reason))}
            end
        end
      end

      defp patch_state(socket, state) do
        push_patch(socket,
          to:
            ListPage.list_path(
              @kind,
              Map.merge(ListState.to_params(state), PeriodFilter.params(socket.assigns.period))
            )
        )
      end

      defp load(socket, state) do
        result =
          ListPage.read(
            @kind,
            socket.assigns.current_scope.scope,
            socket.assigns.company_id,
            socket.assigns.period.to,
            socket.assigns.report_options
          )

        {rows, report, error} =
          case result do
            {:ok, %{rows: rows} = report} ->
              {Enum.map(
                 rows,
                 &Map.merge(
                   &1.asset,
                   Map.take(&1, [:accumulated, :carrying_value, :disposed?, :voided?])
                 )
               ), report, nil}

            {:ok, rows} ->
              {rows, nil, nil}

            {:error, reason} ->
              {[], nil, Feedback.message(reason)}
          end

        rows =
          Enum.filter(
            rows,
            &String.contains?(
              String.downcase(ListPage.search(@kind, &1)),
              String.downcase(state.search)
            )
          )

        page = ListState.paginate(rows, state)
        state = ListState.clamp_to_last_page(state, page)
        page = ListState.paginate(rows, state)

        socket
        |> assign(:state, state)
        |> assign(:page, page)
        |> assign(:report, report)
        |> assign(:read_error, error)
        |> assign(:filters_form, ListState.filters_form(state))
        |> assign(:columns, ListColumns.load(socket.assigns.columns, page.entries, & &1.id))
      end

      @impl true
      def render(assigns), do: ListPage.render(assigns)
    end
  end

  use Bilimbi.Base.UI, :html
  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.UI.{Params, PeriodFilter, ListState}
  alias Bilimbi.Finance.FixedAssets

  def title(:register), do: "Fixed assets"
  def title(:categories), do: "Asset categories"
  def title(:runs), do: "Depreciation runs"

  def columns(:register),
    do:
      Enum.map(
        [
          {"number", "Number"},
          {"description", "Asset"},
          {"cost", "Cost"},
          {"accumulated", "Depreciation"},
          {"carrying", "Carrying value"},
          {"status", "Status"}
        ],
        &column/1
      )

  def columns(:categories),
    do:
      Enum.map(
        [
          {"id", "Category ID"},
          {"name", "Category"},
          {"method", "Method"},
          {"life", "Life (months)"},
          {"revision", "Revision"}
        ],
        &column/1
      )

  def columns(:runs),
    do:
      Enum.map(
        [
          {"id", "Run ID"},
          {"period", "Period"},
          {"total", "Depreciation"},
          {"entry", "Entry"},
          {"reversed", "Reversed"},
          {"exceptions", "Skipped assets"}
        ],
        &column/1
      )

  defp column({id, label}), do: %{id: id, label: label, type: :string}
  def list_path(:register, params), do: ~p"/finance/fixed-assets/register?#{params}"
  def list_path(:categories, params), do: ~p"/finance/fixed-assets/categories?#{params}"
  def list_path(:runs, params), do: ~p"/finance/fixed-assets/runs?#{params}"
  def search(:register, row), do: "#{row.asset_number} #{row.description}"
  def search(:categories, row), do: row.name
  def search(:runs, row), do: to_string(row.period)

  def read(:register, scope, company, date, options),
    do: FixedAssets.register_report(scope, company, date, options)

  def read(:categories, scope, company, _date, _options),
    do: FixedAssets.list_categories(scope, company)

  def read(:runs, scope, company, _date, _options), do: FixedAssets.list_runs(scope, company)
  def write_capability(:register), do: FixedAssets.acquire_capability()
  def write_capability(:categories), do: FixedAssets.configure_capability()
  def write_capability(:runs), do: FixedAssets.depreciate_capability()

  def save(:register, scope, company, attrs) do
    if attrs["source"] == "bill",
      do: FixedAssets.acquire_from_bill(scope, company, attrs),
      else: FixedAssets.acquire_from_entry(scope, company, attrs)
  end

  def save(:categories, scope, company, attrs) do
    case Params.positive_id(attrs["category_id"]) do
      {:ok, id} -> FixedAssets.revise_category(scope, company, id, attrs)
      :error -> FixedAssets.create_category(scope, company, attrs)
    end
  end

  def save(:runs, scope, company, attrs) do
    case Date.from_iso8601(attrs["period"] || "") do
      {:ok, date} -> FixedAssets.depreciate(scope, company, date)
      _ -> {:error, :invalid_period}
    end
  end

  def recorded_flash(:runs, %{exceptions: [_ | _] = skipped}) do
    assets = Enum.map_join(skipped, ", ", &"##{&1.asset_number}")

    {:error,
     "Recorded without asset #{assets}: its acquisition entry was reversed. Void the acquisition from the asset page."}
  end

  def recorded_flash(_kind, _saved), do: {:success, "Recorded."}

  def status(%{voided?: true}), do: "Voided"
  def status(%{disposed?: true}), do: "Disposed"
  def status(_row), do: "In service"

  def skipped(%{exceptions: [_ | _] = skipped}),
    do: Enum.map_join(skipped, ", ", &"##{&1.asset_number} #{&1.description}")

  def skipped(_run), do: "None"

  def money(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  def money(nil), do: "—"

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id={"assets-#{@kind}"}>
        <span id="assets-browser-clock" phx-hook="BrowserTimeZone" class="hidden" />
        <.header>
          {@page_title}
          <:subtitle>Permanent accounting records for this company.</:subtitle>
        </.header>
        <.filter_toolbar id="assets-filters" form={@filters_form} event="filter">
          <:control
            type={:search}
            field={@filters_form[:search]}
            id="assets-search"
            label="Search"
            placeholder="Search records…"
          />
        </.filter_toolbar>
        <.period_filter
          :if={@kind == :register}
          id="assets-report-period"
          label="Report through"
          clock={@clock}
          state={@period}
          current_scope={@current_scope}
          path={fn period -> list_path(@kind, Map.merge(ListState.to_params(@state), period)) end}
        />
        <.empty_state
          :if={@read_error}
          id="assets-unavailable"
          title="Records unavailable"
          reason={@read_error}
        />
        <.flex_table
          :if={!@read_error}
          id={"assets-#{@kind}-table"}
          columns={@columns.column_views}
          rows={@columns.rows}
          mode={@columns.mode}
          zoom={@columns.zoom}
          suggestions={@columns.suggestions}
          add_query={@columns.add_query}
          row_id={&"asset-row-#{&1}"}
          caption={@page_title}
        >
          <:col :let={%{record: r}} id="id">{r.id}</:col>
          <:col :let={%{record: r}} id="number">{Map.get(r, :asset_number)}</:col>
          <:col :let={%{record: r}} id="description">
            <.record_link
              workspace={@workspace}
              kind="finance/fixed_assets"
              record_id={r.id}
              navigate={~p"/finance/fixed-assets/register/#{r.id}"}
            >{Map.get(r, :description)}</.record_link>
          </:col>
          <:col :let={%{record: r}} id="cost">{money(Map.get(r, :cost))}</:col>
          <:col :let={%{record: r}} id="accumulated">{money(Map.get(r, :accumulated))}</:col>
          <:col :let={%{record: r}} id="carrying">{money(Map.get(r, :carrying_value))}</:col>
          <:col :let={%{record: r}} id="status">{status(r)}</:col>
          <:col :let={%{record: r}} id="exceptions">{skipped(r)}</:col>
          <:col :let={%{record: r}} id="name">{Map.get(r, :name)}</:col>
          <:col :let={%{record: r}} id="method">{get_in(r, [:revision, :method])}</:col>
          <:col :let={%{record: r}} id="life">{get_in(r, [:revision, :life_months])}</:col>
          <:col :let={%{record: r}} id="revision">{get_in(r, [:revision, :id])}</:col>
          <:col :let={%{record: r}} id="period">{Map.get(r, :period)}</:col>
          <:col :let={%{record: r}} id="total">{money(Map.get(r, :total))}</:col>
          <:col :let={%{record: r}} id="entry">{Map.get(r, :entry_number) || "No charge"}</:col>
          <:col :let={%{record: r}} id="reversed">
            {if Map.get(r, :reversed?), do: "Yes", else: "No"}
          </:col>
          <:empty>No records match these filters.</:empty>
        </.flex_table>
        <.pagination
          id="assets-pagination"
          page={@page}
          page_sizes={[25, 50, 100]}
          filters_form={@filters_form}
          filters_event="filter"
        />
        <div :if={@report} id="assets-reconciliation" class="mt-4">
          <h2 class="font-medium">Ledger reconciliation as of {@report.as_of}</h2>
          <p>
            Ledger entry {@report.through_entry_number}; asset {@report.through_asset_number}; event {@report.through_event_number}; category revision {@report.through_category_revision_id}.
          </p>
          <.link
            id="assets-report-reproduce"
            patch={
              list_path(
                :register,
                Map.merge(
                  PeriodFilter.params(@period),
                  Map.take(@report, [
                    :through_entry_number,
                    :through_asset_number,
                    :through_event_number,
                    :through_category_revision_id
                  ])
                )
              )
            }
          >Keep this report's recorded boundary</.link>
          <p :for={r <- @report.reconciliation}>
            Account {r.account_id}: ledger {money(r.ledger_balance)}, register {money(
              r.register_balance
            )}, difference {money(r.difference)}.
          </p>
        </div>
        <.card class="mt-4">
          <h2 class="font-medium">
            {if @kind == :categories,
              do: "Record category defaults",
              else: if(@kind == :runs, do: "Run monthly depreciation", else: "Register acquisition")}
          </h2>
          <.empty_state
            :if={!LiveAuthorization.allowed_now?(@current_scope, write_capability(@kind))}
            id="assets-write-withheld"
            title="Read-only access"
            reason="Ask your company administrator for permission to record this operation."
          />
          <.form
            :if={LiveAuthorization.allowed_now?(@current_scope, write_capability(@kind))}
            for={@form}
            id="assets-write-form"
            phx-submit="save"
          >
            <%= if @kind == :categories do %>
              <.input
                field={@form[:category_id]}
                type="number"
                label="Existing category ID (blank creates one)"
              />
              <.input field={@form[:name]} label="New category name" />
              <.input field={@form[:cost_account_id]} type="number" label="Cost account ID" required />
              <.input
                field={@form[:accumulated_account_id]}
                type="number"
                label="Accumulated depreciation account ID"
                required
              />
              <.input
                field={@form[:expense_account_id]}
                type="number"
                label="Depreciation expense account ID"
                required
              />
              <.input
                field={@form[:gain_account_id]}
                type="number"
                label="Disposal gain account ID"
                required
              />
              <.input
                field={@form[:loss_account_id]}
                type="number"
                label="Disposal loss account ID"
                required
              />
              <.input
                field={@form[:method]}
                type="select"
                label="Default method"
                options={[
                  {"Straight line", "straight_line"},
                  {"Reducing balance", "reducing_balance"}
                ]}
              />
              <.input
                field={@form[:life_months]}
                type="number"
                label="Default useful life (months)"
                required
              />
              <.input field={@form[:annual_rate]} label="Annual percentage (reducing balance)" />
              <.input field={@form[:reason]} label="Reason" required />
            <% else %>
              <%= if @kind == :register do %>
                <.input
                  field={@form[:source]}
                  type="select"
                  label="Acquisition source"
                  options={[{"Manual ledger entry", "entry"}, {"Posted supplier bill", "bill"}]}
                />
                <.input
                  field={@form[:category_revision_id]}
                  type="number"
                  label="Category revision ID"
                  required
                />
                <.input field={@form[:description]} label="Asset description" required />
                <.input field={@form[:entry_id]} type="number" label="Manual entry ID" />
                <.input
                  field={@form[:entry_line_number]}
                  type="number"
                  label="Manual entry line number"
                />
                <.input field={@form[:bill_id]} type="number" label="Supplier bill ID" />
                <.input
                  field={@form[:bill_line_number]}
                  type="number"
                  label="Supplier bill line number"
                />
                <.input field={@form[:in_service_date]} type="date" label="In-service date" required />
                <.input field={@form[:residual_value]} label="Residual value (blank means zero)" />
              <% else %>
                <.input field={@form[:period]} type="date" label="First day of month" required />
                <p>
                  One charge through this month, including any scheduled depreciation still unposted. Closed periods are refused.
                </p>
              <% end %>
            <% end %>
            <.button id="assets-record" type="submit">Record</.button>
          </.form>
        </.card>
        <.card :if={@kind == :runs} class="mt-4">
          <h2 class="font-medium">Reverse a run</h2>
          <.form
            :if={LiveAuthorization.allowed_now?(@current_scope, FixedAssets.reverse_capability())}
            for={@form}
            id="assets-reverse-form"
            phx-submit="reverse"
          >
            <.input field={@form[:run_id]} type="number" label="Run ID" required />
            <.input
              field={@form[:effective_date]}
              type="date"
              label="Reversal date in an open period"
              required
            />
            <.input field={@form[:reason]} label="Reason" required />
            <.button id="assets-reverse" type="submit">Post reversal</.button>
          </.form>
          <.empty_state
            :if={!LiveAuthorization.allowed_now?(@current_scope, FixedAssets.reverse_capability())}
            id="assets-reverse-withheld"
            title="Reversals unavailable"
            reason="Ask your company administrator for asset reversal permission."
          />
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
