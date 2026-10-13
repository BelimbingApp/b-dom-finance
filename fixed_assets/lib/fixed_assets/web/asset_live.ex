defmodule Bilimbi.Finance.FixedAssets.Web.AssetLive do
  @moduledoc false
  use Bilimbi.Base.UI, :live_view
  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.UI.{Params, Workspace}
  alias Bilimbi.Finance.FixedAssets
  alias Bilimbi.Finance.FixedAssets.Web.{Feedback, ListPage}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Asset")
     |> assign(:active_nav, "finance.fixed-assets.register")
     |> assign(:company_id, Scope.actor(socket.assigns.current_scope.scope).company_id)
     |> assign(:form, to_form(%{}, as: "asset"))}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, load(assign(socket, :asset_id, Params.positive_integer(id)))}
  end

  @impl true
  def handle_event("dispose", %{"asset" => attrs}, socket) do
    case LiveAuthorization.authorize_event(socket, FixedAssets.dispose_capability()) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        complete(
          socket,
          FixedAssets.dispose(
            socket.assigns.current_scope.scope,
            socket.assigns.company_id,
            socket.assigns.asset_id,
            attrs
          ),
          attrs
        )
    end
  end

  def handle_event("reverse", %{"asset" => attrs}, socket) do
    case LiveAuthorization.authorize_event(socket, FixedAssets.reverse_capability()) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        complete(
          socket,
          FixedAssets.reverse_disposal(
            socket.assigns.current_scope.scope,
            socket.assigns.company_id,
            socket.assigns.asset_id,
            attrs
          ),
          attrs
        )
    end
  end

  defp complete(socket, {:ok, _}, _attrs),
    do: {:noreply, socket |> put_flash(:success, "Recorded in the ledger.") |> load()}

  defp complete(socket, {:error, reason}, attrs),
    do:
      {:noreply,
       socket
       |> put_flash(:error, Feedback.message(reason))
       |> assign(:form, to_form(attrs, as: "asset"))}

  defp load(socket) do
    case FixedAssets.get_asset(
           socket.assigns.current_scope.scope,
           socket.assigns.company_id,
           socket.assigns.asset_id
         ) do
      {:ok, detail} ->
        socket
        |> assign(:detail, detail)
        |> assign(:read_error, nil)
        |> Workspace.announce(%{kind: "finance/fixed_assets", id: detail.asset.id})

      {:error, reason} ->
        socket |> assign(:detail, nil) |> assign(:read_error, Feedback.message(reason))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="asset-detail">
        <.header>
          Asset<:actions>
            <.link navigate={~p"/finance/fixed-assets/register"}>Register</.link>
          </:actions>
        </.header>
        <.empty_state
          :if={@read_error}
          id="asset-unavailable"
          title="Asset unavailable"
          reason={@read_error}
        />
        <div :if={@detail}>
          <.card>
            <h2 class="font-medium">#{@detail.asset.asset_number} {@detail.asset.description}</h2>
            <p>
              Cost {ListPage.money(@detail.asset.cost)}; residual {ListPage.money(
                @detail.asset.residual_value
              )}.
            </p>
            <p>
              Acquired {@detail.asset.acquisition_date}; in service {@detail.asset.in_service_date}.
            </p>
            <p>
              {@detail.asset.method}; {@detail.asset.life_months} months. Category revision {@detail.revision.id}.
            </p>
            <p>
              Acquisition entry {@detail.asset.entry_number}, line {@detail.asset.entry_line_number}.
            </p>
            <p>
              Recorded by user {@detail.asset.recorded_by_user_id}<span :if={
                @detail.asset.recorded_by_impersonator_id
              }> (impersonated by {@detail.asset.recorded_by_impersonator_id})</span>
              at <.datetime id="asset-recorded-at" value={@detail.asset.recorded_at} />.
            </p>
          </.card>
          <.table id="asset-schedule" rows={@detail.schedule}>
            <:col :let={r} label="Month">{r.period}</:col>
            <:col :let={r} label="Scheduled depreciation">{ListPage.money(r.amount)}</:col>
            <:col :let={r} label="Accumulated">{ListPage.money(r.accumulated)}</:col>
            <:col :let={r} label="Carrying value">{ListPage.money(r.carrying_value)}</:col>
          </.table>
          <p>
            This projected book schedule assumes continued use. Recorded charges and reversals appear in depreciation runs.
          </p>
          <.table id="asset-charges" rows={@detail.charges}>
            <:col :let={r} label="Run">{r.run_id}</:col>
            <:col :let={r} label="Month">{r.period}</:col>
            <:col :let={r} label="Posted depreciation">{ListPage.money(r.amount)}</:col>
            <:col :let={r} label="Entry">{r.entry_number}</:col>
            <:col :let={r} label="Actor">
              {r.recorded_by_user_id}<span :if={r.recorded_by_impersonator_id}> (impersonated by {r.recorded_by_impersonator_id})</span>
            </:col>
            <:col :let={r} label="Recorded">
              <.datetime id={"asset-charge-#{r.run_id}-at"} value={r.recorded_at} />
            </:col>
            <:col :let={r} label="Reversal">
              {if r.reversal,
                do:
                  "Entry #{r.reversal.entry_number} on #{r.reversal.effective_date}: #{r.reversal.reason}",
                else: "—"}
            </:col>
            <:empty>No depreciation charges posted.</:empty>
          </.table>
          <.table id="asset-events" rows={@detail.events}>
            <:col :let={e} label="Event">{e.action}</:col>
            <:col :let={e} label="Effective">{e.effective_date}</:col>
            <:col :let={e} label="Reason">{e.reason}</:col>
            <:col :let={e} label="Actor">{e.recorded_by_user_id}</:col>
            <:col :let={e} label="Recorded">
              <.datetime id={"asset-event-#{e.id}-at"} value={e.recorded_at} />
            </:col>
            <:empty>No disposal events.</:empty>
          </.table>
          <.card class="mt-4">
            <h2 class="font-medium">Sale or write-off</h2>
            <.form
              :if={LiveAuthorization.allowed_now?(@current_scope, FixedAssets.dispose_capability())}
              for={@form}
              id="asset-dispose-form"
              phx-submit="dispose"
            >
              <.input field={@form[:effective_date]} type="date" label="Disposal date" required />
              <.input field={@form[:proceeds]} label="Proceeds (zero for a write-off)" required />
              <.input
                field={@form[:settlement_account_id]}
                type="number"
                label="Proceeds account ID (for a sale)"
              />
              <.input field={@form[:reason]} label="Reason" required />
              <.button id="asset-dispose" type="submit">Post disposal</.button>
            </.form>
            <.empty_state
              :if={!LiveAuthorization.allowed_now?(@current_scope, FixedAssets.dispose_capability())}
              id="asset-dispose-withheld"
              title="Disposal unavailable"
              reason="Ask your company administrator for asset disposal permission."
            />
          </.card>
          <.card class="mt-4">
            <h2 class="font-medium">Reverse disposal</h2>
            <.form
              :if={LiveAuthorization.allowed_now?(@current_scope, FixedAssets.reverse_capability())}
              for={@form}
              id="asset-reverse-form"
              phx-submit="reverse"
            >
              <.input
                id="asset-reversal-date"
                field={@form[:effective_date]}
                type="date"
                label="Reversal date"
                required
              />
              <.input id="asset-reversal-reason" field={@form[:reason]} label="Reason" required />
              <.button id="asset-reverse" type="submit">Post reversal</.button>
            </.form>
            <.empty_state
              :if={!LiveAuthorization.allowed_now?(@current_scope, FixedAssets.reverse_capability())}
              id="asset-reverse-withheld"
              title="Reversal unavailable"
              reason="Ask your company administrator for asset reversal permission."
            />
          </.card>
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
