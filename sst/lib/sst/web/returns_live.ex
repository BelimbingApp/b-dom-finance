defmodule Bilimbi.Finance.Sst.Web.ReturnsLive do
  @moduledoc """
  The company's SST returns: the recent taxable periods of its
  registration with each registered tax's return for the period (open,
  finalised with its version, or none yet, with a control that prepares
  it), a form that prepares the return of any period, and every return on
  record. Preparing is a facade call that re-asks its capability.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Sst
  alias Bilimbi.Finance.Sst.Web.Format

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope.scope

    {:ok,
     socket
     |> assign(:page_title, "SST returns")
     |> assign(:active_nav, "finance.sst")
     |> assign(:company_id, Scope.actor(scope).company_id)
     |> assign(
       :prepare_form,
       to_form(%{"tax_type" => "sales_tax", "period_start" => ""}, as: :prepare)
     )
     |> load()}
  end

  defp load(socket) do
    %{current_scope: %{scope: scope} = current_scope, company_id: company_id} = socket.assigns

    with {:ok, registration} <- Sst.get_registration(scope, company_id),
         {:ok, periods} <- Sst.taxable_periods(scope, company_id, count: 6),
         {:ok, returns} <- Sst.list_returns(scope, company_id, limit: 500) do
      socket
      |> assign(:registration, registration)
      |> assign(:periods, periods)
      |> assign(:returns, Enum.reverse(returns))
      |> assign(:by_period, by_period(returns))
      |> assign(:tax_types, registered(registration))
      |> assign(:refusal, nil)
      |> assign(
        :can_prepare?,
        LiveAuthorization.allowed_now?(current_scope, Sst.prepare_returns_capability())
      )
    else
      {:error, reason} ->
        socket
        |> assign(:registration, nil)
        |> assign(:returns, nil)
        |> assign(:refusal, reason)
        |> assign(:can_prepare?, false)
    end
  end

  defp registered(nil), do: []

  defp registered(registration) do
    for {tax_type, number} <- [
          {"sales_tax", registration.sales_tax_number},
          {"service_tax", registration.service_tax_number}
        ],
        number,
        do: tax_type
  end

  # The return that stands for each tax and period: an open one, else the
  # latest finalised version; discarded returns stay in the list below.
  defp by_period(returns) do
    returns
    |> Enum.reject(&(&1.status == "discarded"))
    |> Enum.group_by(&{&1.tax_type, &1.period_start})
    |> Map.new(fn {key, group} ->
      {key,
       Enum.find(group, &(&1.status == "open")) ||
         Enum.max_by(group, & &1.version)}
    end)
  end

  @impl true
  def handle_event("prepare", params, socket) do
    attributes =
      case params do
        %{"prepare" => form} -> form
        %{"tax_type" => _, "period_start" => _} -> params
      end

    case LiveAuthorization.authorize_event(socket, Sst.prepare_returns_capability()) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        case Sst.open_return(socket.assigns.current_scope.scope, socket.assigns.company_id, %{
               tax_type: attributes["tax_type"],
               period_start: attributes["period_start"]
             }) do
          {:ok, tax_return} ->
            {:noreply,
             socket
             |> put_flash(:success, "Return #{tax_return.return_number} opened.")
             |> push_navigate(to: ~p"/finance/sst/returns/#{tax_return.id}")}

          {:error, reason} ->
            {:noreply, socket |> put_flash(:error, Format.refusal(reason)) |> load()}
        end
    end
  end

  def handle_event("prepare_change", %{"prepare" => params}, socket),
    do: {:noreply, assign(socket, :prepare_form, to_form(params, as: :prepare))}

  defp status_kind("open"), do: :warning
  defp status_kind("finalised"), do: :success
  defp status_kind("discarded"), do: :neutral

  defp status_label(%{status: "finalised", version: version, superseded_by_return_id: nil}),
    do: "finalised v#{version}"

  defp status_label(%{status: "finalised", version: version}),
    do: "finalised v#{version}, amended"

  defp status_label(%{status: status}), do: status

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="sst-returns">
        <.header>
          SST returns
          <:subtitle>
            SST-02 returns for each taxable period, computed from posted documents and reconciled with the tax accounts.
          </:subtitle>
          <:actions>
            <.link id="sst-returns-setup" navigate={~p"/finance/sst/setup"}>SST setup</.link>
          </:actions>
        </.header>

        <.empty_state
          :if={@refusal}
          id="sst-returns-refusal"
          title="SST returns unavailable"
          reason={Format.refusal(@refusal)}
        />

        <.empty_state
          :if={is_nil(@refusal) and is_nil(@registration)}
          id="sst-returns-unregistered"
          title="Not registered yet"
          reason="Record the company's SST registration in SST setup to prepare returns."
        />

        <.card
          :if={@registration}
          id="sst-periods"
          inner_class="p-0"
          role="region"
          aria-labelledby="sst-periods-heading"
        >
          <.section_heading id="sst-periods-heading" title="Taxable periods" class="p-5 pb-0">
            <:description>
              {@registration.period_months}-month periods; a return is due by the date shown (moved to the next working day when it falls on a weekend or holiday).
            </:description>
          </.section_heading>
          <.table
            id="sst-periods-table"
            rows={@periods}
            framed={false}
            row_id={&"period-#{&1.period_start}"}
          >
            <:col :let={period} label="Period">{period.period_start} to {period.period_end}</:col>
            <:col :let={period} label="Due">{period.due_date}</:col>
            <:col :let={period} :for={tax_type <- @tax_types} label={Format.tax_name(tax_type)}>
              <%= case Map.get(@by_period, {tax_type, period.period_start}) do %>
                <% nil -> %>
                  <.button
                    :if={@can_prepare?}
                    id={"prepare-#{tax_type}-#{period.period_start}"}
                    phx-click="prepare"
                    phx-value-tax_type={tax_type}
                    phx-value-period_start={period.period_start}
                  >
                    Prepare
                  </.button>
                  <span :if={!@can_prepare?} class="text-ink-muted">none</span>
                <% tax_return -> %>
                  <.link
                    id={"period-#{tax_type}-#{period.period_start}-return"}
                    navigate={~p"/finance/sst/returns/#{tax_return.id}"}
                  >
                    Return {tax_return.return_number}
                  </.link>
                  <.badge kind={status_kind(tax_return.status)} class="ml-1">
                    {status_label(tax_return)}
                  </.badge>
              <% end %>
            </:col>
          </.table>

          <.empty_state
            :if={!@can_prepare?}
            id="sst-prepare-forbidden"
            forbidden="prepare SST returns"
            class="p-5"
          />

          <.form
            :if={@can_prepare?}
            for={@prepare_form}
            id="sst-prepare-form"
            phx-change="prepare_change"
            phx-submit="prepare"
            class="grid gap-x-6 gap-y-2 p-5 md:grid-cols-3"
          >
            <.input
              field={@prepare_form[:tax_type]}
              id="prepare-tax-type"
              type="select"
              label="Tax"
              options={Enum.map(@tax_types, &{Format.tax_name(&1), &1})}
            />
            <.input
              field={@prepare_form[:period_start]}
              id="prepare-period-start"
              type="date"
              label="Period starts"
              required
            />
            <div class="flex items-end pb-4">
              <.button type="submit" id="prepare-submit" variant="primary">Prepare return</.button>
            </div>
          </.form>
        </.card>

        <.card
          :if={@returns}
          id="sst-returns-list"
          inner_class="p-0"
          role="region"
          aria-labelledby="sst-returns-list-heading"
        >
          <.section_heading
            id="sst-returns-list-heading"
            title="Returns on record"
            count={length(@returns)}
            class="p-5 pb-0"
          />
          <.table
            id="sst-returns-table"
            rows={@returns}
            framed={false}
            row_id={&"return-#{&1.return_number}"}
          >
            <:col :let={r} label="No.">
              <.link navigate={~p"/finance/sst/returns/#{r.id}"} class="font-medium hover:underline">
                {r.return_number}
              </.link>
            </:col>
            <:col :let={r} label="Tax">{Format.tax_name(r.tax_type)}</:col>
            <:col :let={r} label="Period">{r.period_start} to {r.period_end}</:col>
            <:col :let={r} label="Status">
              <.badge kind={status_kind(r.status)}>{status_label(r)}</.badge>
              <span :if={r.amends_return_id} class="ml-1 text-xs text-ink-muted">amendment</span>
            </:col>
            <:col :let={r} label="Due">{r.due_date}</:col>
            <:col :let={r} label="Tax payable" align={:right}>
              <span class="tabular-nums">{Format.money(r.tax_payable, r.minor_units)}</span>
            </:col>
            <:empty title="No returns yet" reason="Prepare the first return from its taxable period." />
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
