defmodule Bilimbi.Finance.Reports.Web.BookkeepingLive do
  @moduledoc """
  The company's bookkeeping controls: whether it is controlled (an entry posts
  only into a fiscal period it has opened), the fiscal years it has opened
  (the first one is opened here, explicitly), and the entries recorded late
  with each independent review of them.

  The page reads the ledger's facade (`Bilimbi.Finance.Ledger`). Every change
  and review is a facade call that re-asks its own capability; the `can_*`
  assigns only decide which controls show.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Finance.Ledger

  @page_size 100
  @statuses ~w(all approaching late)
  @reviews ~w(all pending reviewed)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Bookkeeping")
     |> assign(:active_nav, "finance.reports.bookkeeping")
     |> assign(:page_size, @page_size)
     |> assign(:dialog, nil)
     |> assign(:reviewing, nil)
     |> assign(:text, "")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    state = %{
      status: if(params["status"] in @statuses, do: params["status"], else: "all"),
      review: if(params["review"] in @reviews, do: params["review"], else: "all"),
      after: Params.positive_integer(params["after"])
    }

    {:noreply, socket |> assign(:params, params) |> assign(:state, state) |> load()}
  end

  @impl true
  def handle_event("open_dialog", %{"dialog" => "review", "entry" => id}, socket) do
    {:noreply,
     socket
     |> clear_flash()
     |> assign(dialog: "review", reviewing: Params.positive_integer(id, 0), text: "")}
  end

  def handle_event("open_dialog", %{"dialog" => dialog}, socket) do
    {:noreply, socket |> clear_flash() |> assign(dialog: dialog, reviewing: nil, text: "")}
  end

  def handle_event("close_dialog", _params, socket) do
    {:noreply, assign(socket, dialog: nil, reviewing: nil, text: "")}
  end

  def handle_event("text", %{"dialog" => %{"text" => text}}, socket) do
    {:noreply, assign(socket, :text, text)}
  end

  def handle_event("turn_on", _params, socket) do
    case LiveAuthorization.authorize_event(
           socket,
           Ledger.manage_controlled_bookkeeping_capability()
         ) do
      {:denied, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        socket =
          case Ledger.set_controlled_bookkeeping(scope(socket), company_id(socket), %{
                 controlled: true
               }) do
            {:ok, _view} ->
              put_flash(
                socket,
                :success,
                "Bookkeeping is controlled: entries need an open fiscal period."
              )

            {:error, reason} ->
              put_flash(socket, :error, refusal_text(reason))
          end

        {:noreply, load(socket)}
    end
  end

  def handle_event("turn_off", %{"dialog" => %{"text" => reason}}, socket) do
    case LiveAuthorization.authorize_event(
           socket,
           Ledger.manage_controlled_bookkeeping_capability()
         ) do
      {:denied, socket} ->
        {:noreply, assign(socket, :dialog, nil)}

      {:ok, socket} ->
        socket =
          case Ledger.set_controlled_bookkeeping(scope(socket), company_id(socket), %{
                 controlled: false,
                 reason: reason
               }) do
            {:ok, _view} ->
              socket
              |> assign(dialog: nil, text: "")
              |> put_flash(
                :success,
                "Bookkeeping is not controlled; the change is listed as an override."
              )

            {:error, %Ecto.Changeset{}} ->
              put_flash(socket, :error, "Give a reason of 1 to 500 characters.")

            {:error, reason} ->
              socket |> assign(:dialog, nil) |> put_flash(:error, refusal_text(reason))
          end

        {:noreply, load(socket)}
    end
  end

  def handle_event("open_fiscal_year", %{"dialog" => fields}, socket) do
    case LiveAuthorization.authorize_event(socket, Ledger.manage_periods_capability()) do
      {:denied, socket} ->
        {:noreply, assign(socket, :dialog, nil)}

      {:ok, socket} ->
        socket =
          case fiscal_year_attributes(fields) do
            {:ok, attributes} ->
              case Ledger.open_fiscal_year(scope(socket), company_id(socket), attributes) do
                {:ok, year} ->
                  socket
                  |> assign(dialog: nil, text: "")
                  |> put_flash(
                    :success,
                    "Fiscal year #{year.start_date} to #{year.end_date} is open."
                  )

                {:error, %Ecto.Changeset{}} ->
                  put_flash(
                    socket,
                    :error,
                    "Check the fiscal year's dates: it starts on the first of a month and runs to the end of one, up to two years."
                  )

                {:error, reason} ->
                  socket |> assign(:dialog, nil) |> put_flash(:error, refusal_text(reason))
              end

            :error ->
              put_flash(socket, :error, "Give the first day of the fiscal year as a date.")
          end

        {:noreply, load(socket)}
    end
  end

  def handle_event("review", %{"dialog" => %{"text" => reason}}, socket) do
    case LiveAuthorization.authorize_event(socket, Ledger.review_late_recordings_capability()) do
      {:denied, socket} ->
        {:noreply, assign(socket, :dialog, nil)}

      {:ok, socket} ->
        socket =
          case Ledger.record_late_recording_review(
                 scope(socket),
                 company_id(socket),
                 socket.assigns.reviewing,
                 %{reason: reason}
               ) do
            {:ok, review} ->
              socket
              |> assign(dialog: nil, reviewing: nil, text: "")
              |> put_flash(:success, "Review of entry #{review.entry_id} recorded.")

            {:error, %Ecto.Changeset{}} ->
              put_flash(socket, :error, "Give a reason of 1 to 500 characters.")

            {:error, reason} ->
              socket
              |> assign(dialog: nil, reviewing: nil)
              |> put_flash(:error, refusal_text(reason))
          end

        {:noreply, load(socket)}
    end
  end

  defp load(socket) do
    %{state: state} = socket.assigns
    scope = scope(socket)
    company_id = company_id(socket)

    result =
      with {:ok, controlled} <- Ledger.get_controlled_bookkeeping(scope, company_id),
           {:ok, changes} <- Ledger.list_controlled_bookkeeping_changes(scope, company_id),
           {:ok, entries} <-
             Ledger.list_late_recordings(scope, company_id,
               status: status_filter(state.status),
               reviewed: reviewed_filter(state.review),
               limit: @page_size,
               after: state.after
             ) do
        {:ok, controlled, Enum.reverse(changes), entries}
      end

    case result do
      {:ok, controlled, changes, entries} ->
        socket
        |> assign(controlled: controlled, changes: changes, entries: entries, refusal: nil)
        |> assign(:thresholds, Ledger.late_recording_thresholds())
        |> assign(
          :can_manage?,
          LiveAuthorization.allowed_now?(
            socket.assigns.current_scope,
            Ledger.manage_controlled_bookkeeping_capability()
          )
        )
        |> assign(
          :can_open_years?,
          LiveAuthorization.allowed_now?(
            socket.assigns.current_scope,
            Ledger.manage_periods_capability()
          )
        )
        |> assign(
          :can_review?,
          LiveAuthorization.allowed_now?(
            socket.assigns.current_scope,
            Ledger.review_late_recordings_capability()
          )
        )

      {:error, reason} ->
        socket
        |> assign(controlled: nil, changes: [], entries: [])
        |> assign(can_manage?: false, can_open_years?: false, can_review?: false)
        |> assign(:refusal, reason)
    end
  end

  defp status_filter("all"), do: nil
  defp status_filter(status), do: status

  defp reviewed_filter("pending"), do: false
  defp reviewed_filter("reviewed"), do: true
  defp reviewed_filter("all"), do: nil

  defp fiscal_year_attributes(fields) do
    case Map.get(fields, "start_date", "") do
      "" ->
        {:ok, %{}}

      start_date ->
        with {:ok, start} <- Date.from_iso8601(start_date) do
          attributes = %{start_date: start}

          case Map.get(fields, "end_date", "") do
            "" ->
              {:ok, attributes}

            end_date ->
              with {:ok, finish} <- Date.from_iso8601(end_date),
                   do: {:ok, Map.put(attributes, :end_date, finish)}
          end
        else
          _invalid -> :error
        end
    end
  end

  ## Paths

  defp bookkeeping_path(state, changes) do
    query =
      %{
        "status" => if(state.status == "all", do: nil, else: state.status),
        "review" => if(state.review == "all", do: nil, else: state.review),
        "after" => nil
      }
      |> Map.merge(Map.new(changes, fn {key, value} -> {to_string(key), value} end))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/finance/reports/bookkeeping?#{query}"
  end

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  ## Text

  defp refusal_text(:unauthorized), do: "You do not have permission for that action."
  defp refusal_text(:company_archived), do: "The company is archived; nothing can be changed."
  defp refusal_text(:entry_not_found), do: "That entry no longer exists."
  defp refusal_text(:already_reviewed), do: "Someone has already reviewed that entry."
  defp refusal_text(:not_late_recorded), do: "That entry was not recorded late."

  defp refusal_text(:reviewer_not_independent),
    do: "An entry is reviewed by someone who did not post it."

  defp refusal_text(:book_not_open), do: "The ledger's book is not open yet."
  defp refusal_text(reason), do: "That could not be done (#{inspect(reason)})."

  defp actor_text(nil, _impersonator), do: "—"
  defp actor_text(user_id, nil), do: "User ##{user_id}"
  defp actor_text(user_id, by), do: "User ##{user_id} (impersonated by ##{by})"

  defp status_label("late"), do: "Late"
  defp status_label("approaching"), do: "Approaching"

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:detail}>
        <.header>
          Bookkeeping
          <:subtitle>Controlled bookkeeping, fiscal years, and entries recorded late</:subtitle>
        </.header>

        <.alert :if={@refusal} id="bookkeeping-refusal" kind={:error} class="mb-3">
          {refusal_text(@refusal)}
        </.alert>

        <.card
          :if={is_nil(@refusal)}
          id="controlled-bookkeeping"
          inner_class="p-5 sm:p-6"
          role="region"
          aria-labelledby="controlled-bookkeeping-heading"
        >
          <.section_heading id="controlled-bookkeeping-heading" title="Controlled bookkeeping">
            <:description>
              A controlled company posts an entry only into a fiscal period it has opened and left
              open, so nothing is recorded into a period nobody set up. Opening the first fiscal year
              is a step of its own; entries dated before it are refused, and so are dates after the
              last one until the next year is opened. Old transactions are not refused: an entry dated
              into an open period posts, however late.
            </:description>
          </.section_heading>

          <div class="mt-3 flex flex-wrap items-center gap-3">
            <span id="controlled-bookkeeping-status">
              <.badge :if={@controlled.controlled} kind={:success}>Controlled</.badge>
              <.badge :if={!@controlled.controlled} kind={:warning}>Not controlled</.badge>
            </span>
            <span :if={@controlled.change} class="text-sm text-ink-muted">
              Since
              <.datetime
                id="controlled-bookkeeping-changed-at"
                value={@controlled.change.changed_at}
                precision={:second}
              />
              by {actor_text(
                @controlled.change.changed_by_user_id,
                @controlled.change.changed_by_impersonator_id
              )}<span :if={@controlled.change.reason}>: {@controlled.change.reason}</span>
            </span>
            <.button
              :if={@can_manage? && !@controlled.controlled}
              id="controlled-bookkeeping-on"
              phx-click="turn_on"
            >
              Turn on
            </.button>
            <.button
              :if={@can_manage? && @controlled.controlled}
              id="controlled-bookkeeping-off"
              phx-click="open_dialog"
              phx-value-dialog="controlled-off"
              variant="danger"
            >
              Turn off
            </.button>
          </div>

          <.alert
            :if={@controlled.controlled && @controlled.fiscal_years == 0}
            id="no-fiscal-year"
            kind={:warning}
            class="mt-4"
          >
            No fiscal year is open, so no entry can be posted yet. Open the first fiscal year to
            start.
          </.alert>

          <div :if={@can_open_years?} class="mt-3 flex flex-wrap items-center gap-3">
            <span class="text-sm text-ink-muted">
              {if @controlled.fiscal_years == 0,
                do: "No fiscal year is open yet.",
                else:
                  "#{@controlled.fiscal_years} fiscal #{if @controlled.fiscal_years == 1, do: "year", else: "years"} open."}
            </span>
            <.button
              id="fiscal-year-open"
              phx-click="open_dialog"
              phx-value-dialog="fiscal-year"
              variant={if @controlled.fiscal_years == 0, do: "primary", else: nil}
            >
              {if @controlled.fiscal_years == 0,
                do: "Open the first fiscal year",
                else: "Open the next fiscal year"}
            </.button>
          </div>

          <.table
            :if={@changes != []}
            id="controlled-bookkeeping-changes"
            rows={@changes}
            framed={false}
            row_id={&"controlled-bookkeeping-change-#{&1.change_number}"}
            caption="Changes to controlled bookkeeping"
          >
            <:col :let={change} label="When">
              <.datetime
                id={"controlled-bookkeeping-change-at-#{change.change_number}"}
                value={change.changed_at}
                precision={:second}
              />
            </:col>
            <:col :let={change} label="Set to">
              {if change.controlled, do: "Controlled", else: "Not controlled"}
            </:col>
            <:col :let={change} label="Reason">{change.reason || "—"}</:col>
            <:col :let={change} label="By">
              {actor_text(change.changed_by_user_id, change.changed_by_impersonator_id)}
            </:col>
          </.table>
        </.card>

        <.card
          :if={is_nil(@refusal)}
          id="late-recordings"
          inner_class="p-5 sm:p-6 mt-4"
          role="region"
          aria-labelledby="late-recordings-heading"
        >
          <.section_heading id="late-recordings-heading" title="Entries recorded late">
            <:description>
              An entry is listed once it is recorded {@thresholds.approaching_days} or more days after
              its transaction date, and is late past {@thresholds.late_days} days. Each late entry
              needs a reason from an independent reviewer, someone who did not post it. The days are
              whole days from the transaction date to the day it was recorded.
            </:description>
          </.section_heading>

          <div id="late-recordings-filters" class="mt-3 flex flex-wrap items-center gap-4">
            <.tabs id="late-recordings-status" aria-label="Lateness">
              <:tab patch={bookkeeping_path(@state, status: nil)} current={@state.status == "all"}>
                All
              </:tab>
              <:tab
                patch={bookkeeping_path(@state, status: "approaching")}
                current={@state.status == "approaching"}
              >
                Approaching
              </:tab>
              <:tab patch={bookkeeping_path(@state, status: "late")} current={@state.status == "late"}>
                Late
              </:tab>
            </.tabs>
            <.tabs id="late-recordings-review" aria-label="Review status">
              <:tab patch={bookkeeping_path(@state, review: nil)} current={@state.review == "all"}>
                Any review
              </:tab>
              <:tab
                patch={bookkeeping_path(@state, review: "pending")}
                current={@state.review == "pending"}
              >
                Awaiting review
              </:tab>
              <:tab
                patch={bookkeeping_path(@state, review: "reviewed")}
                current={@state.review == "reviewed"}
              >
                Reviewed
              </:tab>
            </.tabs>
          </div>
        </.card>

        <.card :if={is_nil(@refusal)} id="late-recordings-card" inner_class="p-0 mt-3">
          <.table
            :if={@entries != []}
            id="late-recordings-table"
            rows={@entries}
            framed={false}
            row_id={&"late-entry-#{&1.entry_number}"}
            caption="Entries recorded late"
          >
            <:col :let={row} label="#">{row.entry_number}</:col>
            <:col :let={row} label="Transaction date">{row.entry_date}</:col>
            <:col :let={row} label="Recorded">
              <.datetime
                id={"late-entry-at-#{row.entry_number}"}
                value={row.posted_at}
                precision={:second}
              />
            </:col>
            <:col :let={row} label="Days">{row.days}</:col>
            <:col :let={row} label="Status">
              <.badge :if={row.status == "late"} kind={:danger} dot={false}>
                {status_label(row.status)}
              </.badge>
              <.badge :if={row.status == "approaching"} kind={:warning} dot={false}>
                {status_label(row.status)}
              </.badge>
            </:col>
            <:col :let={row} label="Description">
              <span class="block">{row.description}</span>
              <span :if={row.reference} class="block text-xs text-ink-muted">{row.reference}</span>
            </:col>
            <:col :let={row} label="Posted by">
              {actor_text(row.posted_by_user_id, row.posted_by_impersonator_id)}
            </:col>
            <:col :let={row} label="Review">
              <span :if={row.review} id={"late-entry-review-#{row.entry_number}"}>
                {row.review.reason}
                <span class="block text-xs text-ink-muted">
                  {actor_text(
                    row.review.reviewed_by_user_id,
                    row.review.reviewed_by_impersonator_id
                  )}
                </span>
              </span>
              <.button
                :if={is_nil(row.review) and @can_review?}
                id={"late-entry-review-open-#{row.entry_number}"}
                phx-click="open_dialog"
                phx-value-dialog="review"
                phx-value-entry={row.entry_id}
              >
                Record review
              </.button>
              <span :if={is_nil(row.review) and !@can_review?} class="text-ink-muted">
                Awaiting review
              </span>
            </:col>
          </.table>
          <.empty_state
            :if={@entries == []}
            id="late-recordings-empty"
            title="No entries recorded late"
            reason="Nothing in the ledger was recorded this long after its transaction date."
          />
        </.card>

        <div :if={length(@entries) == @page_size} class="mt-3">
          <.link
            id="late-recordings-next"
            patch={bookkeeping_path(@state, after: List.last(@entries).entry_number)}
            class="text-action hover:underline"
          >
            Later entries
          </.link>
        </div>

        <.modal
          :if={@dialog == "controlled-off"}
          id="controlled-off-modal"
          flash={@flash}
          title="Turn off controlled bookkeeping"
          on_cancel={JS.push("close_dialog")}
        >
          <:description>
            Entries may then post into a date no fiscal period covers, after the last year. The change
            is listed in the approval exceptions for an independent reviewer, with this reason.
          </:description>
          <.form
            for={%{}}
            as={:dialog}
            id="controlled-off-form"
            phx-change="text"
            phx-submit="turn_off"
          >
            <.input
              type="textarea"
              name="dialog[text]"
              id="controlled-off-reason"
              value={@text}
              label="Reason (1 to 500 characters)"
              maxlength="500"
              required
            />
            <div class="mt-4 flex justify-end gap-2">
              <.button type="button" id="controlled-off-close" phx-click="close_dialog">Cancel</.button>
              <.button
                type="submit"
                id="controlled-off-confirm"
                variant="danger"
                phx-disable-with="Saving…"
              >
                Turn off
              </.button>
            </div>
          </.form>
        </.modal>

        <.modal
          :if={@dialog == "fiscal-year"}
          id="fiscal-year-modal"
          flash={@flash}
          title="Open a fiscal year"
          on_cancel={JS.push("close_dialog")}
        >
          <:description>
            A fiscal year is divided into monthly periods, which are open until they are closed. The
            first year may start on any month; each later year starts the day after the previous one
            ends. Leave the end date blank for twelve months.
          </:description>
          <.form for={%{}} as={:dialog} id="fiscal-year-form" phx-submit="open_fiscal_year">
            <.input
              type="date"
              name="dialog[start_date]"
              id="fiscal-year-start"
              value=""
              label="First day of the year"
              required
            />
            <.input
              type="date"
              name="dialog[end_date]"
              id="fiscal-year-end"
              value=""
              label="Last day (optional)"
            />
            <div class="mt-4 flex justify-end gap-2">
              <.button type="button" id="fiscal-year-close" phx-click="close_dialog">Cancel</.button>
              <.button
                type="submit"
                id="fiscal-year-confirm"
                variant="primary"
                phx-disable-with="Opening…"
              >
                Open fiscal year
              </.button>
            </div>
          </.form>
        </.modal>

        <.modal
          :if={@dialog == "review"}
          id="late-review-modal"
          flash={@flash}
          title="Record your review"
          on_cancel={JS.push("close_dialog")}
        >
          <:description>
            Your review is kept with your name and the time; it cannot be changed. You cannot review an
            entry you posted.
          </:description>
          <.form for={%{}} as={:dialog} id="late-review-form" phx-change="text" phx-submit="review">
            <.input
              type="textarea"
              name="dialog[text]"
              id="late-review-reason"
              value={@text}
              label="Why it was recorded late (1 to 500 characters)"
              maxlength="500"
              required
            />
            <div class="mt-4 flex justify-end gap-2">
              <.button type="button" id="late-review-close" phx-click="close_dialog">Cancel</.button>
              <.button
                type="submit"
                id="late-review-confirm"
                variant="primary"
                phx-disable-with="Recording…"
              >
                Record review
              </.button>
            </div>
          </.form>
        </.modal>
      </.page>
    </Layouts.app>
    """
  end
end
