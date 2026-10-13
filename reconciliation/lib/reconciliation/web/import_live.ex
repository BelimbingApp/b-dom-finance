defmodule Bilimbi.Finance.Reconciliation.Web.ImportLive do
  @moduledoc """
  One bank account: its statements, each with a link to the bank's file it
  was read from, the form that imports the next one from the bank's CSV
  export, and its reconciliations with the form that opens the next. The
  import reads the uploaded file once and hands its bytes to the facade,
  which refuses a file or a line already imported and keeps the file whole
  as the statement's source document. Every write re-asks its capability.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Finance.Attachments
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Reconciliation
  alias Bilimbi.Finance.Reconciliation.Csv
  alias Bilimbi.Finance.Reconciliation.Records
  alias Bilimbi.Finance.Reconciliation.Web.Format

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope.scope

    {:ok,
     socket
     |> assign(:page_title, "Bank statements")
     |> assign(:active_nav, "finance.reconciliation")
     |> assign(:company_id, Scope.actor(scope).company_id)
     |> assign(:bank_account_id, Params.positive_integer(id, 0))
     |> assign(
       :reconciliation_form,
       to_form(%{"end_date" => "", "statement_balance" => ""}, as: :reconciliation)
     )
     |> allow_upload(:statement,
       accept: ~w(.csv .txt text/csv text/plain),
       max_entries: 1,
       max_file_size: Csv.max_bytes()
     )
     |> load()}
  end

  defp load(socket) do
    %{current_scope: %{scope: scope} = current_scope, company_id: company_id, bank_account_id: id} =
      socket.assigns

    case Reconciliation.get_bank_account(scope, company_id, id) do
      {:ok, account} ->
        statements =
          items(Records.all_pages(&Reconciliation.list_statements(scope, company_id, id, &1)))

        reconciliations = items(Reconciliation.list_reconciliations(scope, company_id, id))
        files = statement_files(scope, company_id)

        book =
          case Ledger.get_book(scope, company_id) do
            {:ok, book} -> book
            {:error, _reason} -> nil
          end

        socket
        |> assign(:account, account)
        |> assign(:refusal, nil)
        |> assign(:page_title, account.name)
        |> assign(:statements, Enum.reverse(statements))
        |> assign(:files, files)
        |> assign(:reconciliations, Enum.reverse(reconciliations))
        |> assign(:minor_units, (book && book.minor_units) || 2)
        |> assign(
          :can_import?,
          LiveAuthorization.allowed_now?(
            current_scope,
            Reconciliation.import_statements_capability()
          )
        )
        |> assign(
          :can_open?,
          LiveAuthorization.allowed_now?(
            current_scope,
            Reconciliation.manage_reconciliations_capability()
          )
        )
        |> suggest_reconciliation(statements, reconciliations)

      {:error, reason} ->
        socket |> assign(:account, nil) |> assign(:refusal, reason)
    end
  end

  defp items({:ok, items}), do: items
  defp items({:error, _reason}), do: []

  # The next reconciliation ends where the latest statement ends, at the
  # balance it closed with, unless the form already holds a draft.
  defp suggest_reconciliation(socket, statements, reconciliations) do
    form = socket.assigns.reconciliation_form

    if form.params["end_date"] in [nil, ""] and Enum.all?(reconciliations, &(&1.status != "open")) do
      case List.last(statements) do
        nil ->
          socket

        statement ->
          assign(
            socket,
            :reconciliation_form,
            to_form(
              %{
                "end_date" => Date.to_iso8601(statement.end_date),
                "statement_balance" =>
                  if(statement.closing_balance,
                    do:
                      statement.closing_balance
                      |> Decimal.normalize()
                      |> Decimal.to_string(:normal),
                    else: ""
                  )
              },
              as: :reconciliation
            )
          )
      end
    else
      socket
    end
  end

  @impl true
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :statement, ref)}

  def handle_event("import", _params, socket) do
    case LiveAuthorization.authorize_event(socket, Reconciliation.import_statements_capability()) do
      {:denied, socket} -> {:noreply, socket}
      {:ok, socket} -> {:noreply, import_file(socket)}
    end
  end

  def handle_event("reconciliation_change", %{"reconciliation" => params}, socket),
    do: {:noreply, assign(socket, :reconciliation_form, to_form(params, as: :reconciliation))}

  def handle_event("open_reconciliation", %{"reconciliation" => params}, socket) do
    case LiveAuthorization.authorize_event(
           socket,
           Reconciliation.manage_reconciliations_capability()
         ) do
      {:denied, socket} -> {:noreply, socket}
      {:ok, socket} -> {:noreply, open_reconciliation(socket, params)}
    end
  end

  # The standing source document of each statement, by statement ID, for
  # the download link; a statement imported before files were kept has none.
  defp statement_files(scope, company_id) do
    case Attachments.list_company_attachments(scope, company_id,
           source: Reconciliation.StatementSource.source_id(),
           limit: 500
         ) do
      {:ok, attachments} -> Map.new(attachments, &{&1.document_id, &1})
      {:error, _reason} -> %{}
    end
  end

  # The uploaded bytes are read once, here, and handed to the facade, which
  # keeps the file as the statement's source document.
  defp import_file(socket) do
    files =
      consume_uploaded_entries(socket, :statement, fn %{path: path}, entry ->
        {:ok,
         %{
           file_name: entry.client_name,
           content: File.read!(path),
           content_type: entry.client_type
         }}
      end)

    case files do
      [] ->
        put_flash(socket, :error, "Choose the bank's CSV file first.")

      [file] ->
        case Reconciliation.import_statement(
               socket.assigns.current_scope.scope,
               socket.assigns.company_id,
               socket.assigns.bank_account_id,
               file
             ) do
          {:ok, statement} ->
            skipped =
              if statement.skipped_count > 0,
                do: " #{statement.skipped_count} zero-amount rows were skipped.",
                else: ""

            socket
            |> put_flash(
              :success,
              "Statement #{statement.statement_number} imported: #{statement.line_count} lines from #{statement.start_date} to #{statement.end_date}.#{skipped}"
            )
            |> load()

          {:error, reason} ->
            put_flash(socket, :error, Format.refusal(reason))
        end
    end
  end

  defp open_reconciliation(socket, params) do
    attributes = %{
      end_date: date(params["end_date"]),
      statement_balance: params["statement_balance"]
    }

    case Reconciliation.open_reconciliation(
           socket.assigns.current_scope.scope,
           socket.assigns.company_id,
           socket.assigns.bank_account_id,
           attributes
         ) do
      {:ok, reconciliation} ->
        socket
        |> put_flash(:success, "Reconciliation #{reconciliation.reconciliation_number} opened.")
        |> push_navigate(to: ~p"/finance/reconciliation/reconciliations/#{reconciliation.id}")

      {:error, reason} ->
        socket
        |> assign(:reconciliation_form, to_form(params, as: :reconciliation))
        |> put_flash(:error, Format.refusal(reason))
    end
  end

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp date(_value), do: nil

  defp status_kind("open"), do: :warning
  defp status_kind("finalised"), do: :success
  defp status_kind("abandoned"), do: :neutral

  defp upload_error(:too_large), do: "The file is larger than the import allows."
  defp upload_error(:not_accepted), do: "Choose a CSV file."
  defp upload_error(:too_many_files), do: "Choose one file at a time."
  defp upload_error(error), do: "The file could not be uploaded (#{inspect(error)})."

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="bank-account" variant={:detail}>
        <.back_link
          id="bank-account-back"
          navigate={~p"/finance/reconciliation"}
          title="Bank accounts"
        />

        <.empty_state
          :if={@refusal}
          id="bank-account-refusal"
          title="Bank account unavailable"
          reason={Format.refusal(@refusal)}
        />

        <%= if @account do %>
          <.header>
            {@account.name}
            <:subtitle>Statements imported for this account and its reconciliations.</:subtitle>
            <:actions>
              <.link
                id="bank-account-matching"
                navigate={~p"/finance/reconciliation/accounts/#{@account.id}/matching"}
              >
                Match statement lines
              </.link>
            </:actions>
          </.header>

          <.card
            id="statement-import"
            inner_class="p-5 sm:p-6"
            role="region"
            aria-labelledby="statement-import-heading"
          >
            <.section_heading id="statement-import-heading" title="Import a statement">
              <:description>
                The bank's CSV export, read with this account's mapping: {@account.import_mapping[
                  "description"
                ]} as the description, {@account.import_mapping["amount"] ||
                  "#{@account.import_mapping["debit"]} and #{@account.import_mapping["credit"]}"} as the amount{if @account.import_mapping[
                                                                                                                     "balance"
                                                                                                                   ],
                                                                                                                   do:
                                                                                                                     ", #{@account.import_mapping["balance"]} as the running balance"}. A file or a line already imported is refused.
              </:description>
            </.section_heading>

            <.empty_state
              :if={!@can_import?}
              id="statement-import-forbidden"
              forbidden="import statements"
            />

            <.form
              :if={@can_import?}
              for={%{}}
              id="statement-import-form"
              phx-change="validate_upload"
              phx-submit="import"
              class="mt-4 space-y-3"
            >
              <.live_file_input upload={@uploads.statement} class="block text-sm" />
              <div
                :for={entry <- @uploads.statement.entries}
                id={"statement-upload-#{entry.ref}"}
                class="text-sm"
              >
                {entry.client_name} · {entry.progress}%
                <.button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  aria-label="Cancel upload"
                >Remove</.button>
                <p :for={error <- upload_errors(@uploads.statement, entry)} class="text-danger">
                  {upload_error(error)}
                </p>
              </div>
              <p :for={error <- upload_errors(@uploads.statement)} class="text-sm text-danger">
                {upload_error(error)}
              </p>
              <.button
                type="submit"
                id="statement-import-submit"
                variant="primary"
                phx-disable-with="Importing…"
              >
                Import statement
              </.button>
            </.form>
          </.card>

          <.card id="statements" inner_class="p-0" role="region" aria-labelledby="statements-heading">
            <.section_heading
              id="statements-heading"
              title="Statements"
              count={length(@statements)}
              class="p-5 pb-0"
            />
            <.table
              id="statements-table"
              rows={@statements}
              framed={false}
              row_id={&"statement-#{&1.id}"}
            >
              <:col :let={statement} label="Number">{statement.statement_number}</:col>
              <:col :let={statement} label="File">
                <%= if file = @files[statement.id] do %>
                  <.link
                    id={"statement-#{statement.id}-file"}
                    href={~p"/finance/attachments/#{file.id}/download"}
                    download={statement.file_name}
                    title={"SHA-256 #{statement.file_sha256}"}
                  >
                    {statement.file_name}
                  </.link>
                <% else %>
                  <span title={"SHA-256 #{statement.file_sha256}; the file itself was not kept"}>
                    {statement.file_name}
                  </span>
                <% end %>
              </:col>
              <:col :let={statement} label="From">{statement.start_date}</:col>
              <:col :let={statement} label="To">{statement.end_date}</:col>
              <:col :let={statement} label="Lines" align={:right}>{statement.line_count}</:col>
              <:col :let={statement} label="Opening" align={:right}>
                <span class="tabular-nums">{Format.money(statement.opening_balance, @minor_units)}</span>
              </:col>
              <:col :let={statement} label="Closing" align={:right}>
                <span class="tabular-nums">{Format.money(statement.closing_balance, @minor_units)}</span>
              </:col>
              <:col :let={statement} label="Imported">
                <.datetime id={"statement-#{statement.id}-imported"} value={statement.imported_at} />
              </:col>
              <:empty title="No statements yet" reason="Import the bank's first CSV export above." />
            </.table>
          </.card>

          <.card
            id="reconciliations"
            inner_class="p-0"
            role="region"
            aria-labelledby="reconciliations-heading"
          >
            <.section_heading
              id="reconciliations-heading"
              title="Reconciliations"
              count={length(@reconciliations)}
              class="p-5 pb-0"
            />
            <.table
              id="reconciliations-table"
              rows={@reconciliations}
              framed={false}
              row_id={&"reconciliation-#{&1.id}"}
            >
              <:col :let={reconciliation} label="Number">
                <.link
                  navigate={~p"/finance/reconciliation/reconciliations/#{reconciliation.id}"}
                  class="font-medium text-ink-strong hover:underline"
                >
                  Reconciliation {reconciliation.reconciliation_number}
                </.link>
              </:col>
              <:col :let={reconciliation} label="As of">{reconciliation.end_date}</:col>
              <:col :let={reconciliation} label="Statement balance" align={:right}>
                <span class="tabular-nums">{Format.money(
                  reconciliation.statement_balance,
                  @minor_units
                )}</span>
              </:col>
              <:col :let={reconciliation} label="Status">
                <.badge kind={status_kind(reconciliation.status)}>{reconciliation.status}</.badge>
              </:col>
              <:empty
                title="No reconciliations yet"
                reason="Open the first one below once a statement is imported."
              />
            </.table>

            <div class="p-5">
              <.empty_state
                :if={!@can_open?}
                id="reconciliation-open-forbidden"
                forbidden="open reconciliations"
              />
              <.form
                :if={@can_open?}
                for={@reconciliation_form}
                id="reconciliation-open-form"
                phx-change="reconciliation_change"
                phx-submit="open_reconciliation"
                class="grid gap-x-6 md:grid-cols-3 md:items-end"
              >
                <.input
                  field={@reconciliation_form[:end_date]}
                  id="reconciliation-end-date"
                  type="date"
                  label="Statement end date"
                  required
                />
                <.input
                  field={@reconciliation_form[:statement_balance]}
                  id="reconciliation-statement-balance"
                  label="Balance per statement"
                  required
                />
                <div class="mb-4">
                  <.button type="submit" id="reconciliation-open" variant="primary">Open reconciliation</.button>
                </div>
              </.form>
            </div>
          </.card>
        <% end %>
      </.page>
    </Layouts.app>
    """
  end
end
