defmodule Bilimbi.Finance.Reports.Web.AccountActivityLive do
  @moduledoc """
  The entries behind one account's figure in a report: the account's debits
  and credits over the report's window, and every entry counted, with the
  account's own amount in each, who posted it and when.

  A report links here with its window and entry number, so the totals equal
  the figure that was clicked and the list holds exactly the entries it
  counted, however much has been posted since.
  """

  use Bilimbi.Base.UI, :live_view

  import Bilimbi.Finance.Reports.Web.Figures

  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Finance.Reports

  @page_size 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Account entries")
     |> assign(:active_nav, "finance.reports")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    window = %{from: date(params["from"]), to: date(params["to"])}
    through = Params.positive_integer(params["through"])

    result =
      with {:ok, account_id} <- Params.positive_id(params["account_id"]) do
        Reports.account_activity(
          socket.assigns.current_scope.scope,
          socket.assigns.current_scope.user["company_id"],
          account_id,
          from: window.from,
          to: window.to,
          through_entry_number: through,
          limit: @page_size,
          after: cursor(params["after_date"], params["after_id"])
        )
      end

    case result do
      {:ok, activity} ->
        {:noreply,
         socket
         |> assign(:activity, activity)
         |> assign(:refusal, nil)
         |> assign(:page_title, "#{activity.account.code} #{activity.account.name}")}

      {:error, reason} ->
        {:noreply, socket |> assign(:activity, nil) |> assign(:refusal, reason)}

      :error ->
        {:noreply, socket |> assign(:activity, nil) |> assign(:refusal, :account_not_found)}
    end
  end

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp date(_value), do: nil

  defp cursor(date, id) do
    with %Date{} = date <- date(date),
         {:ok, id} <- Params.positive_id(id) do
      {date, id}
    else
      _missing -> nil
    end
  end

  defp next_path(activity) do
    last = List.last(activity.entries)

    query =
      %{
        "from" => activity.from && Date.to_iso8601(activity.from),
        "to" => activity.to && Date.to_iso8601(activity.to),
        "through" => activity.through_entry_number,
        "after_date" => Date.to_iso8601(last.entry_date),
        "after_id" => last.id
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/finance/reports/accounts/#{activity.account.id}?#{query}"
  end

  defp window_label(%{from: nil, to: nil}), do: "All entries"
  defp window_label(%{from: nil, to: to}), do: "Up to #{Date.to_iso8601(to)}"
  defp window_label(%{from: from, to: nil}), do: "From #{Date.to_iso8601(from)}"
  defp window_label(%{from: from, to: to}), do: column_label(%{from: from, to: to})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:detail}>
        <.back_link navigate={~p"/finance/reports"} title="Financial reports" />

        <%= if @activity do %>
          <.header>
            <span class="tabular-nums text-ink-muted">{@activity.account.code}</span>
            {@activity.account.name}
            <:subtitle>
              {type_label(@activity.account.account_type)} · {window_label(@activity)} ·
              <span id="activity-through">through entry {@activity.through_entry_number}</span>
            </:subtitle>
          </.header>

          <.list id="activity-totals">
            <:item title="Debits" id="activity-debits">
              <span class="tabular-nums">{amount(@activity.debits, @activity.minor_units)}</span>
            </:item>
            <:item title="Credits" id="activity-credits">
              <span class="tabular-nums">{amount(@activity.credits, @activity.minor_units)}</span>
            </:item>
            <:item title="Debits less credits" id="activity-net">
              <span class="tabular-nums">
                {amount(Decimal.sub(@activity.debits, @activity.credits), @activity.minor_units)}
                {@activity.currency_code}
              </span>
            </:item>
          </.list>

          <.card id="activity-entries-card" class="mt-4" inner_class="p-0">
            <.table
              id="activity-entries"
              rows={@activity.entries}
              row_id={&"activity-entry-#{&1.id}"}
              caption="Entries"
              framed={false}
            >
              <:col :let={entry} label="Entry" align={:right}>
                <span class="tabular-nums text-ink-muted">{entry.entry_number}</span>
              </:col>
              <:col :let={entry} label="Date">
                <span class="tabular-nums">{Date.to_iso8601(entry.entry_date)}</span>
              </:col>
              <:col :let={entry} label="Description">
                {entry.description}
                <span :if={entry.reverses_entry_id} class="text-ink-muted"> · reversal</span>
                <span :if={entry.reversed_by_entry_id} class="text-ink-muted"> · reversed</span>
              </:col>
              <:col :let={entry} label="Reference">{entry.reference}</:col>
              <:col :let={entry} label="Debit" align={:right}>
                <span class="tabular-nums">{amount(entry.debit, @activity.minor_units)}</span>
              </:col>
              <:col :let={entry} label="Credit" align={:right}>
                <span class="tabular-nums">{amount(entry.credit, @activity.minor_units)}</span>
              </:col>
              <:col :let={entry} label="Posted">
                <.datetime id={"activity-entry-#{entry.id}-posted"} value={entry.posted_at} />
                <span class="tabular-nums text-ink-muted">
                  by user {entry.posted_by_user_id}<span :if={entry.posted_by_impersonator_id}>, impersonated by user {entry.posted_by_impersonator_id}</span>
                </span>
              </:col>
              <:empty
                :if={@activity.entries == []}
                title="No entries"
                reason="No entry in this window posts to this account."
              />
            </.table>
          </.card>

          <div :if={@activity.more?} class="mt-3">
            <.button id="activity-next" navigate={next_path(@activity)}>Next entries</.button>
          </div>
        <% else %>
          <.empty_state
            :if={@refusal == :unauthorized}
            id="activity-refusal"
            forbidden="view the ledger"
          />
          <.empty_state
            :if={@refusal != :unauthorized}
            id="activity-refusal"
            title="Account not found"
            reason="This company's chart has no such account, or the link's options are not valid."
          />
        <% end %>
      </.page>
    </Layouts.app>
    """
  end
end
