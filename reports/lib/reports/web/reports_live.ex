defmodule Bilimbi.Finance.Reports.Web.ReportsLive do
  @moduledoc """
  The company's financial reports: headline figures, profit and loss, the
  balance sheet and the cash position, for one period against the period
  before it.

  The page reads through the `Bilimbi.Finance.Reports` facade and subscribes
  to the company's postings, so figures read again as soon as an entry's
  transaction commits. A report pinned to an entry number (the `through`
  parameter) stays as it is: its figures cannot change, which is what makes
  the address a reproducible reference.
  """

  use Bilimbi.Base.UI, :live_view

  import Bilimbi.Finance.Reports.Web.Figures

  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Base.UI.PeriodFilter
  alias Bilimbi.Finance.Reports

  @views ~w(overview profit-and-loss balance-sheet cash-position)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Financial reports")
      |> assign(:active_nav, "finance.reports")
      |> assign(:browser_timezone, nil)

    if connected?(socket), do: Reports.subscribe(scope(socket), company_id(socket))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    clock =
      PeriodFilter.clock(
        socket.assigns.current_scope.shell_preferences,
        socket.assigns.browser_timezone
      )

    view = if params["view"] in @views, do: params["view"], else: "overview"
    compare? = params["compare"] != "none"

    state = %{
      view: view,
      clock: clock,
      period: PeriodFilter.parse(Map.put_new(params, "period", "this_month"), clock.today),
      compare?: compare?,
      pinned: Params.positive_integer(params["through"])
    }

    {:noreply,
     socket
     |> assign(:params, params)
     |> assign(state)
     |> assign(:state, state)
     |> assign(:compare_form, to_form(%{"compare" => compare?}, as: :report))
     |> load()}
  end

  @impl true
  def handle_event("browser_timezone", %{"timezone" => timezone}, socket) do
    handle_params(socket.assigns.params, nil, assign(socket, :browser_timezone, timezone))
  end

  def handle_event("compare", params, socket) do
    compare = if get_in(params, ["report", "compare"]) == "true", do: nil, else: "none"
    {:noreply, push_patch(socket, to: report_path(socket.assigns.state, compare: compare))}
  end

  # A pinned report cannot change, so it ignores postings. Notices already
  # waiting are taken with this one, so a burst of postings reads once.
  @impl true
  def handle_info({:finance_ledger_posted, _notice}, socket) do
    drain_notices()
    if socket.assigns.pinned, do: {:noreply, socket}, else: {:noreply, load(socket)}
  end

  defp drain_notices do
    receive do
      {:finance_ledger_posted, _notice} -> drain_notices()
    after
      0 -> :ok
    end
  end

  defp load(socket) do
    %{view: view, period: period, compare?: compare?, pinned: pinned} = socket.assigns
    current = {period.from, period.to}
    previous = Reports.previous_period(current)
    options = if pinned, do: [through_entry_number: pinned], else: []
    scope = scope(socket)
    company_id = company_id(socket)

    result =
      case view do
        "overview" ->
          Reports.overview(scope, company_id, current, options)

        "profit-and-loss" ->
          Reports.profit_and_loss(
            scope,
            company_id,
            columns(current, previous, compare?),
            options
          )

        "balance-sheet" ->
          dates = columns(period.to, elem(previous, 1), compare?)
          Reports.balance_sheet(scope, company_id, dates, options)

        "cash-position" ->
          dates = columns(period.to, elem(previous, 1), compare?)
          Reports.cash_position(scope, company_id, dates, options)
      end

    case result do
      {:ok, report} -> socket |> assign(:report, report) |> assign(:refusal, nil)
      {:error, reason} -> socket |> assign(:report, nil) |> assign(:refusal, reason)
    end
  end

  defp columns(current, previous, true), do: [current, previous]
  defp columns(current, _previous, false), do: [current]

  ## Paths

  defp report_path(state, changes) do
    query =
      %{
        "view" => state.view,
        "compare" => if(state.compare?, do: nil, else: "none"),
        "through" => state.pinned
      }
      |> Map.merge(PeriodFilter.params(state.period))
      |> Map.merge(Map.new(changes, fn {key, value} -> {to_string(key), value} end))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/finance/reports?#{query}"
  end

  defp period_path(state, params),
    do: report_path(state, PeriodFilter.params(PeriodFilter.parse(params, state.clock.today)))

  defp drill_path(report, row, column) do
    window =
      case column do
        %{from: from, to: to} ->
          %{"from" => Date.to_iso8601(from), "to" => Date.to_iso8601(to), "closing" => "excluded"}

        %{as_of: as_of} ->
          %{"to" => Date.to_iso8601(as_of)}
      end

    query = Map.put(window, "through", report.through_entry_number)
    ~p"/finance/reports/accounts/#{row.account_id}?#{query}"
  end

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:detail}>
        <.header>
          Financial reports
          <:subtitle :if={@report}>
            <span id="report-currency">{@report.currency_code}</span>
            · <span id="report-through">through entry {@report.through_entry_number}</span>
            <span :if={@pinned}> · pinned</span>
          </:subtitle>
          <:actions :if={@report}>
            <.button
              :if={is_nil(@pinned)}
              id="pin-report"
              patch={report_path(@state, through: @report.through_entry_number)}
            >
              Pin these figures
            </.button>
            <.button :if={@pinned} id="unpin-report" patch={report_path(@state, through: nil)}>
              Show latest figures
            </.button>
          </:actions>
        </.header>

        <.tabs id="report-views" aria-label="Reports">
          <:tab patch={report_path(@state, view: "overview")} current={@view == "overview"}>
            Overview
          </:tab>
          <:tab
            patch={report_path(@state, view: "profit-and-loss")}
            current={@view == "profit-and-loss"}
          >
            Profit and loss
          </:tab>
          <:tab patch={report_path(@state, view: "balance-sheet")} current={@view == "balance-sheet"}>
            Balance sheet
          </:tab>
          <:tab patch={report_path(@state, view: "cash-position")} current={@view == "cash-position"}>
            Cash position
          </:tab>
        </.tabs>

        <div
          id="report-period-region"
          phx-hook="BrowserTimeZone"
          class="mt-3 mb-3 flex flex-wrap items-center gap-4"
        >
          <.period_filter
            id="report-period"
            clock={@clock}
            state={@period}
            current_scope={@current_scope}
            path={&period_path(@state, &1)}
          />
          <.form
            :if={@view != "overview"}
            for={@compare_form}
            id="report-compare"
            phx-change="compare"
            phx-submit="compare"
          >
            <.input
              type="checkbox"
              field={@compare_form[:compare]}
              id="report-compare-input"
              label="Compare with the previous period"
            />
          </.form>
        </div>

        <.refusal :if={@refusal} reason={@refusal} />

        <.overview :if={@report && @view == "overview"} report={@report} state={@state} />

        <.alert
          :if={@report && @report[:unmatched_codes] not in [nil, []]}
          kind={:warning}
          class="mb-3"
        >
          The report sections name account codes the chart does not have: {Enum.join(
            @report.unmatched_codes,
            ", "
          )}.
        </.alert>

        <.card :if={@report && @view == "profit-and-loss"} id="profit-and-loss-card" inner_class="p-0">
          <.statement
            :if={statement_rows?(@report.groups)}
            id="profit-and-loss"
            columns={@report.columns}
            minor_units={@report.minor_units}
            groups={type_groups(@report.groups)}
            footer={[{"net-income", "Net income", @report.net_income}]}
            drill={&drill_path(@report, &1, &2)}
          />
          <.empty_state
            :if={!statement_rows?(@report.groups)}
            title="No income or expenses"
            reason="No entry in these periods posts to an income or expense account."
          />
        </.card>

        <.card :if={@report && @view == "balance-sheet"} id="balance-sheet-card" inner_class="p-0">
          <.statement
            id="balance-sheet"
            columns={@report.columns}
            minor_units={@report.minor_units}
            groups={balance_sheet_groups(@report)}
            footer={[
              {"total-liabilities-and-equity", "Total liabilities and equity",
               @report.total_liabilities_and_equity}
            ]}
            drill={&drill_path(@report, &1, &2)}
          />
        </.card>

        <.card :if={@report && @view == "cash-position"} id="cash-position-card" inner_class="p-0">
          <.statement
            :if={@report.sections != []}
            id="cash-position"
            columns={@report.columns}
            minor_units={@report.minor_units}
            groups={[
              %{
                id: "cash",
                label: nil,
                sections: @report.sections,
                extras: [],
                total_label: "Total cash",
                totals: @report.totals
              }
            ]}
            drill={&drill_path(@report, &1, &2)}
          />
          <.empty_state
            :if={@report.sections == []}
            title="No cash accounts configured"
            reason="Name the cash and bank accounts in a cash position section of the Report sections setting."
          />
        </.card>
      </.page>
    </Layouts.app>
    """
  end

  attr(:report, :map, required: true)
  attr(:state, :map, required: true)

  defp overview(assigns) do
    [current, previous] = assigns.report.columns
    minor_units = assigns.report.minor_units

    figures =
      for {id, label, values} <- [
            {"income", "Income", assigns.report.income},
            {"expense", "Expenses", assigns.report.expense},
            {"net-income", "Net income", assigns.report.net_income},
            {"assets", "Assets", assigns.report.assets},
            {"liabilities", "Liabilities", assigns.report.liabilities},
            {"equity", "Equity", assigns.report.equity},
            {"cash", "Cash", assigns.report.cash}
          ] do
        [now, before] = values

        %{
          id: id,
          label: label,
          now: amount(now, minor_units),
          before: amount(before, minor_units),
          change: amount(Decimal.sub(now, before), minor_units)
        }
      end

    assigns =
      assign(assigns,
        figures: figures,
        value: Map.new(figures, &{&1.id, &1.now}),
        current_label: column_label(current),
        previous_label: column_label(previous)
      )

    ~H"""
    <div id="overview" class="grid gap-3 md:grid-cols-3">
      <.stat_strip
        id="overview-profit-and-loss"
        title="Profit and loss"
        navigate={report_path(@state, view: "profit-and-loss")}
      >
        <:item label="Income" value={@value["income"]} />
        <:item label="Expenses" value={@value["expense"]} />
        <:item label="Net income" value={@value["net-income"]} />
      </.stat_strip>
      <.stat_strip
        id="overview-position"
        title="Financial position"
        navigate={report_path(@state, view: "balance-sheet")}
      >
        <:item label="Assets" value={@value["assets"]} />
        <:item label="Liabilities" value={@value["liabilities"]} />
        <:item label="Equity" value={@value["equity"]} />
      </.stat_strip>
      <.stat_strip
        id="overview-cash"
        title="Cash position"
        navigate={report_path(@state, view: "cash-position")}
      >
        <:item label="Cash" value={@value["cash"]} />
      </.stat_strip>
    </div>
    <.card id="overview-comparison" class="mt-4" inner_class="p-0">
      <.table
        id="overview-figures"
        rows={@figures}
        row_id={&"overview-figure-#{&1.id}"}
        caption="Headline figures against the previous period"
        framed={false}
      >
        <:col :let={figure} label="Figure">{figure.label}</:col>
        <:col :let={figure} label={@current_label} align={:right}>
          <span class="tabular-nums">{figure.now}</span>
        </:col>
        <:col :let={figure} label={@previous_label} align={:right}>
          <span class="tabular-nums">{figure.before}</span>
        </:col>
        <:col :let={figure} label="Change" align={:right}>
          <span class="tabular-nums">{figure.change}</span>
        </:col>
      </.table>
    </.card>
    """
  end

  attr(:reason, :atom, required: true)

  defp refusal(%{reason: :book_not_open} = assigns) do
    ~H"""
    <.empty_state
      id="report-refusal"
      title="The ledger is not open"
      reason="Reports read the company's book, which has not been opened yet."
    />
    """
  end

  defp refusal(%{reason: :unauthorized} = assigns) do
    ~H"""
    <.empty_state id="report-refusal" forbidden="view the ledger" />
    """
  end

  defp refusal(assigns) do
    ~H"""
    <.empty_state
      id="report-refusal"
      title="These figures cannot be shown"
      reason="The company or the report options could not be read. Choose another period or reload the page."
    />
    """
  end

  defp statement_rows?(groups), do: Enum.any?(groups, &(&1.sections != []))

  defp type_groups(groups) do
    Enum.map(groups, fn group ->
      %{
        id: group.account_type,
        label: type_label(group.account_type),
        sections: group.sections,
        extras: [],
        total_label: "Total #{String.downcase(type_label(group.account_type))}",
        totals: group.totals
      }
    end)
  end

  defp balance_sheet_groups(report) do
    Enum.map(type_groups(report.groups), fn
      %{id: "equity"} = equity ->
        %{
          equity
          | extras: [{"earnings", "Income less expenses not yet closed", report.earnings}]
        }

      group ->
        group
    end)
  end
end
