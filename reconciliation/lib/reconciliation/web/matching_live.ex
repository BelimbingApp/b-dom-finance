defmodule Bilimbi.Finance.Reconciliation.Web.MatchingLive do
  @moduledoc """
  Matching for one bank account: the statement lines with no standing
  match beside the ledger entries on its account with none, each line's
  suggested entry, and a form that matches whatever is ticked on both
  sides, one or many each. Standing matches are listed and unmatched with
  a reason. Every write is a facade call that re-asks its capability.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Reconciliation
  alias Bilimbi.Finance.Reconciliation.Records
  alias Bilimbi.Finance.Reconciliation.Web.Format

  @zero Decimal.new(0)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope.scope
    company_id = Scope.actor(scope).company_id

    socket =
      socket
      |> assign(:page_title, "Matching")
      |> assign(:active_nav, "finance.reconciliation")
      |> assign(:company_id, company_id)
      |> assign(:bank_account_id, Params.positive_integer(id, 0))
      |> assign(:selected_lines, MapSet.new())
      |> assign(:selected_entries, MapSet.new())
      |> assign(:note, "")
      |> assign(:unmatching, nil)
      |> assign(:unmatch_form, to_form(%{"reason" => ""}, as: :unmatch))

    if connected?(socket), do: Ledger.subscribe_postings(scope, company_id)

    {:ok, load(socket)}
  end

  defp load(socket) do
    %{current_scope: %{scope: scope} = current_scope, company_id: company_id, bank_account_id: id} =
      socket.assigns

    with {:ok, account} <- Reconciliation.get_bank_account(scope, company_id, id),
         {:ok, unmatched} <- Reconciliation.unmatched_items(scope, company_id, id) do
      matches =
        case Records.all_pages(&Reconciliation.list_matches(scope, company_id, id, &1)) do
          {:ok, matches} -> matches |> Enum.filter(&(&1.status == "matched")) |> Enum.reverse()
          {:error, _reason} -> []
        end

      book =
        case Ledger.get_book(scope, company_id) do
          {:ok, book} -> book
          {:error, _reason} -> nil
        end

      line_ids = MapSet.new(unmatched.lines, & &1.id)
      entry_ids = MapSet.new(unmatched.entries, & &1.entry_id)

      socket
      |> assign(:account, account)
      |> assign(:refusal, nil)
      |> assign(:page_title, "#{account.name}: matching")
      |> assign(:lines, unmatched.lines)
      |> assign(:entries, unmatched.entries)
      |> assign(:suggestions, unmatched.suggestions)
      |> assign(:matches, matches)
      |> assign(:minor_units, (book && book.minor_units) || 2)
      |> assign(:selected_lines, MapSet.intersection(socket.assigns.selected_lines, line_ids))
      |> assign(
        :selected_entries,
        MapSet.intersection(socket.assigns.selected_entries, entry_ids)
      )
      |> assign(
        :can_match?,
        LiveAuthorization.allowed_now?(current_scope, Reconciliation.manage_matches_capability())
      )
    else
      {:error, reason} -> socket |> assign(:account, nil) |> assign(:refusal, reason)
    end
  end

  @impl true
  def handle_event("select", params, socket) do
    lines = params |> Map.get("lines", []) |> ids()
    entries = params |> Map.get("entries", []) |> ids()

    {:noreply,
     socket
     |> assign(:selected_lines, MapSet.new(lines))
     |> assign(:selected_entries, MapSet.new(entries))
     |> assign(:note, Map.get(params, "note", ""))}
  end

  def handle_event("match", params, socket) do
    case LiveAuthorization.authorize_event(socket, Reconciliation.manage_matches_capability()) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        {:noreply,
         match(socket, %{
           statement_line_ids: params |> Map.get("lines", []) |> ids(),
           entry_ids: params |> Map.get("entries", []) |> ids(),
           note: Map.get(params, "note", "")
         })}
    end
  end

  def handle_event("accept", %{"line" => line_id}, socket) do
    case LiveAuthorization.authorize_event(socket, Reconciliation.manage_matches_capability()) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        line_id = Params.positive_integer(line_id, 0)

        case Map.get(socket.assigns.suggestions, line_id) do
          nil ->
            {:noreply, put_flash(socket, :error, "That suggestion is no longer available.")}

          entry ->
            {:noreply,
             match(socket, %{
               statement_line_ids: [line_id],
               entry_ids: [entry.entry_id],
               note: "Suggested match"
             })}
        end
    end
  end

  def handle_event("unmatching", %{"id" => id}, socket) do
    match = Enum.find(socket.assigns.matches, &(to_string(&1.id) == id))

    {:noreply,
     socket
     |> assign(:unmatching, match)
     |> assign(:unmatch_form, to_form(%{"reason" => ""}, as: :unmatch))}
  end

  def handle_event("cancel_unmatch", _params, socket),
    do: {:noreply, assign(socket, :unmatching, nil)}

  def handle_event("unmatch_change", %{"unmatch" => params}, socket),
    do: {:noreply, assign(socket, :unmatch_form, to_form(params, as: :unmatch))}

  def handle_event("unmatch", %{"unmatch" => params}, socket) do
    case LiveAuthorization.authorize_event(socket, Reconciliation.manage_matches_capability()) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, %{assigns: %{unmatching: nil}} = socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        case Reconciliation.unmatch(
               socket.assigns.current_scope.scope,
               socket.assigns.company_id,
               socket.assigns.unmatching.id,
               %{reason: params["reason"]}
             ) do
          {:ok, match} ->
            {:noreply,
             socket
             |> put_flash(
               :success,
               "Match #{match.match_number} unmatched; its lines and entries are free again."
             )
             |> assign(:unmatching, nil)
             |> load()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:unmatch_form, to_form(params, as: :unmatch))
             |> put_flash(:error, Format.refusal(reason))}
        end
    end
  end

  # A posting on the account changes the ledger side; the notice carries no
  # figures, so the page reads again through the facade.
  @impl true
  def handle_info({:finance_ledger_posted, _notice}, socket) do
    drain_notices()
    {:noreply, load(socket)}
  end

  defp drain_notices do
    receive do
      {:finance_ledger_posted, _notice} -> drain_notices()
    after
      0 -> :ok
    end
  end

  defp match(socket, attributes) do
    case Reconciliation.match(
           socket.assigns.current_scope.scope,
           socket.assigns.company_id,
           socket.assigns.bank_account_id,
           attributes
         ) do
      {:ok, match} ->
        socket
        |> put_flash(
          :success,
          "Match #{match.match_number} made: #{length(match.statement_line_ids)} statement #{plural(length(match.statement_line_ids), "line")} with #{length(match.entries)} #{plural(length(match.entries), "entry", "entries")}."
        )
        |> assign(:selected_lines, MapSet.new())
        |> assign(:selected_entries, MapSet.new())
        |> assign(:note, "")
        |> load()

      {:error, reason} ->
        socket |> put_flash(:error, Format.refusal(reason)) |> load()
    end
  end

  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural
  defp plural(count, singular), do: plural(count, singular, singular <> "s")

  defp ids(values) when is_list(values),
    do: values |> Enum.map(&Params.positive_integer/1) |> Enum.reject(&is_nil/1)

  defp ids(_values), do: []

  defp selected_sum(items, selected, key, amount_key) do
    items
    |> Enum.filter(&MapSet.member?(selected, Map.fetch!(&1, key)))
    |> Enum.reduce(@zero, &Decimal.add(Map.fetch!(&1, amount_key), &2))
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        statement_sum: selected_sum(assigns.lines || [], assigns.selected_lines, :id, :amount),
        ledger_sum:
          selected_sum(assigns.entries || [], assigns.selected_entries, :entry_id, :amount)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="matching" variant={:detail}>
        <.back_link
          id="matching-back"
          navigate={
            if @account,
              do: ~p"/finance/reconciliation/accounts/#{@account.id}",
              else: ~p"/finance/reconciliation"
          }
          title={if @account, do: @account.name, else: "Bank accounts"}
        />

        <.empty_state
          :if={@refusal}
          id="matching-refusal"
          title="Matching unavailable"
          reason={Format.refusal(@refusal)}
        />

        <%= if @account do %>
          <.header>
            {@account.name}: matching
            <:subtitle>
              Tick statement lines and ledger entries whose amounts agree, then match them; or accept a suggestion.
            </:subtitle>
          </.header>

          <.empty_state :if={!@can_match?} id="matching-forbidden" forbidden="match statement lines" />

          <.form for={%{}} id="matching-form" phx-change="select" phx-submit="match">
            <div class="grid gap-4 lg:grid-cols-2">
              <.card
                id="unmatched-lines"
                inner_class="p-0"
                role="region"
                aria-labelledby="unmatched-lines-heading"
              >
                <.section_heading
                  id="unmatched-lines-heading"
                  title="Statement lines not in the books"
                  count={length(@lines)}
                  class="p-5 pb-0"
                />
                <.table
                  id="unmatched-lines-table"
                  rows={@lines}
                  framed={false}
                  row_id={&"line-#{&1.id}"}
                >
                  <:col :let={line} label="">
                    <input
                      :if={@can_match?}
                      type="checkbox"
                      name="lines[]"
                      value={line.id}
                      id={"line-#{line.id}-select"}
                      checked={MapSet.member?(@selected_lines, line.id)}
                      aria-label={"Select statement line #{line.description}"}
                    />
                  </:col>
                  <:col :let={line} label="Date">{line.line_date}</:col>
                  <:col :let={line} label="Description">
                    {line.description}
                    <span :if={line.reference} class="block text-xs text-ink-muted">{line.reference}</span>
                  </:col>
                  <:col :let={line} label="Amount" align={:right}>
                    <span class="tabular-nums">{Format.money(line.amount, @minor_units)}</span>
                  </:col>
                  <:col :let={line} label="Suggested">
                    <%= if suggestion = @suggestions[line.id] do %>
                      <span id={"line-#{line.id}-suggestion"}>Entry {suggestion.entry_number} on {suggestion.entry_date}</span>
                      <.button
                        :if={@can_match?}
                        type="button"
                        id={"line-#{line.id}-accept"}
                        phx-click="accept"
                        phx-value-line={line.id}
                      >
                        Accept
                      </.button>
                    <% end %>
                  </:col>
                  <:empty
                    title="Every statement line is matched"
                    reason="Import the next statement to continue."
                  />
                </.table>
              </.card>

              <.card
                id="unmatched-entries"
                inner_class="p-0"
                role="region"
                aria-labelledby="unmatched-entries-heading"
              >
                <.section_heading
                  id="unmatched-entries-heading"
                  title="Ledger entries not on a statement"
                  count={length(@entries)}
                  class="p-5 pb-0"
                />
                <.table
                  id="unmatched-entries-table"
                  rows={@entries}
                  framed={false}
                  row_id={&"entry-#{&1.entry_id}"}
                >
                  <:col :let={entry} label="">
                    <input
                      :if={@can_match?}
                      type="checkbox"
                      name="entries[]"
                      value={entry.entry_id}
                      id={"entry-#{entry.entry_id}-select"}
                      checked={MapSet.member?(@selected_entries, entry.entry_id)}
                      aria-label={"Select entry #{entry.entry_number}"}
                    />
                  </:col>
                  <:col :let={entry} label="Entry">{entry.entry_number}</:col>
                  <:col :let={entry} label="Date">{entry.entry_date}</:col>
                  <:col :let={entry} label="Description">
                    {entry.description}
                    <span :if={entry.reference} class="block text-xs text-ink-muted">{entry.reference}</span>
                  </:col>
                  <:col :let={entry} label="Amount" align={:right}>
                    <span class="tabular-nums">{Format.money(entry.amount, @minor_units)}</span>
                  </:col>
                  <:empty
                    title="Every entry on this account is matched"
                    reason="Entries posted to the bank account appear here until a statement line matches them."
                  />
                </.table>
              </.card>
            </div>

            <.card :if={@can_match?} id="match-selected" inner_class="p-5 sm:p-6" class="mt-4">
              <div class="flex flex-wrap items-end gap-4">
                <p class="text-sm">
                  Selected: <span id="selected-lines-count">{MapSet.size(@selected_lines)}</span>
                  lines totalling <span id="selected-lines-sum" class="tabular-nums">{Format.money(@statement_sum, @minor_units)}</span>,
                  <span id="selected-entries-count">{MapSet.size(@selected_entries)}</span>
                  entries totalling <span id="selected-entries-sum" class="tabular-nums">{Format.money(@ledger_sum, @minor_units)}</span>.
                </p>
                <.input
                  type="text"
                  name="note"
                  id="match-note"
                  value={@note}
                  label="Note"
                  maxlength="500"
                  wrapper_class="mb-0 grow"
                />
                <.button type="submit" id="match-selected-submit" variant="primary">Match selected</.button>
              </div>
            </.card>
          </.form>

          <.card
            id="standing-matches"
            inner_class="p-0"
            class="mt-4"
            role="region"
            aria-labelledby="standing-matches-heading"
          >
            <.section_heading
              id="standing-matches-heading"
              title="Standing matches"
              count={length(@matches)}
              class="p-5 pb-0"
            />
            <.table
              id="standing-matches-table"
              rows={@matches}
              framed={false}
              row_id={&"match-#{&1.id}"}
            >
              <:col :let={match} label="Match">{match.match_number}</:col>
              <:col :let={match} label="Statement lines">{length(match.statement_line_ids)}</:col>
              <:col :let={match} label="Entries">
                {Enum.map_join(match.entries, ", ", &"#{&1.entry_number}")}
              </:col>
              <:col :let={match} label="Amount" align={:right}>
                <span class="tabular-nums">
                  {Format.money(
                    Enum.reduce(match.entries, Decimal.new(0), &Decimal.add(&1.amount, &2)),
                    @minor_units
                  )}
                </span>
              </:col>
              <:col :let={match} label="Note">{match.note}</:col>
              <:col :let={match} label="Matched">
                <.datetime id={"match-#{match.id}-at"} value={match.matched_at} />
              </:col>
              <:action :let={match}>
                <.button
                  :if={@can_match?}
                  id={"match-#{match.id}-unmatch"}
                  phx-click="unmatching"
                  phx-value-id={match.id}
                >
                  Unmatch
                </.button>
              </:action>
              <:empty
                title="No standing matches"
                reason="Matches made above are listed here and can be unmatched with a reason."
              />
            </.table>
          </.card>

          <.modal
            :if={@unmatching}
            id="unmatch-modal"
            title={"Unmatch match #{@unmatching.match_number}"}
            on_cancel={JS.push("cancel_unmatch")}
          >
            <:description>
              Its statement lines and ledger entries become unmatched again; the match and this reason stay on record.
            </:description>
            <.form
              for={@unmatch_form}
              id="unmatch-form"
              phx-change="unmatch_change"
              phx-submit="unmatch"
              class="space-y-3"
            >
              <.input
                field={@unmatch_form[:reason]}
                id="unmatch-reason"
                label="Reason"
                maxlength="500"
                required
              />
              <div class="flex gap-2">
                <.button type="submit" id="unmatch-submit" variant="danger">Unmatch</.button>
                <.button type="button" id="unmatch-cancel" phx-click="cancel_unmatch">Cancel</.button>
              </div>
            </.form>
          </.modal>
        <% end %>
      </.page>
    </Layouts.app>
    """
  end
end
