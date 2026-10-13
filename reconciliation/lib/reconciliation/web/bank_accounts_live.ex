defmodule Bilimbi.Finance.Reconciliation.Web.BankAccountsLive do
  @moduledoc """
  The company's bank accounts for reconciliation: each mapped to a ledger
  account, with the accounts its charges and interest post to and the
  mapping its bank's CSV export is read with. The form adds an account or
  changes one; every write is a facade call that re-asks its capability,
  and the change log the facade keeps is shown per account.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Reconciliation
  alias Bilimbi.Finance.Reconciliation.Web.Format

  @mapping_fields ~w(delimiter header_rows date date_format description reference amount amount_sign debit credit balance decimal_separator)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope.scope

    {:ok,
     socket
     |> assign(:page_title, "Bank reconciliation")
     |> assign(:active_nav, "finance.reconciliation")
     |> assign(:company_id, Scope.actor(scope).company_id)
     |> assign(:choices, Reconciliation.mapping_choices())
     |> assign(:editing, nil)
     |> assign(:form, blank_form())
     |> load()}
  end

  defp load(socket) do
    %{current_scope: %{scope: scope}, company_id: company_id} = socket.assigns

    accounts =
      case Reconciliation.list_bank_accounts(scope, company_id) do
        {:ok, accounts} -> accounts
        {:error, _reason} -> nil
      end

    chart =
      case Ledger.list_accounts(scope, company_id) do
        {:ok, chart} -> chart
        {:error, _reason} -> nil
      end

    socket
    |> assign(:accounts, accounts)
    |> assign(:chart, chart)
    |> assign(:chart_by_id, Map.new(chart || [], &{&1.id, &1}))
    |> assign(
      :can_manage?,
      LiveAuthorization.allowed_now?(
        socket.assigns.current_scope,
        Reconciliation.manage_bank_accounts_capability()
      )
    )
  end

  defp blank_form do
    to_form(
      %{
        "name" => "",
        "ledger_account_id" => "",
        "charges_account_id" => "",
        "interest_account_id" => "",
        "match_window_days" => "5",
        "delimiter" => ",",
        "header_rows" => "1",
        "date" => "",
        "date_format" => "YYYY-MM-DD",
        "description" => "",
        "reference" => "",
        "amount" => "",
        "amount_sign" => "deposits_positive",
        "debit" => "",
        "credit" => "",
        "balance" => "",
        "decimal_separator" => ".",
        "reason" => ""
      },
      as: :bank_account
    )
  end

  defp edit_form(account) do
    mapping = account.import_mapping

    to_form(
      %{
        "name" => account.name,
        "ledger_account_id" => to_string(account.ledger_account_id),
        "charges_account_id" => to_string(account.charges_account_id || ""),
        "interest_account_id" => to_string(account.interest_account_id || ""),
        "match_window_days" => to_string(account.match_window_days),
        "delimiter" => mapping["delimiter"],
        "header_rows" => to_string(mapping["header_rows"]),
        "date" => to_string(mapping["date"]),
        "date_format" => mapping["date_format"],
        "description" => to_string(mapping["description"]),
        "reference" => to_string(mapping["reference"] || ""),
        "amount" => to_string(mapping["amount"] || ""),
        "amount_sign" => mapping["amount_sign"],
        "debit" => to_string(mapping["debit"] || ""),
        "credit" => to_string(mapping["credit"] || ""),
        "balance" => to_string(mapping["balance"] || ""),
        "decimal_separator" => mapping["decimal_separator"],
        "reason" => ""
      },
      as: :bank_account
    )
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.accounts || [], &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      account ->
        {:noreply, socket |> assign(:editing, account) |> assign(:form, edit_form(account))}
    end
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, socket |> assign(:editing, nil) |> assign(:form, blank_form())}

  def handle_event("change", %{"bank_account" => params}, socket),
    do: {:noreply, assign(socket, :form, to_form(params, as: :bank_account))}

  def handle_event("save", %{"bank_account" => params}, socket) do
    case LiveAuthorization.authorize_event(
           socket,
           Reconciliation.manage_bank_accounts_capability()
         ) do
      {:denied, socket} -> {:noreply, socket}
      {:ok, socket} -> {:noreply, save(socket, params)}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    case LiveAuthorization.authorize_event(
           socket,
           Reconciliation.manage_bank_accounts_capability()
         ) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        account = Enum.find(socket.assigns.accounts || [], &(to_string(&1.id) == id))

        result =
          account &&
            Reconciliation.update_bank_account(
              socket.assigns.current_scope.scope,
              socket.assigns.company_id,
              account.id,
              %{active: not account.active}
            )

        case result do
          {:ok, changed} ->
            {:noreply,
             socket
             |> put_flash(
               :success,
               "#{changed.name} is now #{if changed.active, do: "active", else: "inactive"}."
             )
             |> load()}

          {:error, reason} ->
            {:noreply, socket |> put_flash(:error, Format.refusal(reason)) |> load()}

          nil ->
            {:noreply, socket}
        end
    end
  end

  defp save(socket, params) do
    %{current_scope: %{scope: scope}, company_id: company_id, editing: editing} = socket.assigns
    attributes = attributes(params)

    result =
      if editing,
        do: Reconciliation.update_bank_account(scope, company_id, editing.id, attributes),
        else: Reconciliation.create_bank_account(scope, company_id, attributes)

    case result do
      {:ok, account} ->
        socket
        |> put_flash(
          :success,
          "Bank account #{account.name} #{if editing, do: "changed", else: "added"}."
        )
        |> assign(:editing, nil)
        |> assign(:form, blank_form())
        |> load()

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> assign(:form, form_with_errors(params, changeset))
        |> put_flash(:error, Format.refusal(changeset))

      {:error, reason} ->
        socket
        |> assign(:form, to_form(params, as: :bank_account))
        |> put_flash(:error, Format.refusal(reason))
    end
  end

  # Mapping errors land on the form's mapping fields as one message; the
  # other errors on their own fields.
  defp form_with_errors(params, changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, _options} -> message end)
      |> Enum.flat_map(fn
        {:import_mapping, messages} -> Enum.map(messages, &{:date, &1})
        {field, messages} -> Enum.map(messages, &{field, &1})
      end)
      |> Enum.map(fn {field, message} -> {field, {message, []}} end)

    to_form(params, as: :bank_account, errors: errors)
  end

  defp attributes(params) do
    mapping =
      for key <- @mapping_fields, into: %{} do
        {key, mapping_value(key, Map.get(params, key))}
      end

    %{
      name: params["name"],
      ledger_account_id: integer(params["ledger_account_id"]),
      charges_account_id: integer(params["charges_account_id"]),
      interest_account_id: integer(params["interest_account_id"]),
      match_window_days: integer(params["match_window_days"]),
      import_mapping: mapping,
      reason: params["reason"]
    }
  end

  # A column is its header, or its position when the file has no header.
  defp mapping_value("header_rows", value), do: integer(value)

  defp mapping_value(key, value)
       when key in ~w(date description reference amount debit credit balance) do
    case String.trim(value || "") do
      "" ->
        nil

      trimmed ->
        case Integer.parse(trimmed) do
          {position, ""} when position > 0 -> position
          _header -> trimmed
        end
    end
  end

  defp mapping_value(_key, value), do: blank_to_nil(value)

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp integer(_value), do: nil

  defp chart_options(nil, _type), do: []

  defp chart_options(chart, type) do
    for account <- chart, account.account_type == type, account.active do
      {"#{account.code} #{account.name}", account.id}
    end
  end

  defp account_label(_chart_by_id, nil), do: "—"

  defp account_label(chart_by_id, id) do
    case Map.get(chart_by_id, id) do
      nil -> "##{id}"
      account -> "#{account.code} #{account.name}"
    end
  end

  defp delimiter_label(","), do: "Comma"
  defp delimiter_label(";"), do: "Semicolon"
  defp delimiter_label("\t"), do: "Tab"
  defp delimiter_label("|"), do: "Pipe"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="bank-accounts">
        <.header>
          Bank reconciliation
          <:subtitle>
            Bank accounts, each mapped to a ledger account, with the column mapping their statements import with.
          </:subtitle>
        </.header>

        <.empty_state
          :if={is_nil(@accounts)}
          id="bank-accounts-forbidden"
          forbidden="view bank reconciliation"
        />

        <.card
          :if={@accounts}
          id="bank-accounts-list"
          inner_class="p-0"
          role="region"
          aria-labelledby="bank-accounts-heading"
        >
          <.section_heading id="bank-accounts-heading" title="Bank accounts" class="p-5 pb-0" />
          <.table
            id="bank-accounts-table"
            rows={@accounts}
            framed={false}
            row_id={&"bank-account-#{&1.id}"}
          >
            <:col :let={account} label="Name">
              <.link
                navigate={~p"/finance/reconciliation/accounts/#{account.id}"}
                class="font-medium text-ink-strong hover:underline"
              >
                {account.name}
              </.link>
            </:col>
            <:col :let={account} label="Ledger account">
              {account_label(@chart_by_id, account.ledger_account_id)}
            </:col>
            <:col :let={account} label="Charges to">
              {account_label(@chart_by_id, account.charges_account_id)}
            </:col>
            <:col :let={account} label="Interest to">
              {account_label(@chart_by_id, account.interest_account_id)}
            </:col>
            <:col :let={account} label="Window">{account.match_window_days} days</:col>
            <:col :let={account} label="Status">
              <.badge kind={if account.active, do: :success, else: :neutral}>
                {if account.active, do: "active", else: "inactive"}
              </.badge>
            </:col>
            <:action :let={account}>
              <.link
                id={"bank-account-#{account.id}-matching"}
                navigate={~p"/finance/reconciliation/accounts/#{account.id}/matching"}
              >
                Matching
              </.link>
              <.button
                :if={@can_manage?}
                id={"bank-account-#{account.id}-edit"}
                phx-click="edit"
                phx-value-id={account.id}
              >
                Edit
              </.button>
              <.button
                :if={@can_manage?}
                id={"bank-account-#{account.id}-toggle"}
                phx-click="toggle_active"
                phx-value-id={account.id}
              >
                {if account.active, do: "Deactivate", else: "Activate"}
              </.button>
            </:action>
            <:empty
              title="No bank accounts yet"
              reason="Add the first bank account below to start importing its statements."
            />
          </.table>
        </.card>

        <.empty_state
          :if={@accounts && is_nil(@chart)}
          id="bank-accounts-chart-forbidden"
          forbidden="view the ledger's chart of accounts, which a bank account is mapped to"
        />

        <.empty_state
          :if={@accounts && @chart && !@can_manage?}
          id="bank-accounts-manage-forbidden"
          forbidden="add or change bank accounts"
        />

        <.card
          :if={@accounts && @chart && @can_manage?}
          id="bank-account-form-card"
          inner_class="p-5 sm:p-6"
          role="region"
          aria-labelledby="bank-account-form-heading"
        >
          <.section_heading
            id="bank-account-form-heading"
            title={if @editing, do: "Change #{@editing.name}", else: "Add a bank account"}
          >
            <:description>
              Name the columns of the bank's CSV export by their header text, or by position (1, 2, ...) when the file has no header row.
            </:description>
          </.section_heading>

          <.form
            for={@form}
            id="bank-account-form"
            phx-change="change"
            phx-submit="save"
            class="mt-4 grid gap-x-6 gap-y-2 md:grid-cols-2"
          >
            <.input field={@form[:name]} id="bank-account-name" label="Name" maxlength="200" required />
            <.input
              :if={is_nil(@editing)}
              field={@form[:ledger_account_id]}
              id="bank-account-ledger-account"
              type="select"
              label="Ledger account (asset)"
              prompt="Choose an account"
              options={chart_options(@chart, "asset")}
              required
            />
            <div :if={@editing} class="mb-4 text-sm">
              <span class="block font-medium text-ink">Ledger account</span>
              <span id="bank-account-ledger-account-fixed">{account_label(
                @chart_by_id,
                @editing.ledger_account_id
              )} (never changes)</span>
            </div>
            <.input
              field={@form[:charges_account_id]}
              id="bank-account-charges-account"
              type="select"
              label="Bank charges post to (expense)"
              prompt="Not set"
              options={chart_options(@chart, "expense")}
            />
            <.input
              field={@form[:interest_account_id]}
              id="bank-account-interest-account"
              type="select"
              label="Interest posts to (income)"
              prompt="Not set"
              options={chart_options(@chart, "income")}
            />
            <.input
              field={@form[:match_window_days]}
              id="bank-account-window"
              type="number"
              min="0"
              max="90"
              label="Suggested match window (days)"
              hint="How far apart a statement line's and an entry's dates may be for a suggested match."
            />
            <.input
              field={@form[:delimiter]}
              id="bank-account-delimiter"
              type="select"
              label="Column separator"
              options={Enum.map(@choices.delimiters, &{delimiter_label(&1), &1})}
            />
            <.input
              field={@form[:header_rows]}
              id="bank-account-header-rows"
              type="number"
              min="0"
              max="20"
              label="Rows before the data"
              hint="The last of them is the header row; 0 when the file has none."
            />
            <.input field={@form[:date]} id="bank-account-date" label="Date column" required />
            <.input
              field={@form[:date_format]}
              id="bank-account-date-format"
              type="select"
              label="Date format"
              options={@choices.date_formats}
            />
            <.input
              field={@form[:description]}
              id="bank-account-description"
              label="Description column"
              required
            />
            <.input
              field={@form[:reference]}
              id="bank-account-reference"
              label="Reference column"
              hint="Optional."
            />
            <.input
              field={@form[:amount]}
              id="bank-account-amount"
              label="Amount column"
              hint="One signed column; leave blank when the file has debit and credit columns."
            />
            <.input
              field={@form[:amount_sign]}
              id="bank-account-amount-sign"
              type="select"
              label="Sign of the amount column"
              options={[
                {"Money in is positive", "deposits_positive"},
                {"Money out is positive", "withdrawals_positive"}
              ]}
            />
            <.input field={@form[:debit]} id="bank-account-debit" label="Debit column (money out)" />
            <.input field={@form[:credit]} id="bank-account-credit" label="Credit column (money in)" />
            <.input
              field={@form[:balance]}
              id="bank-account-balance"
              label="Running balance column"
              hint="Optional; with it, each import checks the balances follow from the amounts."
            />
            <.input
              field={@form[:decimal_separator]}
              id="bank-account-decimal-separator"
              type="select"
              label="Decimal separator"
              options={[{"Point (1,234.56)", "."}, {"Comma (1.234,56)", ","}]}
            />
            <.input
              :if={@editing}
              field={@form[:reason]}
              id="bank-account-reason"
              label="Reason for the change"
              maxlength="500"
              wrapper_class="md:col-span-2 mb-4"
            />
            <div class="flex gap-2 md:col-span-2">
              <.button type="submit" id="bank-account-save" variant="primary">
                {if @editing, do: "Save changes", else: "Add bank account"}
              </.button>
              <.button :if={@editing} type="button" id="bank-account-cancel" phx-click="cancel">Cancel</.button>
            </div>
          </.form>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
