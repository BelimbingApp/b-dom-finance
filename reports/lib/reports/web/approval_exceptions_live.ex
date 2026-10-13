defmodule Bilimbi.Finance.Reports.Web.ApprovalExceptionsLive do
  @moduledoc """
  The company's approval exceptions, by period, for an independent
  reviewer: every approval made by the person who prepared the record while
  the company had separation of duties turned off, and every override of a
  control (an approved match exception, a reopened period), each with who
  prepared and approved it, the reason, and its review. Above them, the
  company's separation of duties setting and every change to it.

  The page reads the ledger's facade (`Bilimbi.Finance.Ledger`). Changing the
  setting and recording a review are facade calls that re-ask their own
  capability; the `can_*` assigns only decide which controls show.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Base.UI.PeriodFilter
  alias Bilimbi.Finance.Ledger

  @page_size 100
  @reviews ~w(all pending reviewed)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Approval exceptions")
     |> assign(:active_nav, "finance.reports.approval-exceptions")
     |> assign(:browser_timezone, nil)
     |> assign(:page_size, @page_size)
     |> assign(:dialog, nil)
     |> assign(:reviewing, nil)
     |> assign(:text, "")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    clock =
      PeriodFilter.clock(
        socket.assigns.current_scope.shell_preferences,
        socket.assigns.browser_timezone
      )

    state = %{
      clock: clock,
      period: PeriodFilter.parse(Map.put_new(params, "period", "this_month"), clock.today),
      review: if(params["review"] in @reviews, do: params["review"], else: "all"),
      after: Params.positive_integer(params["after"])
    }

    {:noreply, socket |> assign(:params, params) |> assign(:state, state) |> load()}
  end

  @impl true
  def handle_event("browser_timezone", %{"timezone" => timezone}, socket) do
    handle_params(socket.assigns.params, nil, assign(socket, :browser_timezone, timezone))
  end

  def handle_event("open_dialog", %{"dialog" => "separation"}, socket) do
    {:noreply, socket |> clear_flash() |> assign(dialog: "separation", text: "")}
  end

  def handle_event("open_dialog", %{"dialog" => "review", "exception" => id}, socket) do
    {:noreply,
     socket
     |> clear_flash()
     |> assign(dialog: "review", reviewing: Params.positive_integer(id, 0), text: "")}
  end

  def handle_event("close_dialog", _params, socket) do
    {:noreply, assign(socket, dialog: nil, reviewing: nil, text: "")}
  end

  def handle_event("text", %{"dialog" => %{"text" => text}}, socket) do
    {:noreply, assign(socket, :text, text)}
  end

  def handle_event("change_separation", %{"dialog" => %{"text" => reason}}, socket) do
    case LiveAuthorization.authorize_event(socket, Ledger.manage_duty_separation_capability()) do
      {:denied, socket} ->
        {:noreply, assign(socket, :dialog, nil)}

      {:ok, socket} ->
        required = not socket.assigns.separation.required

        socket =
          case Ledger.set_duty_separation(scope(socket), company_id(socket), %{
                 required: required,
                 reason: reason
               }) do
            {:ok, %{required: true}} ->
              socket
              |> assign(dialog: nil, text: "")
              |> put_flash(:success, "Separation of duties is required again.")

            {:ok, %{required: false}} ->
              socket
              |> assign(dialog: nil, text: "")
              |> put_flash(
                :success,
                "Separation of duties is off; same-person approvals are listed here."
              )

            {:error, %Ecto.Changeset{}} ->
              put_flash(socket, :error, "Give a reason of 1 to 500 characters.")

            {:error, reason} ->
              socket |> assign(:dialog, nil) |> put_flash(:error, refusal_text(reason))
          end

        {:noreply, load(socket)}
    end
  end

  def handle_event("review", %{"dialog" => %{"text" => note}}, socket) do
    case LiveAuthorization.authorize_event(socket, Ledger.review_exceptions_capability()) do
      {:denied, socket} ->
        {:noreply, assign(socket, :dialog, nil)}

      {:ok, socket} ->
        socket =
          case Ledger.review_approval_exception(
                 scope(socket),
                 company_id(socket),
                 socket.assigns.reviewing,
                 %{note: note}
               ) do
            {:ok, exception} ->
              socket
              |> assign(dialog: nil, reviewing: nil, text: "")
              |> put_flash(
                :success,
                "Review of exception #{exception.exception_number} recorded."
              )

            {:error, %Ecto.Changeset{}} ->
              put_flash(socket, :error, "Keep the note to 500 characters.")

            {:error, reason} ->
              socket
              |> assign(dialog: nil, reviewing: nil)
              |> put_flash(:error, refusal_text(reason))
          end

        {:noreply, load(socket)}
    end
  end

  defp load(socket) do
    %{state: state, current_scope: current_scope} = socket.assigns
    scope = scope(socket)
    company_id = company_id(socket)

    result =
      with {:ok, from, before} <-
             PeriodFilter.bounds(state.period, state.clock.timezone, state.clock.tz_db),
           {:ok, separation} <- Ledger.get_duty_separation(scope, company_id),
           {:ok, changes} <- Ledger.list_duty_separation_changes(scope, company_id),
           {:ok, exceptions} <-
             Ledger.list_approval_exceptions(scope, company_id,
               recorded_from: from,
               recorded_before: before,
               reviewed: reviewed_filter(state.review),
               limit: @page_size,
               after: state.after
             ) do
        {:ok, separation, Enum.reverse(changes), exceptions}
      end

    case result do
      {:ok, separation, changes, exceptions} ->
        socket
        |> assign(separation: separation, changes: changes, exceptions: exceptions)
        |> assign(:refusal, nil)
        |> assign(
          :can_manage?,
          LiveAuthorization.allowed_now?(
            current_scope,
            Ledger.manage_duty_separation_capability()
          )
        )
        |> assign(
          :can_review?,
          LiveAuthorization.allowed_now?(current_scope, Ledger.review_exceptions_capability())
        )

      {:error, reason} ->
        socket
        |> assign(separation: nil, changes: [], exceptions: [])
        |> assign(can_manage?: false, can_review?: false)
        |> assign(:refusal, reason)
    end
  end

  defp reviewed_filter("pending"), do: false
  defp reviewed_filter("reviewed"), do: true
  defp reviewed_filter("all"), do: nil

  ## Paths

  defp exceptions_path(state, changes) do
    query =
      %{"review" => if(state.review == "all", do: nil, else: state.review), "after" => nil}
      |> Map.merge(PeriodFilter.params(state.period))
      |> Map.merge(Map.new(changes, fn {key, value} -> {to_string(key), value} end))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/finance/reports/approval-exceptions?#{query}"
  end

  defp period_path(state, params),
    do:
      exceptions_path(
        state,
        PeriodFilter.params(PeriodFilter.parse(params, state.clock.today))
      )

  defp scope(socket), do: socket.assigns.current_scope.scope
  defp company_id(socket), do: socket.assigns.current_scope.user["company_id"]

  ## Text

  defp refusal_text(:unauthorized), do: "You do not have permission for that action."
  defp refusal_text(:company_archived), do: "The company is archived; nothing can be changed."
  defp refusal_text(:exception_not_found), do: "That exception no longer exists."
  defp refusal_text(:already_reviewed), do: "Someone has already reviewed that exception."

  defp refusal_text(:reviewer_not_independent),
    do: "An exception is reviewed by someone who neither approved nor prepared what it records."

  defp refusal_text(reason), do: "That could not be done (#{inspect(reason)})."

  defp actor_text(nil, _impersonator), do: "—"
  defp actor_text(user_id, nil), do: "User ##{user_id}"
  defp actor_text(user_id, by), do: "User ##{user_id} (impersonated by ##{by})"

  defp source_label("finance/ledger"), do: "Ledger"
  defp source_label("finance/payables"), do: "Payables"
  defp source_label("finance/reconciliation"), do: "Bank reconciliation"
  defp source_label(source), do: source

  defp action_label("document_approval"), do: "Document approved"
  defp action_label("match_override"), do: "Match exceptions approved"
  defp action_label("payment_approval"), do: "Payment approved"
  defp action_label("journal_approval"), do: "Journal approved"
  defp action_label("reconciliation_finalisation"), do: "Reconciliation finalised"
  defp action_label("period_reopen"), do: "Period reopened"
  defp action_label("fiscal_year_reopen"), do: "Fiscal year reopened"

  defp action_label(action),
    do: action |> String.replace("_", " ") |> String.capitalize()

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page variant={:detail}>
        <.header>
          Approval exceptions
          <:subtitle>
            Same-person approvals and overrides of controls, for someone independent to review.
          </:subtitle>
        </.header>

        <.empty_state
          :if={@refusal == :unauthorized}
          id="exceptions-refusal"
          forbidden="view the ledger"
        />
        <.empty_state
          :if={@refusal && @refusal != :unauthorized}
          id="exceptions-refusal"
          title="The exceptions cannot be shown"
          reason="The company or the period could not be read. Choose another period or reload the page."
        />

        <.card
          :if={@separation}
          id="duty-separation"
          inner_class="p-5 sm:p-6"
          role="region"
          aria-labelledby="duty-separation-heading"
        >
          <.section_heading id="duty-separation-heading" title="Separation of duties">
            <:description>
              While it is required, nobody approves, posts, or finalises a record they prepared,
              nor one prepared by someone they impersonated. A company with one finance person
              turns it off: those approvals are then allowed and listed below.
            </:description>
          </.section_heading>
          <div class="mt-3 flex flex-wrap items-center gap-3">
            <span id="duty-separation-status">
              <.badge :if={@separation.required} kind={:success}>Required</.badge>
              <.badge :if={!@separation.required} kind={:warning}>Not required</.badge>
            </span>
            <span :if={@separation.change} class="text-sm text-ink-muted">
              Since
              <.datetime
                id="duty-separation-changed-at"
                value={@separation.change.changed_at}
                precision={:second}
              />
              by {actor_text(
                @separation.change.changed_by_user_id,
                @separation.change.changed_by_impersonator_id
              )}<span :if={@separation.change.reason}>: {@separation.change.reason}</span>
            </span>
            <.button
              :if={@can_manage?}
              id="duty-separation-change"
              phx-click="open_dialog"
              phx-value-dialog="separation"
              variant={if @separation.required, do: "danger", else: "primary"}
            >
              {if @separation.required, do: "Turn off", else: "Require again"}
            </.button>
          </div>
          <.table
            :if={@changes != []}
            id="duty-separation-changes"
            rows={@changes}
            framed={false}
            row_id={&"duty-separation-change-#{&1.change_number}"}
            caption="Changes to separation of duties"
          >
            <:col :let={change} label="When">
              <.datetime
                id={"duty-separation-change-at-#{change.change_number}"}
                value={change.changed_at}
                precision={:second}
              />
            </:col>
            <:col :let={change} label="Set to">
              {if change.required, do: "Required", else: "Not required"}
            </:col>
            <:col :let={change} label="Reason">{change.reason || "—"}</:col>
            <:col :let={change} label="By">
              {actor_text(change.changed_by_user_id, change.changed_by_impersonator_id)}
            </:col>
          </.table>
        </.card>

        <div
          :if={is_nil(@refusal)}
          id="exceptions-filters"
          phx-hook="BrowserTimeZone"
          class="mt-4 mb-3 flex flex-wrap items-center gap-4"
        >
          <.period_filter
            id="exceptions-period"
            clock={@state.clock}
            state={@state.period}
            current_scope={@current_scope}
            path={&period_path(@state, &1)}
          />
          <.tabs id="exceptions-review" aria-label="Review status">
            <:tab patch={exceptions_path(@state, review: nil)} current={@state.review == "all"}>
              All
            </:tab>
            <:tab
              patch={exceptions_path(@state, review: "pending")}
              current={@state.review == "pending"}
            >
              Awaiting review
            </:tab>
            <:tab
              patch={exceptions_path(@state, review: "reviewed")}
              current={@state.review == "reviewed"}
            >
              Reviewed
            </:tab>
          </.tabs>
        </div>

        <.card :if={is_nil(@refusal)} id="exceptions-card" inner_class="p-0">
          <.table
            :if={@exceptions != []}
            id="exceptions-table"
            rows={@exceptions}
            framed={false}
            row_id={&"exception-#{&1.exception_number}"}
            caption="Approval exceptions"
          >
            <:col :let={exception} label="#">{exception.exception_number}</:col>
            <:col :let={exception} label="When">
              <.datetime
                id={"exception-at-#{exception.exception_number}"}
                value={exception.recorded_at}
                precision={:second}
              />
            </:col>
            <:col :let={exception} label="Kind">
              <.badge :if={exception.same_person} kind={:warning} dot={false}>Same person</.badge>
              <.badge :if={exception.override} dot={false}>Override</.badge>
            </:col>
            <:col :let={exception} label="What">
              <span class="block">
                {source_label(exception.source)}: {action_label(exception.action)}
              </span>
              <span class="block text-xs text-ink-muted">{exception.subject}</span>
            </:col>
            <:col :let={exception} label="Prepared by">
              {actor_text(exception.prepared_by_user_id, exception.prepared_by_impersonator_id)}
            </:col>
            <:col :let={exception} label="Approved by">
              {actor_text(exception.approved_by_user_id, exception.approved_by_impersonator_id)}
            </:col>
            <:col :let={exception} label="Reason">{exception.reason}</:col>
            <:col :let={exception} label="Review">
              <span :if={exception.review} id={"exception-review-#{exception.exception_number}"}>
                {actor_text(
                  exception.review.reviewed_by_user_id,
                  exception.review.reviewed_by_impersonator_id
                )}
                <span :if={exception.review.note} class="block text-xs text-ink-muted">
                  {exception.review.note}
                </span>
              </span>
              <.button
                :if={is_nil(exception.review) and @can_review?}
                id={"exception-review-open-#{exception.exception_number}"}
                phx-click="open_dialog"
                phx-value-dialog="review"
                phx-value-exception={exception.id}
              >
                Record review
              </.button>
              <span :if={is_nil(exception.review) and !@can_review?} class="text-ink-muted">
                Awaiting review
              </span>
            </:col>
          </.table>
          <.empty_state
            :if={@exceptions == []}
            id="exceptions-empty"
            title="No approval exceptions"
            reason="Nobody approved their own work or overrode a control in this period."
          />
        </.card>

        <div :if={length(@exceptions) == @page_size} class="mt-3">
          <.link
            id="exceptions-next"
            patch={exceptions_path(@state, after: List.last(@exceptions).exception_number)}
            class="text-action hover:underline"
          >
            Later exceptions
          </.link>
        </div>

        <.modal
          :if={@dialog == "separation" and @separation}
          id="duty-separation-modal"
          flash={@flash}
          title={
            if @separation.required,
              do: "Turn separation of duties off",
              else: "Require separation of duties again"
          }
          on_cancel={JS.push("close_dialog")}
        >
          <:description>
            <%= if @separation.required do %>
              Whoever prepares a record may then approve it. Each such approval is listed here
              with this reason, for someone independent to review.
            <% else %>
              Nobody may then approve, post, or finalise a record they prepared.
            <% end %>
          </:description>
          <.form
            for={%{}}
            as={:dialog}
            id="duty-separation-form"
            phx-change="text"
            phx-submit="change_separation"
          >
            <.input
              type="textarea"
              name="dialog[text]"
              id="duty-separation-reason"
              value={@text}
              label={
                if @separation.required, do: "Reason (1 to 500 characters)", else: "Reason (optional)"
              }
              maxlength="500"
              required={@separation.required}
            />
            <div class="mt-4 flex justify-end gap-2">
              <.button type="button" id="duty-separation-close" phx-click="close_dialog">
                Cancel
              </.button>
              <.button
                type="submit"
                id="duty-separation-confirm"
                variant="primary"
                phx-disable-with="Saving…"
              >
                {if @separation.required, do: "Turn off", else: "Require again"}
              </.button>
            </div>
          </.form>
        </.modal>

        <.modal
          :if={@dialog == "review"}
          id="exception-review-modal"
          flash={@flash}
          title="Record your review"
          on_cancel={JS.push("close_dialog")}
        >
          <:description>
            Your review is kept with your name and the time; it cannot be changed. You cannot
            review an approval you made or a record you prepared.
          </:description>
          <.form
            for={%{}}
            as={:dialog}
            id="exception-review-form"
            phx-change="text"
            phx-submit="review"
          >
            <.input
              type="textarea"
              name="dialog[text]"
              id="exception-review-note"
              value={@text}
              label="Note (optional, up to 500 characters)"
              maxlength="500"
            />
            <div class="mt-4 flex justify-end gap-2">
              <.button type="button" id="exception-review-close" phx-click="close_dialog">
                Cancel
              </.button>
              <.button
                type="submit"
                id="exception-review-confirm"
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
