defmodule Bilimbi.Finance.Sst.Web.ReturnLive do
  @moduledoc """
  One SST return: its SST-02 items in the form's order, what keeps it from
  finalising (unmapped tax codes, a rate that does not fit its item, a
  period not yet ended), its adjustments, the source rows behind each item,
  and how the documents' tax compares with each tax account's ledger
  postings, the difference shown as it is. An open return reads its
  figures now and follows the ledger's postings; a finalised one shows the
  figures it was finalised with, which never change, and what documents
  posted since would change; an amendment shows what it changes. Every
  write is a facade call that re-asks its capability.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Sst
  alias Bilimbi.Finance.Sst.Web.Format

  @blank_adjustment %{
    "box" => "",
    "taxable_amount" => "",
    "tax_amount" => "",
    "description" => "",
    "reference" => ""
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope.scope
    company_id = Scope.actor(scope).company_id

    socket =
      socket
      |> assign(:page_title, "SST return")
      |> assign(:active_nav, "finance.sst")
      |> assign(:company_id, company_id)
      |> assign(:return_id, Params.positive_integer(id, 0))
      |> assign(:modal, nil)
      |> assign(:reason_form, to_form(%{"reason" => ""}, as: :reason))
      |> assign(:adjustment_form, to_form(@blank_adjustment, as: :adjustment))

    if connected?(socket), do: Ledger.subscribe_postings(scope, company_id)

    {:ok, load(socket)}
  end

  defp load(socket) do
    %{current_scope: %{scope: scope} = current_scope, company_id: company_id, return_id: id} =
      socket.assigns

    case Sst.get_return(scope, company_id, id) do
      {:ok, report} ->
        socket
        |> assign(:report, report)
        |> assign(:refusal, nil)
        |> assign(
          :page_title,
          "#{Format.tax_name(report.tax_type)} return #{report.return_number}"
        )
        |> assign(:can_prepare?, may?(current_scope, Sst.prepare_returns_capability()))
        |> assign(:can_finalise?, may?(current_scope, Sst.finalise_returns_capability()))
        |> assign(:can_amend?, may?(current_scope, Sst.amend_returns_capability()))

      {:error, reason} ->
        socket
        |> assign(:report, nil)
        |> assign(:refusal, reason)
        |> assign(:can_prepare?, false)
        |> assign(:can_finalise?, false)
        |> assign(:can_amend?, false)
    end
  end

  defp may?(current_scope, capability),
    do: LiveAuthorization.allowed_now?(current_scope, capability)

  @impl true
  def handle_event("finalise", _params, socket) do
    act(socket, Sst.finalise_returns_capability(), fn scope, company_id, id ->
      with {:ok, tax_return} <- Sst.finalise_return(scope, company_id, id),
           do:
             {:ok,
              "Return #{tax_return.return_number} finalised as version #{tax_return.version}; its figures are now fixed."}
    end)
  end

  def handle_event("open_modal", %{"modal" => modal}, socket)
      when modal in ~w(discard amend withdraw) do
    {:noreply,
     socket
     |> assign(:modal, modal)
     |> assign(:reason_form, to_form(%{"reason" => ""}, as: :reason))}
  end

  def handle_event("open_withdraw", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:modal, "withdraw")
     |> assign(:reason_form, to_form(%{"reason" => "", "adjustment_id" => id}, as: :reason))}
  end

  def handle_event("close_modal", _params, socket), do: {:noreply, assign(socket, :modal, nil)}

  def handle_event("reason_change", %{"reason" => params}, socket),
    do: {:noreply, assign(socket, :reason_form, to_form(params, as: :reason))}

  def handle_event("submit_reason", %{"reason" => params}, socket) do
    case socket.assigns.modal do
      "discard" ->
        act(socket, Sst.prepare_returns_capability(), fn scope, company_id, id ->
          with {:ok, _} <- Sst.discard_return(scope, company_id, id, %{reason: params["reason"]}),
               do: {:ok, "The return was discarded; it stays on record."}
        end)

      "amend" ->
        case LiveAuthorization.authorize_event(socket, Sst.amend_returns_capability()) do
          {:denied, socket} ->
            {:noreply, socket}

          {:ok, socket} ->
            case Sst.amend_return(
                   socket.assigns.current_scope.scope,
                   socket.assigns.company_id,
                   socket.assigns.return_id,
                   %{reason: params["reason"]}
                 ) do
              {:ok, amendment} ->
                {:noreply,
                 socket
                 |> put_flash(:success, "Amendment opened as return #{amendment.return_number}.")
                 |> push_navigate(to: ~p"/finance/sst/returns/#{amendment.id}")}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, Format.refusal(reason))}
            end
        end

      "withdraw" ->
        act(socket, Sst.prepare_returns_capability(), fn scope, company_id, _id ->
          with {:ok, _} <-
                 Sst.withdraw_adjustment(scope, company_id, params["adjustment_id"], %{
                   reason: params["reason"]
                 }),
               do: {:ok, "The adjustment was withdrawn; it stays on record."}
        end)

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("adjustment_change", %{"adjustment" => params}, socket),
    do: {:noreply, assign(socket, :adjustment_form, to_form(params, as: :adjustment))}

  def handle_event("add_adjustment", %{"adjustment" => params}, socket) do
    case LiveAuthorization.authorize_event(socket, Sst.prepare_returns_capability()) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        attributes =
          Map.new(params, fn
            {key, ""} when key in ~w(taxable_amount tax_amount) -> {key, nil}
            pair -> pair
          end)

        case Sst.add_adjustment(
               socket.assigns.current_scope.scope,
               socket.assigns.company_id,
               socket.assigns.return_id,
               attributes
             ) do
          {:ok, adjustment} ->
            {:noreply,
             socket
             |> put_flash(:success, "Adjustment #{adjustment.adjustment_number} added.")
             |> assign(:adjustment_form, to_form(@blank_adjustment, as: :adjustment))
             |> load()}

          {:error, %Ecto.Changeset{} = changeset} ->
            errors =
              changeset
              |> Ecto.Changeset.traverse_errors(fn {message, _options} -> message end)
              |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &{field, {&1, []}}) end)

            {:noreply,
             socket
             |> assign(:adjustment_form, to_form(params, as: :adjustment, errors: errors))
             |> put_flash(:error, Format.refusal(changeset))}

          {:error, reason} ->
            {:noreply, socket |> put_flash(:error, Format.refusal(reason)) |> load()}
        end
    end
  end

  defp act(socket, capability, fun) do
    case LiveAuthorization.authorize_event(socket, capability) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        %{current_scope: %{scope: scope}, company_id: company_id, return_id: id} = socket.assigns

        case fun.(scope, company_id, id) do
          {:ok, message} ->
            {:noreply, socket |> put_flash(:success, message) |> assign(:modal, nil) |> load()}

          {:error, reason} ->
            {:noreply, socket |> put_flash(:error, Format.refusal(reason)) |> load()}
        end
    end
  end

  # An open return follows the books; a finalised one cannot change, but
  # what documents posted since would change is read again.
  @impl true
  def handle_info({:finance_ledger_posted, _notice}, socket) do
    drain_notices()

    case socket.assigns.report do
      %{status: status} when status in ~w(open finalised) -> {:noreply, load(socket)}
      _other -> {:noreply, socket}
    end
  end

  defp drain_notices do
    receive do
      {:finance_ledger_posted, _notice} -> drain_notices()
    after
      0 -> :ok
    end
  end

  defp status_kind("open"), do: :warning
  defp status_kind("finalised"), do: :success
  defp status_kind("discarded"), do: :neutral

  defp event_label("opened"), do: "Opened"
  defp event_label("finalised"), do: "Finalised"
  defp event_label("discarded"), do: "Discarded"

  defp zero?(%Decimal{} = value), do: Decimal.equal?(value, 0)

  defp blockers(%{status: "open", figures: figures} = report) when is_map(figures) do
    Enum.reject(
      [
        figures.unmapped != [] && "unmapped",
        figures.rate_mismatches != [] && "rate",
        !report.period_ended && "period"
      ],
      &(&1 == false)
    )
  end

  defp blockers(_report), do: []

  # What an amendment changes in a box: its tax, or its value for a box
  # without tax; blank when unchanged.
  defp change(amends, key, minor_units) do
    case Enum.find(amends.boxes, &(&1.key == key)) do
      nil -> ""
      box -> Format.money(box.tax_change || box.taxable_change, minor_units)
    end
  end

  defp amendable?(report),
    do: report.status == "finalised" and is_nil(report.superseded_by_return_id)

  defp adjustable_options(tax_type) do
    for box <- Sst.boxes(tax_type), box.kind != :total, do: {"#{box.item} #{box.label}", box.key}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="sst-return" variant={:detail}>
        <.back_link id="sst-return-back" navigate={~p"/finance/sst"} title="SST returns" />

        <.empty_state
          :if={@refusal}
          id="sst-return-refusal"
          title="Return unavailable"
          reason={Format.refusal(@refusal)}
        />

        <%= if @report do %>
          <.header>
            {Format.tax_name(@report.tax_type)} return {@report.return_number}: {@report.period_start} to {@report.period_end}
            <:subtitle>
              <span id="sst-return-status"><.badge kind={status_kind(@report.status)}>
                {@report.status}{if @report.version, do: " v#{@report.version}"}
              </.badge></span>
              <span :if={@report.amends_return_id} id="sst-return-amends" class="ml-2">
                amends return {@report.amends && @report.amends.return_number}: {@report.reason}
              </span>
              <span :if={@report.superseded_by_return_id} id="sst-return-superseded" class="ml-2">
                amended by a later version
              </span>
            </:subtitle>
            <:actions>
              <.link
                :if={@report.status != "discarded"}
                id="sst-return-export"
                href={~p"/finance/sst/returns/#{@report.id}/export.csv"}
              >
                Export CSV
              </.link>
              <.link
                :if={@report.status != "discarded"}
                id="sst-return-print"
                href={~p"/finance/sst/returns/#{@report.id}/print"}
                target="_blank"
              >
                Printable
              </.link>
            </:actions>
          </.header>

          <.card
            id="sst-return-facts"
            inner_class="p-5 sm:p-6"
            role="region"
            aria-labelledby="sst-return-facts-heading"
          >
            <.section_heading id="sst-return-facts-heading" title="Part A" />
            <.list id="sst-return-particulars">
              <:item title="SST registration number" id="sst-return-number">
                {@report.registration_number || "—"}
              </:item>
              <:item title="Taxable period" id="sst-return-period">
                {@report.period_start} to {@report.period_end}
              </:item>
              <:item title="Return and payment due" id="sst-return-due">{@report.due_date}</:item>
              <:item
                :if={@report.tax_type == "service_tax" and @report.figures}
                title="Service tax counted"
                id="sst-return-basis"
              >
                {Format.basis_name(
                  @report.figures[:service_tax_basis] || @report.registration.service_tax_basis
                )}
              </:item>
              <:item :if={@report.figures} title="Read through" id="sst-return-through">
                ledger entry {@report.figures.through_entry_number}, mapping {@report.figures.through_mapping_number}
              </:item>
            </.list>

            <div :if={@report.status == "open"} class="mt-4 flex flex-wrap gap-2">
              <.button
                :if={@can_finalise?}
                id="sst-return-finalise"
                variant="primary"
                phx-click="finalise"
                disabled={blockers(@report) != []}
              >
                Finalise
              </.button>
              <.button
                :if={@can_prepare?}
                id="sst-return-discard"
                phx-click="open_modal"
                phx-value-modal="discard"
              >
                Discard
              </.button>
            </div>
            <.empty_state
              :if={@report.status == "open" and !@can_finalise?}
              id="sst-return-finalise-forbidden"
              forbidden="finalise SST returns"
              class="mt-4"
            />
            <div :if={amendable?(@report) and @can_amend?} class="mt-4">
              <.button id="sst-return-amend" phx-click="open_modal" phx-value-modal="amend">
                Amend
              </.button>
            </div>
          </.card>

          <.card
            :if={blockers(@report) != []}
            id="sst-return-blockers"
            inner_class="p-5 sm:p-6"
            role="region"
            aria-labelledby="sst-return-blockers-heading"
          >
            <.section_heading id="sst-return-blockers-heading" title="Before it can be finalised" />
            <ul class="mt-2 list-disc pl-5 text-sm">
              <li :if={"period" in blockers(@report)} id="blocker-period">
                The period ends on {@report.period_end}; a return is finalised after its period ends.
              </li>
              <li
                :for={row <- @report.figures.unmapped}
                id={"blocker-unmapped-#{row.source}-#{row.tax_code_id}"}
              >
                {Format.source_name(row.source)} tax code {row.tax_code} has tax in the period and no SST-02 item: <.link navigate={
                  ~p"/finance/sst/setup"
                }>map it</.link>.
              </li>
              <li :for={row <- @report.figures.rate_mismatches} id={"blocker-rate-#{row.line_number}"}>
                Tax code {row.tax_code} at {Decimal.to_string(row.rate, :normal)}% does not fit {Format.box_name(
                  @report.tax_type,
                  row.box
                )}.
              </li>
            </ul>
          </.card>

          <.card
            :if={@report.posted_since && @report.posted_since.boxes != []}
            id="sst-return-posted-since"
            inner_class="p-5 sm:p-6"
            role="region"
            aria-labelledby="sst-return-posted-since-heading"
          >
            <.section_heading
              id="sst-return-posted-since-heading"
              title="Posted since this return was finalised"
            >
              <:description>
                Documents dated in the period and posted after it change these items; the finalised figures stay as they were. Amend the return to report them.
              </:description>
            </.section_heading>
            <.table
              id="sst-return-posted-since-table"
              rows={@report.posted_since.boxes}
              framed={false}
              row_id={&"posted-since-#{&1.key}"}
            >
              <:col :let={b} label="Item">{b.item} {b.label}</:col>
              <:col :let={b} label="Value change" align={:right}>
                <span class="tabular-nums">{Format.money(
                  b.taxable_change,
                  @report.figures.minor_units
                )}</span>
              </:col>
              <:col :let={b} label="Tax change" align={:right}>
                <span class="tabular-nums">{Format.money(b.tax_change, @report.figures.minor_units)}</span>
              </:col>
            </.table>
          </.card>

          <.card
            :if={@report.figures}
            id="sst-return-items"
            inner_class="p-0"
            role="region"
            aria-labelledby="sst-return-items-heading"
          >
            <.section_heading id="sst-return-items-heading" title="SST-02 items" class="p-5 pb-0">
              <:description>
                In {@report.figures.currency_code}. Items 15 and 16 (penalty), Part B1's item lines, and Part F's declaration are completed when filing.
              </:description>
            </.section_heading>
            <.table
              id="sst-return-items-table"
              rows={@report.figures.boxes}
              framed={false}
              row_id={&"box-#{&1.key}"}
            >
              <:col :let={b} label="Item">{b.item}</:col>
              <:col :let={b} label="Description">
                <span class={if b.kind == :total, do: "font-semibold"}>{b.label}</span>
              </:col>
              <:col :let={b} label="Value" align={:right}>
                <span class="tabular-nums">{Format.money(
                  b.taxable_amount,
                  @report.figures.minor_units
                )}</span>
              </:col>
              <:col :let={b} label="Tax" align={:right}>
                <span class={["tabular-nums", b.kind == :total && "font-semibold"]}>
                  {Format.money(b.tax_amount, @report.figures.minor_units)}
                </span>
              </:col>
              <:col
                :let={b}
                :if={@report.amends}
                label="Change from the amended version"
                align={:right}
              >
                <span class="tabular-nums">
                  {change(@report.amends, b.key, @report.figures.minor_units)}
                </span>
              </:col>
            </.table>
          </.card>

          <.card
            :if={@report.status != "discarded"}
            id="sst-return-adjustments"
            inner_class="p-0"
            role="region"
            aria-labelledby="sst-return-adjustments-heading"
          >
            <.section_heading
              id="sst-return-adjustments-heading"
              title="Adjustments"
              count={Enum.count(@report.adjustments, & &1.standing)}
              class="p-5 pb-0"
            >
              <:description>
                Amounts the documents cannot show: approved bad debt relief, a deduction, goods taken for own use, a recovered bad debt. Each adds to its item.
              </:description>
            </.section_heading>
            <.table
              id="sst-return-adjustments-table"
              rows={@report.adjustments}
              framed={false}
              row_id={&"adjustment-#{&1.adjustment_number}"}
            >
              <:col :let={a} label="No.">{a.adjustment_number}</:col>
              <:col :let={a} label="Item">{Format.box_name(@report.tax_type, a.box)}</:col>
              <:col :let={a} label="Description">
                {a.description}
                <span :if={a.reference} class="block text-xs text-ink-muted">{a.reference}</span>
                <span :if={a.withdrawal} class="block text-xs text-ink-muted">
                  Withdrawn: {a.withdrawal.description}
                </span>
              </:col>
              <:col :let={a} label="Value" align={:right}>
                <span class="tabular-nums">{Format.money(
                  a.taxable_amount,
                  @report.figures.minor_units
                )}</span>
              </:col>
              <:col :let={a} label="Tax" align={:right}>
                <span class="tabular-nums">{Format.money(a.tax_amount, @report.figures.minor_units)}</span>
              </:col>
              <:col :let={a} label="By">
                {Format.actor(a.recorded_by_user_id, a.recorded_by_impersonator_id)}
              </:col>
              <:action :let={a}>
                <.button
                  :if={@report.status == "open" and a.standing and @can_prepare?}
                  id={"adjustment-#{a.id}-withdraw"}
                  phx-click="open_withdraw"
                  phx-value-id={a.id}
                >
                  Withdraw
                </.button>
              </:action>
              <:empty title="No adjustments" reason="The figures come from posted documents alone." />
            </.table>

            <.form
              :if={@report.status == "open" and @can_prepare?}
              for={@adjustment_form}
              id="sst-adjustment-form"
              phx-change="adjustment_change"
              phx-submit="add_adjustment"
              class="grid gap-x-6 gap-y-2 p-5 md:grid-cols-2"
            >
              <.input
                field={@adjustment_form[:box]}
                id="adjustment-box"
                type="select"
                label="Item"
                prompt="Choose an item"
                options={adjustable_options(@report.tax_type)}
                required
              />
              <.input
                field={@adjustment_form[:description]}
                id="adjustment-description"
                label="Description"
                maxlength="500"
                required
              />
              <.input
                field={@adjustment_form[:taxable_amount]}
                id="adjustment-taxable"
                label="Value"
                inputmode="decimal"
              />
              <.input
                field={@adjustment_form[:tax_amount]}
                id="adjustment-tax"
                label="Tax"
                inputmode="decimal"
              />
              <.input
                field={@adjustment_form[:reference]}
                id="adjustment-reference"
                label="Reference"
                maxlength="100"
              />
              <div class="flex items-end pb-4">
                <.button type="submit" id="adjustment-save" variant="primary">Add adjustment</.button>
              </div>
            </.form>
          </.card>

          <.card
            :if={@report.figures}
            id="sst-return-sources"
            inner_class="p-0"
            role="region"
            aria-labelledby="sst-return-sources-heading"
          >
            <.section_heading
              id="sst-return-sources-heading"
              title="Where the figures come from"
              class="p-5 pb-0"
            >
              <:description>
                Posted documents in the period by tax code, and the item each went to.
              </:description>
            </.section_heading>
            <.table
              id="sst-return-sources-table"
              rows={@report.figures.sources}
              framed={false}
              row_id={&"source-#{&1.line_number}"}
            >
              <:col :let={s} label="Source">
                {Format.source_name(s.source)} {Format.kind_name(s.document_kind)}
                <span class="block text-xs text-ink-muted">
                  {Format.measure_name(s.measure)}{if s.prior_period and s.measure == "documents",
                    do: ", on an earlier period's invoice"}
                </span>
              </:col>
              <:col :let={s} label="Tax code">
                {s.tax_code} ({Decimal.to_string(s.rate, :normal)}%)
              </:col>
              <:col :let={s} label="Documents" align={:right}>{s.document_count}</:col>
              <:col :let={s} label="Item">{Format.box_name(@report.tax_type, s.box)}</:col>
              <:col :let={s} label="Value" align={:right}>
                <span class="tabular-nums">{Format.money(
                  s.taxable_amount,
                  @report.figures.minor_units
                )}</span>
              </:col>
              <:col :let={s} label="Tax" align={:right}>
                <span class="tabular-nums">{Format.money(s.tax_amount, @report.figures.minor_units)}</span>
              </:col>
              <:empty
                title="No documents"
                reason="No posted document in the period carries a tax code of this return."
              />
            </.table>
          </.card>

          <.card
            :if={@report.figures}
            id="sst-return-reconciliation"
            inner_class="p-0"
            role="region"
            aria-labelledby="sst-return-reconciliation-heading"
          >
            <.section_heading
              id="sst-return-reconciliation-heading"
              title="Ledger reconciliation"
              class="p-5 pb-0"
            >
              <:description>
                Each tax account's postings in the period against the tax its documents posted. A difference is an entry no document explains, such as a payment of an earlier return or a manual journal.
              </:description>
            </.section_heading>
            <.table
              id="sst-return-accounts-table"
              rows={@report.figures.accounts}
              framed={false}
              row_id={&"account-#{&1.account_id}"}
            >
              <:col :let={a} label="Account">{a.account_code} {a.account_name}</:col>
              <:col :let={a} label="Ledger debits" align={:right}>
                <span class="tabular-nums">{Format.money(a.ledger_debits, @report.figures.minor_units)}</span>
              </:col>
              <:col :let={a} label="Ledger credits" align={:right}>
                <span class="tabular-nums">{Format.money(
                  a.ledger_credits,
                  @report.figures.minor_units
                )}</span>
              </:col>
              <:col :let={a} label="Document debits" align={:right}>
                <span class="tabular-nums">{Format.money(
                  a.document_debits,
                  @report.figures.minor_units
                )}</span>
              </:col>
              <:col :let={a} label="Document credits" align={:right}>
                <span class="tabular-nums">{Format.money(
                  a.document_credits,
                  @report.figures.minor_units
                )}</span>
              </:col>
              <:col :let={a} label="Difference" align={:right}>
                <span class="tabular-nums">{Format.money(a.difference, @report.figures.minor_units)}</span>
                <.badge :if={zero?(a.difference)} kind={:success} class="ml-1">agrees</.badge>
                <.badge :if={!zero?(a.difference)} kind={:warning} class="ml-1">differs</.badge>
              </:col>
              <:empty
                title="No tax account"
                reason="No tax code of this return names a ledger account yet."
              />
            </.table>
          </.card>

          <.card
            id="sst-return-events"
            inner_class="p-0"
            role="region"
            aria-labelledby="sst-return-events-heading"
          >
            <.section_heading id="sst-return-events-heading" title="History" class="p-5 pb-0" />
            <.table
              id="sst-return-events-table"
              rows={@report.events}
              framed={false}
              row_id={&"event-#{&1.event_number}"}
            >
              <:col :let={e} label="Event">
                {event_label(e.action)}{if e.version, do: " as version #{e.version}"}
              </:col>
              <:col :let={e} label="By">
                {Format.actor(e.recorded_by_user_id, e.recorded_by_impersonator_id)}
              </:col>
              <:col :let={e} label="When">
                <.datetime
                  id={"event-#{e.event_number}-at"}
                  value={e.recorded_at}
                  precision={:second}
                />
              </:col>
              <:col :let={e} label="Reason">{e.reason}</:col>
            </.table>
          </.card>

          <.modal
            :if={@modal}
            id="sst-reason-modal"
            title={
              case @modal do
                "discard" -> "Discard this return"
                "amend" -> "Amend this return"
                "withdraw" -> "Withdraw this adjustment"
              end
            }
            on_cancel={JS.push("close_modal")}
          >
            <:description>
              {case @modal do
                "discard" ->
                  "It stays on record as discarded with this reason, and the period can be prepared again."

                "amend" ->
                  "A new return for the same period opens, naming this one; this one stays as it was finalised."

                "withdraw" ->
                  "It stays on record as withdrawn with this reason and no longer counts."
              end}
            </:description>
            <.form
              for={@reason_form}
              id="sst-reason-form"
              phx-change="reason_change"
              phx-submit="submit_reason"
              class="space-y-3"
            >
              <input
                :if={@reason_form[:adjustment_id].value}
                type="hidden"
                name="reason[adjustment_id]"
                value={@reason_form[:adjustment_id].value}
              />
              <.input
                field={@reason_form[:reason]}
                id="sst-reason"
                label="Reason"
                maxlength="500"
                required
              />
              <div class="flex gap-2">
                <.button type="submit" id="sst-reason-submit" variant="primary">Confirm</.button>
                <.button type="button" id="sst-reason-cancel" phx-click="close_modal">Cancel</.button>
              </div>
            </.form>
          </.modal>
        <% end %>
      </.page>
    </Layouts.app>
    """
  end
end
