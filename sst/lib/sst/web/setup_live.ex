defmodule Bilimbi.Finance.Sst.Web.SetupLive do
  @moduledoc """
  The company's SST setup: its registration (numbers, taxable period
  cycle, service tax basis) with every version recorded, and which return
  box each receivables and payables tax code reports in, with every
  mapping recorded. Every write is a facade call that re-asks its
  capability; nothing here is edited in place.
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
     |> assign(:page_title, "SST setup")
     |> assign(:active_nav, "finance.sst.setup")
     |> assign(:company_id, Scope.actor(scope).company_id)
     |> assign(
       :mapping_form,
       to_form(%{"tax_code" => "", "box" => "", "reason" => ""}, as: :mapping)
     )
     |> load()
     |> reset_registration_form()}
  end

  defp load(socket) do
    %{current_scope: %{scope: scope} = current_scope, company_id: company_id} = socket.assigns

    registrations =
      case Sst.list_registrations(scope, company_id) do
        {:ok, registrations} -> registrations
        {:error, _reason} -> nil
      end

    tax_codes =
      case Sst.list_tax_codes(scope, company_id) do
        {:ok, codes} -> codes
        {:error, _reason} -> nil
      end

    mappings =
      case Sst.list_mappings(scope, company_id, limit: 500) do
        {:ok, mappings} -> mappings
        {:error, _reason} -> []
      end

    socket
    |> assign(:registrations, registrations)
    |> assign(:registration, registrations && List.last(registrations))
    |> assign(:tax_codes, tax_codes)
    |> assign(:mappings, Enum.reverse(mappings))
    |> assign(
      :can_manage?,
      LiveAuthorization.allowed_now?(current_scope, Sst.manage_settings_capability())
    )
  end

  defp reset_registration_form(socket) do
    current = socket.assigns.registration || %{}

    assign(
      socket,
      :registration_form,
      to_form(
        %{
          "sales_tax_number" => current[:sales_tax_number] || "",
          "service_tax_number" => current[:service_tax_number] || "",
          "period_months" => to_string(current[:period_months] || 2),
          "period_start" => to_string(current[:period_start] || ""),
          "service_tax_basis" => current[:service_tax_basis] || "payment",
          "reason" => ""
        },
        as: :registration
      )
    )
  end

  @impl true
  def handle_event("registration_change", %{"registration" => params}, socket),
    do: {:noreply, assign(socket, :registration_form, to_form(params, as: :registration))}

  def handle_event("register", %{"registration" => params}, socket) do
    case LiveAuthorization.authorize_event(socket, Sst.manage_settings_capability()) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        case Sst.register(
               socket.assigns.current_scope.scope,
               socket.assigns.company_id,
               params
             ) do
          {:ok, registration} ->
            {:noreply,
             socket
             |> put_flash(:success, "Registration version #{registration.version} recorded.")
             |> load()
             |> reset_registration_form()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:registration_form, form_with_errors(params, changeset, :registration))
             |> put_flash(:error, Format.refusal(changeset))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, Format.refusal(reason))}
        end
    end
  end

  def handle_event("mapping_change", %{"mapping" => params}, socket),
    do: {:noreply, assign(socket, :mapping_form, to_form(params, as: :mapping))}

  def handle_event("map", %{"mapping" => params}, socket) do
    case LiveAuthorization.authorize_event(socket, Sst.manage_settings_capability()) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        {source, tax_code_id} = parse_tax_code(params["tax_code"])

        case Sst.map_tax_code(socket.assigns.current_scope.scope, socket.assigns.company_id, %{
               source: source,
               tax_code_id: tax_code_id,
               box: params["box"],
               reason: params["reason"]
             }) do
          {:ok, mapping} ->
            {:noreply,
             socket
             |> put_flash(
               :success,
               "#{mapping.tax_code} reports in #{Format.mapped_box_name(mapping.box)}."
             )
             |> assign(
               :mapping_form,
               to_form(%{"tax_code" => "", "box" => "", "reason" => ""}, as: :mapping)
             )
             |> load()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:mapping_form, form_with_errors(params, changeset, :mapping))
             |> put_flash(:error, Format.refusal(changeset))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, Format.refusal(reason))}
        end
    end
  end

  defp parse_tax_code(value) do
    case String.split(value || "", ":", parts: 2) do
      [source, id] -> {source, id}
      _other -> {nil, nil}
    end
  end

  defp form_with_errors(params, changeset, as) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, _options} -> message end)
      |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &{field, {&1, []}}) end)

    to_form(params, as: as, errors: errors)
  end

  defp tax_code_options(codes) do
    for code <- codes do
      {"#{Format.source_name(code.source)} #{code.code} #{code.name} (#{Decimal.to_string(code.rate, :normal)}%)",
       "#{code.source}:#{code.id}"}
    end
  end

  defp box_options do
    boxes =
      for source <- ~w(receivables payables),
          box <- Sst.mappable_boxes(source),
          uniq: true,
          do: {Format.mapped_box_name(box.key), box.key}

    [{"Not reported", ""} | boxes]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="sst-setup">
        <.header>
          SST setup
          <:subtitle>
            The company's Sales and Service Tax registration and which SST-02 item each tax code reports in.
          </:subtitle>
          <:actions>
            <.link id="sst-setup-returns" navigate={~p"/finance/sst"}>SST returns</.link>
          </:actions>
        </.header>

        <.empty_state :if={is_nil(@registrations)} id="sst-setup-forbidden" forbidden="view SST" />

        <.card
          :if={@registrations}
          id="sst-registration"
          inner_class="p-5 sm:p-6"
          role="region"
          aria-labelledby="sst-registration-heading"
        >
          <.section_heading id="sst-registration-heading" title="Registration">
            <:description>
              Each change is recorded as a new version; returns keep the version they were prepared under.
            </:description>
          </.section_heading>

          <.empty_state
            :if={is_nil(@registration)}
            id="sst-registration-none"
            title="Not registered yet"
            reason="Record the registration numbers and the taxable period cycle to prepare returns."
          />

          <.list :if={@registration} id="sst-registration-facts">
            <:item title="Sales tax number" id="sst-sales-tax-number">
              {@registration.sales_tax_number || "—"}
            </:item>
            <:item title="Service tax number" id="sst-service-tax-number">
              {@registration.service_tax_number || "—"}
            </:item>
            <:item title="Taxable period" id="sst-cycle">
              {@registration.period_months} months, the first from {@registration.period_start}
            </:item>
            <:item title="Service tax due" id="sst-basis">
              {Format.basis_name(@registration.service_tax_basis)}
            </:item>
          </.list>

          <div :if={@registrations != []} class="mt-4">
            <.table
              id="sst-registration-history"
              rows={Enum.reverse(@registrations)}
              framed={false}
              row_id={&"registration-#{&1.version}"}
            >
              <:col :let={r} label="Version">{r.version}</:col>
              <:col :let={r} label="Numbers">
                {r.sales_tax_number || "—"} / {r.service_tax_number || "—"}
              </:col>
              <:col :let={r} label="Cycle">{r.period_months} months from {r.period_start}</:col>
              <:col :let={r} label="Service tax">{r.service_tax_basis}</:col>
              <:col :let={r} label="By">
                {Format.actor(r.recorded_by_user_id, r.recorded_by_impersonator_id)}
              </:col>
              <:col :let={r} label="When">
                <.datetime
                  id={"registration-#{r.version}-at"}
                  value={r.recorded_at}
                  precision={:second}
                />
              </:col>
              <:col :let={r} label="Reason">{r.reason}</:col>
            </.table>
          </div>

          <.empty_state
            :if={!@can_manage?}
            id="sst-registration-manage-forbidden"
            forbidden="change the SST registration"
            class="mt-4"
          />

          <.form
            :if={@can_manage?}
            for={@registration_form}
            id="sst-registration-form"
            phx-change="registration_change"
            phx-submit="register"
            class="mt-6 grid gap-x-6 gap-y-2 md:grid-cols-2"
          >
            <.input
              field={@registration_form[:sales_tax_number]}
              id="registration-sales-tax-number"
              label="Sales tax registration number"
              placeholder="A00-0000-00000000"
              maxlength="30"
            />
            <.input
              field={@registration_form[:service_tax_number]}
              id="registration-service-tax-number"
              label="Service tax registration number"
              placeholder="A00-0000-00000000"
              maxlength="30"
            />
            <.input
              field={@registration_form[:period_months]}
              id="registration-period-months"
              type="number"
              min="1"
              max="12"
              label="Months in a taxable period"
              hint="Two, unless the Director General approved another."
            />
            <.input
              field={@registration_form[:period_start]}
              id="registration-period-start"
              type="date"
              label="First taxable period starts"
              hint="It runs to the end of the month the cycle's months on, counting its own month."
            />
            <.input
              field={@registration_form[:service_tax_basis]}
              id="registration-service-tax-basis"
              type="select"
              label="Service tax is due"
              options={[
                {"When payment is received (section 11(1))", "payment"},
                {"When invoiced, with the Director General's approval (section 11(1A))", "invoice"}
              ]}
            />
            <.input
              field={@registration_form[:reason]}
              id="registration-reason"
              label="Reason for the change"
              maxlength="500"
            />
            <div class="md:col-span-2">
              <.button type="submit" id="registration-save" variant="primary">
                Record registration
              </.button>
            </div>
          </.form>
        </.card>

        <.empty_state
          :if={@registrations && is_nil(@tax_codes)}
          id="sst-tax-codes-forbidden"
          forbidden="view the receivables and payables tax codes"
        />

        <.card
          :if={@tax_codes}
          id="sst-mappings"
          inner_class="p-0"
          role="region"
          aria-labelledby="sst-mappings-heading"
        >
          <.section_heading
            id="sst-mappings-heading"
            title="Tax codes and SST-02 items"
            count={length(@tax_codes)}
            class="p-5 pb-0"
          >
            <:description>
              A return counts each tax code's documents in its item; a code with tax and no item stops a return finalising.
            </:description>
          </.section_heading>
          <.table
            id="sst-tax-codes-table"
            rows={@tax_codes}
            framed={false}
            row_id={&"tax-code-#{&1.source}-#{&1.id}"}
          >
            <:col :let={code} label="Source">{Format.source_name(code.source)}</:col>
            <:col :let={code} label="Code">{code.code}</:col>
            <:col :let={code} label="Name">{code.name}</:col>
            <:col :let={code} label="Rate" align={:right}>
              <span class="tabular-nums">{Decimal.to_string(code.rate, :normal)}%</span>
            </:col>
            <:col :let={code} label="Reports in">
              <%= if code.mapping do %>
                {Format.mapped_box_name(code.mapping.box)}
              <% else %>
                <.badge kind={:warning}>unmapped</.badge>
              <% end %>
            </:col>
            <:empty title="No tax codes yet" reason="Tax codes are kept in receivables and payables." />
          </.table>

          <.form
            :if={@can_manage? and @tax_codes != []}
            for={@mapping_form}
            id="sst-mapping-form"
            phx-change="mapping_change"
            phx-submit="map"
            class="grid gap-x-6 gap-y-2 p-5 md:grid-cols-3"
          >
            <.input
              field={@mapping_form[:tax_code]}
              id="mapping-tax-code"
              type="select"
              label="Tax code"
              prompt="Choose a tax code"
              options={tax_code_options(@tax_codes)}
              required
            />
            <.input
              field={@mapping_form[:box]}
              id="mapping-box"
              type="select"
              label="SST-02 item"
              options={box_options()}
            />
            <.input
              field={@mapping_form[:reason]}
              id="mapping-reason"
              label="Reason"
              maxlength="500"
            />
            <div class="md:col-span-3">
              <.button type="submit" id="mapping-save" variant="primary">Map tax code</.button>
            </div>
          </.form>
        </.card>

        <.card
          :if={@registrations}
          id="sst-mapping-history"
          inner_class="p-0"
          role="region"
          aria-labelledby="sst-mapping-history-heading"
        >
          <.section_heading
            id="sst-mapping-history-heading"
            title="Mapping history"
            class="p-5 pb-0"
          />
          <.table
            id="sst-mapping-history-table"
            rows={@mappings}
            framed={false}
            row_id={&"mapping-#{&1.mapping_number}"}
          >
            <:col :let={m} label="No.">{m.mapping_number}</:col>
            <:col :let={m} label="Tax code">{Format.source_name(m.source)} {m.tax_code}</:col>
            <:col :let={m} label="Item">{Format.mapped_box_name(m.box)}</:col>
            <:col :let={m} label="By">
              {Format.actor(m.recorded_by_user_id, m.recorded_by_impersonator_id)}
            </:col>
            <:col :let={m} label="When">
              <.datetime
                id={"mapping-#{m.mapping_number}-at"}
                value={m.recorded_at}
                precision={:second}
              />
            </:col>
            <:col :let={m} label="Reason">{m.reason}</:col>
            <:empty title="No mappings yet" reason="Map each tax code to the item it reports in." />
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
