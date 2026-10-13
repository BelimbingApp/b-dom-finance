defmodule Bilimbi.Finance.Payroll.Web.SetupLive do
  @moduledoc """
  The company's payroll posting accounts: the liability accounts net pay
  and approved claims are owed on, and the mapping of each payroll
  component and claim category to its accounts, with the history of every
  change. Every write is a facade call that re-asks its capability.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Payroll
  alias Bilimbi.Finance.Payroll.Web.Format

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope.scope

    {:ok,
     socket
     |> assign(:page_title, "Payroll posting accounts")
     |> assign(:active_nav, "finance.payroll")
     |> assign(:company_id, Scope.actor(scope).company_id)
     |> assign(:settings_form, nil)
     |> assign(:mapping_form, blank_mapping_form())
     |> load()}
  end

  defp load(socket) do
    %{current_scope: %{scope: scope}, company_id: company_id} = socket.assigns

    settings =
      case Payroll.get_settings(scope, company_id) do
        {:ok, settings} -> settings
        {:error, :payroll_not_configured} -> %{}
        {:error, _reason} -> nil
      end

    chart =
      case Ledger.list_accounts(scope, company_id) do
        {:ok, chart} -> chart
        {:error, _reason} -> nil
      end

    socket
    |> assign(:settings, settings)
    |> assign(:settings_form, socket.assigns.settings_form || settings_form(settings))
    |> assign(:mappings, read(Payroll.list_mappings(scope, company_id)))
    |> assign(:settings_changes, read(Payroll.list_settings_changes(scope, company_id)))
    |> assign(:mapping_changes, read(Payroll.list_mapping_changes(scope, company_id)))
    |> assign(:chart, chart)
    |> assign(:chart_by_id, Map.new(chart || [], &{&1.id, &1}))
    |> assign(
      :can_manage?,
      LiveAuthorization.allowed_now?(
        socket.assigns.current_scope,
        Payroll.manage_settings_capability()
      )
    )
  end

  defp read({:ok, rows}), do: rows
  defp read({:error, _reason}), do: []

  defp settings_form(settings) do
    to_form(
      %{
        "net_pay_account_id" => to_string(Map.get(settings || %{}, :net_pay_account_id, "")),
        "claims_payable_account_id" =>
          to_string(Map.get(settings || %{}, :claims_payable_account_id, "")),
        "reason" => ""
      },
      as: :settings
    )
  end

  defp blank_mapping_form do
    to_form(
      %{
        "kind" => "component",
        "code" => "",
        "direction" => "earning",
        "expense_account_id" => "",
        "liability_account_id" => "",
        "reason" => ""
      },
      as: :mapping
    )
  end

  @impl true
  def handle_event("change_settings", %{"settings" => params}, socket),
    do: {:noreply, assign(socket, :settings_form, to_form(params, as: :settings))}

  def handle_event("save_settings", %{"settings" => params}, socket) do
    with_capability(socket, fn socket ->
      %{current_scope: %{scope: scope}, company_id: company_id} = socket.assigns

      case Payroll.put_settings(scope, company_id, %{
             net_pay_account_id: integer(params["net_pay_account_id"]),
             claims_payable_account_id: integer(params["claims_payable_account_id"]),
             reason: params["reason"]
           }) do
        {:ok, _settings} ->
          socket
          |> put_flash(:success, "Posting accounts saved.")
          |> assign(:settings_form, nil)
          |> load()

        {:error, %Ecto.Changeset{} = changeset} ->
          socket
          |> put_flash(:error, Format.refusal(changeset))
          |> assign(:settings_form, to_form(params, as: :settings, errors: errors(changeset)))

        {:error, reason} ->
          socket |> put_flash(:error, Format.refusal(reason)) |> load()
      end
    end)
  end

  def handle_event("change_mapping", %{"mapping" => params}, socket),
    do: {:noreply, assign(socket, :mapping_form, to_form(params, as: :mapping))}

  def handle_event("edit_mapping", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.mappings, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      mapping ->
        form =
          to_form(
            %{
              "kind" => mapping.kind,
              "code" => mapping.code,
              "direction" => mapping.direction,
              "expense_account_id" => to_string(mapping.expense_account_id || ""),
              "liability_account_id" => to_string(mapping.liability_account_id || ""),
              "reason" => ""
            },
            as: :mapping
          )

        {:noreply, assign(socket, :mapping_form, form)}
    end
  end

  def handle_event("save_mapping", %{"mapping" => params}, socket) do
    with_capability(socket, fn socket ->
      %{current_scope: %{scope: scope}, company_id: company_id} = socket.assigns

      direction =
        if params["kind"] == "claim_category",
          do: "claim",
          else: params["direction"]

      case Payroll.put_mapping(scope, company_id, %{
             kind: params["kind"],
             code: params["code"],
             direction: direction,
             expense_account_id: integer(params["expense_account_id"]),
             liability_account_id: integer(params["liability_account_id"]),
             reason: params["reason"]
           }) do
        {:ok, mapping} ->
          socket
          |> put_flash(:success, "Mapping #{mapping.code} (#{mapping.direction}) saved.")
          |> assign(:mapping_form, blank_mapping_form())
          |> load()

        {:error, %Ecto.Changeset{} = changeset} ->
          socket
          |> put_flash(:error, Format.refusal(changeset))
          |> assign(:mapping_form, to_form(params, as: :mapping, errors: errors(changeset)))

        {:error, reason} ->
          socket |> put_flash(:error, Format.refusal(reason)) |> load()
      end
    end)
  end

  # A refusal re-derives the cached assign the forms render from.
  defp with_capability(socket, fun) do
    case LiveAuthorization.authorize_event(socket, Payroll.manage_settings_capability()) do
      {:denied, socket} -> {:noreply, assign(socket, :can_manage?, false)}
      {:ok, socket} -> {:noreply, fun.(socket)}
    end
  end

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp integer(_value), do: nil

  defp errors(changeset) do
    Enum.map(changeset.errors, fn {field, {message, options}} ->
      {field, {message, options}}
    end)
  end

  defp chart_options(nil, _types), do: []

  defp chart_options(chart, types) do
    for account <- chart, account.account_type in types, account.active do
      {"#{account.code} #{account.name}", account.id}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="payroll-setup">
        <.header>
          Payroll posting accounts
          <:subtitle>
            Where net pay and approved claims are owed, and which accounts each payroll component and claim category posts to.
          </:subtitle>
          <:actions>
            <.link id="payroll-setup-postings" navigate={~p"/finance/payroll"}>
              Payroll and claims
            </.link>
          </:actions>
        </.header>

        <.empty_state
          :if={is_nil(@settings)}
          id="payroll-setup-forbidden"
          forbidden="view payroll posting accounts"
        />

        <.card
          :if={@settings}
          id="payroll-settings"
          role="region"
          aria-labelledby="payroll-settings-heading"
        >
          <.section_heading id="payroll-settings-heading" title="Owed to staff">
            <:description>
              Liability accounts: a run's net pay is credited to the first, an approved claim to the second, until they are paid.
            </:description>
          </.section_heading>

          <dl :if={@settings != %{}} id="payroll-settings-current" class="mt-4 grid gap-2 text-sm md:grid-cols-2">
            <div>
              <dt class="font-medium text-ink">Net pay</dt>
              <dd id="payroll-settings-net-pay">
                {Format.account(@chart_by_id, @settings.net_pay_account_id)}
              </dd>
            </div>
            <div>
              <dt class="font-medium text-ink">Claims payable</dt>
              <dd id="payroll-settings-claims-payable">
                {Format.account(@chart_by_id, @settings.claims_payable_account_id)}
              </dd>
            </div>
          </dl>

          <.empty_state
            :if={not @can_manage?}
            id="payroll-settings-manage-forbidden"
            forbidden="change payroll posting accounts"
            class="mt-4"
          />

          <.form
            :if={@can_manage?}
            for={@settings_form}
            id="payroll-settings-form"
            phx-change="change_settings"
            phx-submit="save_settings"
            class="mt-4 grid gap-x-6 gap-y-2 md:grid-cols-2"
          >
            <.input
              field={@settings_form[:net_pay_account_id]}
              id="payroll-settings-net-pay-account"
              type="select"
              label="Net pay account (liability)"
              prompt="Choose an account"
              options={chart_options(@chart, ["liability"])}
              required
            />
            <.input
              field={@settings_form[:claims_payable_account_id]}
              id="payroll-settings-claims-payable-account"
              type="select"
              label="Claims payable account (liability)"
              prompt="Choose an account"
              options={chart_options(@chart, ["liability"])}
              required
            />
            <.input
              field={@settings_form[:reason]}
              id="payroll-settings-reason"
              label="Reason for the change"
              maxlength="500"
              wrapper_class="md:col-span-2 mb-4"
            />
            <div class="md:col-span-2">
              <.button type="submit" id="payroll-settings-save" variant="primary">
                Save posting accounts
              </.button>
            </div>
          </.form>
        </.card>

        <.card
          :if={@settings}
          id="payroll-mappings"
          inner_class="p-0"
          role="region"
          aria-labelledby="payroll-mappings-heading"
        >
          <.section_heading
            id="payroll-mappings-heading"
            title="Account mappings"
            count={length(@mappings)}
            class="p-5 pb-0"
          >
            <:description>
              A payroll component is a pay item code with the direction of its lines; a claim category is its code.
            </:description>
          </.section_heading>
          <.table
            id="payroll-mappings-table"
            rows={@mappings}
            framed={false}
            row_id={&"payroll-mapping-#{&1.id}"}
          >
            <:col :let={mapping} label="Kind">{Format.mapping_kind(mapping.kind)}</:col>
            <:col :let={mapping} label="Code">{mapping.code}</:col>
            <:col :let={mapping} label="Direction">{mapping.direction}</:col>
            <:col :let={mapping} label="Expense account">
              {Format.account(@chart_by_id, mapping.expense_account_id)}
            </:col>
            <:col :let={mapping} label="Liability account">
              {Format.account(@chart_by_id, mapping.liability_account_id)}
            </:col>
            <:col :let={mapping} label="">
              <.button
                :if={@can_manage?}
                id={"payroll-mapping-edit-#{mapping.id}"}
                phx-click="edit_mapping"
                phx-value-id={mapping.id}
              >
                Change
              </.button>
            </:col>
            <:empty>No mappings yet: a run or claim cannot post until its components are mapped.</:empty>
          </.table>
        </.card>

        <.card
          :if={@settings && @can_manage?}
          id="payroll-mapping-editor"
          role="region"
          aria-labelledby="payroll-mapping-form-heading"
        >
          <.section_heading id="payroll-mapping-form-heading" title="Add or change a mapping">
            <:description>
              An earning or a claim category names the expense account; a deduction names the liability account; an employer contribution names both.
            </:description>
          </.section_heading>
          <.form
            for={@mapping_form}
            id="payroll-mapping-form"
            phx-change="change_mapping"
            phx-submit="save_mapping"
            class="mt-4 grid gap-x-6 gap-y-2 md:grid-cols-2"
          >
            <.input
              field={@mapping_form[:kind]}
              id="payroll-mapping-kind"
              type="select"
              label="Kind"
              options={Enum.map(Payroll.mapping_kinds(), &{Format.mapping_kind(&1), &1})}
            />
            <.input
              field={@mapping_form[:code]}
              id="payroll-mapping-code"
              label="Code (as the source names it)"
              maxlength="60"
              required
            />
            <.input
              :if={@mapping_form[:kind].value != "claim_category"}
              field={@mapping_form[:direction]}
              id="payroll-mapping-direction"
              type="select"
              label="Direction"
              options={Payroll.component_directions()}
            />
            <.input
              field={@mapping_form[:expense_account_id]}
              id="payroll-mapping-expense-account"
              type="select"
              label="Expense account (asset or expense)"
              prompt="None"
              options={chart_options(@chart, ["asset", "expense"])}
            />
            <.input
              field={@mapping_form[:liability_account_id]}
              id="payroll-mapping-liability-account"
              type="select"
              label="Liability account"
              prompt="None"
              options={chart_options(@chart, ["liability"])}
            />
            <.input
              field={@mapping_form[:reason]}
              id="payroll-mapping-reason"
              label="Reason for the change"
              maxlength="500"
              wrapper_class="md:col-span-2 mb-4"
            />
            <div class="md:col-span-2">
              <.button type="submit" id="payroll-mapping-save" variant="primary">
                Save mapping
              </.button>
            </div>
          </.form>
        </.card>

        <.card
          :if={@settings}
          id="payroll-changes"
          inner_class="p-0"
          role="region"
          aria-labelledby="payroll-changes-heading"
        >
          <.section_heading id="payroll-changes-heading" title="Change history" class="p-5 pb-0" />
          <.table
            id="payroll-settings-changes-table"
            rows={@settings_changes}
            framed={false}
            row_id={&"payroll-settings-change-#{&1.id}"}
            caption="Posting account changes"
          >
            <:col :let={change} label="When">{change.changed_at}</:col>
            <:col :let={change} label="By">#{change.changed_by_user_id}</:col>
            <:col :let={change} label="Net pay">
              {Format.account(@chart_by_id, change.old_net_pay_account_id)} → {Format.account(
                @chart_by_id,
                change.new_net_pay_account_id
              )}
            </:col>
            <:col :let={change} label="Claims payable">
              {Format.account(@chart_by_id, change.old_claims_payable_account_id)} → {Format.account(
                @chart_by_id,
                change.new_claims_payable_account_id
              )}
            </:col>
            <:col :let={change} label="Reason">{change.reason || "—"}</:col>
            <:empty>The posting accounts have not been set.</:empty>
          </.table>
          <.table
            id="payroll-mapping-changes-table"
            rows={@mapping_changes}
            framed={false}
            row_id={&"payroll-mapping-change-#{&1.id}"}
            caption="Mapping changes"
          >
            <:col :let={change} label="When">{change.changed_at}</:col>
            <:col :let={change} label="By">#{change.changed_by_user_id}</:col>
            <:col :let={change} label="Mapping">#{change.mapping_id}</:col>
            <:col :let={change} label="Expense account">
              {Format.account(@chart_by_id, change.old_expense_account_id)} → {Format.account(
                @chart_by_id,
                change.new_expense_account_id
              )}
            </:col>
            <:col :let={change} label="Liability account">
              {Format.account(@chart_by_id, change.old_liability_account_id)} → {Format.account(
                @chart_by_id,
                change.new_liability_account_id
              )}
            </:col>
            <:col :let={change} label="Reason">{change.reason || "—"}</:col>
            <:empty>No mapping has been changed.</:empty>
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
