defmodule Bilimbi.Finance.Payroll.Web.PostingsLive do
  @moduledoc """
  The company's payroll runs and approved claims with their standing in the
  books: posted (with the entry number), reversed, failed (with the reason
  of the last attempt), or not posted yet, each with the action that posts,
  retries, or reverses it. Without the source Domain the page lists what
  this module posted from its own events. The buttons are facade calls
  that re-ask the capabilities; the `can_post?` assign only decides whether
  they show.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Base.UI.Params
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Payroll
  alias Bilimbi.Finance.Payroll.Web.Format

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope.scope

    {:ok,
     socket
     |> assign(:page_title, "Payroll and claims")
     |> assign(:active_nav, "finance.payroll")
     |> assign(:company_id, Scope.actor(scope).company_id)
     |> assign(:reversing, nil)
     |> assign(:reversal_form, reversal_form())
     |> load()}
  end

  defp reversal_form, do: to_form(%{"reason" => "", "entry_date" => ""}, as: :reversal)

  defp load(socket) do
    %{current_scope: %{scope: scope}, company_id: company_id} = socket.assigns

    minor_units =
      case Ledger.get_book(scope, company_id) do
        {:ok, book} -> book.minor_units
        {:error, _reason} -> 2
      end

    socket
    |> assign(:available?, Payroll.people_available?())
    |> assign(:runs, read(Payroll.list_payroll_runs(scope, company_id)))
    |> assign(:claims, read(Payroll.list_claims(scope, company_id)))
    |> assign(:postings, read(Payroll.list_postings(scope, company_id)))
    |> assign(:minor_units, minor_units)
    |> assign(
      :can_post?,
      LiveAuthorization.allowed_now?(
        socket.assigns.current_scope,
        Payroll.post_postings_capability()
      )
    )
  end

  defp read({:ok, rows}), do: {:ok, rows}
  defp read({:error, reason}), do: {:error, reason}

  @impl true
  def handle_event("post_run", %{"id" => id}, socket) do
    with_capability(socket, fn socket ->
      socket.assigns.current_scope.scope
      |> Payroll.post_payroll_run(socket.assigns.company_id, Params.positive_integer(id, 0))
      |> flash(socket, &"Payroll run posted as entry #{&1.entry_number}.")
    end)
  end

  def handle_event("post_claim", %{"id" => id}, socket) do
    with_capability(socket, fn socket ->
      socket.assigns.current_scope.scope
      |> Payroll.post_claim(socket.assigns.company_id, Params.positive_integer(id, 0))
      |> flash(socket, &"Claim posted as entry #{&1.entry_number}.")
    end)
  end

  def handle_event("post_all_claims", _params, socket) do
    with_capability(socket, fn socket ->
      %{current_scope: %{scope: scope}, company_id: company_id} = socket.assigns

      pending =
        case socket.assigns.claims do
          {:ok, claims} -> Enum.reject(claims, & &1.posting)
          {:error, _reason} -> []
        end

      {posted, failed} =
        Enum.reduce(pending, {0, 0}, fn claim, {posted, failed} ->
          case Payroll.post_claim(scope, company_id, claim.id) do
            {:ok, _posting} -> {posted + 1, failed}
            {:error, _reason} -> {posted, failed + 1}
          end
        end)

      socket
      |> put_flash(
        if(failed == 0, do: :success, else: :error),
        "#{posted} claims posted, #{failed} failed."
      )
      |> load()
    end)
  end

  def handle_event("reverse", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:reversing, Params.positive_integer(id, nil))
     |> assign(:reversal_form, reversal_form())}
  end

  def handle_event("cancel_reversal", _params, socket),
    do: {:noreply, assign(socket, :reversing, nil)}

  def handle_event("change_reversal", %{"reversal" => params}, socket),
    do: {:noreply, assign(socket, :reversal_form, to_form(params, as: :reversal))}

  def handle_event("confirm_reversal", %{"reversal" => params}, socket) do
    with_capability(socket, fn socket ->
      attributes =
        %{reason: params["reason"]}
        |> then(fn attributes ->
          case Params.blank_to_nil(params["entry_date"]) do
            nil -> attributes
            date -> Map.put(attributes, :entry_date, date)
          end
        end)

      socket.assigns.current_scope.scope
      |> Payroll.reverse_posting(socket.assigns.company_id, socket.assigns.reversing, attributes)
      |> case do
        {:ok, posting} ->
          socket
          |> put_flash(:success, "Reversed as entry #{posting.reversal.entry_number}.")
          |> assign(:reversing, nil)
          |> load()

        {:error, reason} ->
          socket |> put_flash(:error, Format.refusal(reason)) |> load()
      end
    end)
  end

  # A refusal re-derives the cached assign the buttons render from.
  defp with_capability(socket, fun) do
    case LiveAuthorization.authorize_event(socket, Payroll.post_postings_capability()) do
      {:denied, socket} -> {:noreply, assign(socket, :can_post?, false)}
      {:ok, socket} -> {:noreply, fun.(socket)}
    end
  end

  defp flash({:ok, posting}, socket, success),
    do: socket |> put_flash(:success, success.(posting)) |> load()

  defp flash({:error, reason}, socket, _success),
    do: socket |> put_flash(:error, Format.refusal(reason)) |> load()

  defp standing(%{posting: %{reversal: %{}} = posting}),
    do: "reversed (entry #{posting.entry_number})"

  defp standing(%{posting: %{entry_number: number}}), do: "entry #{number}"
  defp standing(source), do: Format.standing(source)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="payroll-postings">
        <.header>
          Payroll and claims
          <:subtitle>
            Finalised payroll runs and approved claims, and whether each is in the books.
          </:subtitle>
          <:actions>
            <.link id="payroll-postings-setup" navigate={~p"/finance/payroll/setup"}>
              Posting accounts
            </.link>
          </:actions>
        </.header>

        <.empty_state
          :if={not @available?}
          id="payroll-source-unavailable"
          title="No payroll or claims source is installed"
          reason="Runs and claims are listed once the People Domain is mounted. The postings already made are listed below."
        />

        <.card
          :if={@available?}
          id="payroll-runs"
          inner_class="p-0"
          role="region"
          aria-labelledby="payroll-runs-heading"
        >
          <.section_heading id="payroll-runs-heading" title="Payroll runs" class="p-5 pb-0" />
          <.empty_state
            :if={match?({:error, _}, @runs)}
            id="payroll-runs-unavailable"
            forbidden="read the company's payroll runs"
          />
          <.table
            :if={match?({:ok, _}, @runs)}
            id="payroll-runs-table"
            rows={elem(@runs, 1)}
            framed={false}
            row_id={&"payroll-run-#{&1.id}"}
          >
            <:col :let={run} label="Run">{run.reference}</:col>
            <:col :let={run} label="Pay date">{run.pay_date}</:col>
            <:col :let={run} label="Run status">{run.status}</:col>
            <:col :let={run} label="In the books">
              <.badge kind={Format.standing_kind(run)}>{standing(run)}</.badge>
            </:col>
            <:col :let={run} label="Last failure">
              {if run.last_failure, do: run.last_failure.reason, else: "—"}
            </:col>
            <:col :let={run} label="">
              <.button
                :if={@can_post? and run.finalised and is_nil(run.posting)}
                id={"payroll-post-run-#{run.id}"}
                phx-click="post_run"
                phx-value-id={run.id}
              >
                {if run.last_failure, do: "Retry posting", else: "Post"}
              </.button>
              <.button
                :if={@can_post? and not is_nil(run.posting) and is_nil(run.posting.reversal)}
                id={"payroll-reverse-run-#{run.id}"}
                phx-click="reverse"
                phx-value-id={run.posting.id}
              >
                Reverse
              </.button>
            </:col>
            <:empty>No payroll runs yet.</:empty>
          </.table>
        </.card>

        <.card
          :if={@available?}
          id="payroll-claims"
          inner_class="p-0"
          role="region"
          aria-labelledby="payroll-claims-heading"
        >
          <.section_heading id="payroll-claims-heading" title="Approved claims" class="p-5 pb-0">
            <:actions>
              <.button
                :if={@can_post? and match?({:ok, [_ | _]}, @claims)}
                id="payroll-post-all-claims"
                phx-click="post_all_claims"
              >
                Post every unposted claim
              </.button>
            </:actions>
          </.section_heading>
          <.empty_state
            :if={match?({:error, _}, @claims)}
            id="payroll-claims-unavailable"
            forbidden="read the company's approved claims"
          />
          <.table
            :if={match?({:ok, _}, @claims)}
            id="payroll-claims-table"
            rows={elem(@claims, 1)}
            framed={false}
            row_id={&"payroll-claim-#{&1.id}"}
          >
            <:col :let={claim} label="Claim">{claim.reference}</:col>
            <:col :let={claim} label="Category">{claim.category_code || "—"}</:col>
            <:col :let={claim} label="Approved on">{claim.approved_on}</:col>
            <:col :let={claim} label="Amount" align={:right}>
              <span class="tabular-nums">{Format.money(claim.amount, @minor_units)} {claim.currency_code}</span>
            </:col>
            <:col :let={claim} label="In the books">
              <.badge kind={Format.standing_kind(claim)}>{standing(claim)}</.badge>
            </:col>
            <:col :let={claim} label="Last failure">
              {if claim.last_failure, do: claim.last_failure.reason, else: "—"}
            </:col>
            <:col :let={claim} label="">
              <.button
                :if={@can_post? and is_nil(claim.posting)}
                id={"payroll-post-claim-#{claim.id}"}
                phx-click="post_claim"
                phx-value-id={claim.id}
              >
                {if claim.last_failure, do: "Retry posting", else: "Post"}
              </.button>
              <.button
                :if={@can_post? and not is_nil(claim.posting) and is_nil(claim.posting.reversal)}
                id={"payroll-reverse-claim-#{claim.id}"}
                phx-click="reverse"
                phx-value-id={claim.posting.id}
              >
                Reverse
              </.button>
            </:col>
            <:empty>No approved claims.</:empty>
          </.table>
        </.card>

        <.card
          :if={@reversing}
          id="payroll-reversal"
          role="region"
          aria-labelledby="payroll-reversal-heading"
        >
          <.section_heading id="payroll-reversal-heading" title="Reverse a posting">
            <:description>
              The reversal is a new entry with the sides swapped; the original stays in the books. Say why.
            </:description>
          </.section_heading>
          <.form
            for={@reversal_form}
            id="payroll-reversal-form"
            phx-change="change_reversal"
            phx-submit="confirm_reversal"
            class="mt-4 grid gap-x-6 gap-y-2 md:grid-cols-2"
          >
            <.input
              field={@reversal_form[:reason]}
              id="payroll-reversal-reason"
              label="Reason"
              maxlength="500"
              required
            />
            <.input
              field={@reversal_form[:entry_date]}
              id="payroll-reversal-date"
              type="date"
              label="Entry date (today unless given)"
            />
            <div class="flex gap-2 md:col-span-2">
              <.button type="submit" id="payroll-reversal-confirm" variant="danger">
                Reverse posting
              </.button>
              <.button type="button" id="payroll-reversal-cancel" phx-click="cancel_reversal">
                Cancel
              </.button>
            </div>
          </.form>
        </.card>

        <.card
          id="payroll-postings-list"
          inner_class="p-0"
          role="region"
          aria-labelledby="payroll-postings-heading"
        >
          <.section_heading id="payroll-postings-heading" title="Postings made" class="p-5 pb-0" />
          <.empty_state
            :if={match?({:error, _}, @postings)}
            id="payroll-postings-unavailable"
            forbidden="view payroll postings"
          />
          <.table
            :if={match?({:ok, _}, @postings)}
            id="payroll-postings-table"
            rows={elem(@postings, 1)}
            framed={false}
            row_id={&"payroll-posting-#{&1.id}"}
          >
            <:col :let={posting} label="Source">
              {Format.source_kind(posting.source_kind)} {posting.source_reference}
            </:col>
            <:col :let={posting} label="Entry">{posting.entry_number}</:col>
            <:col :let={posting} label="Entry date">{posting.entry_date}</:col>
            <:col :let={posting} label="Total" align={:right}>
              <span class="tabular-nums">{Format.money(posting.total, @minor_units)} {posting.currency_code}</span>
            </:col>
            <:col :let={posting} label="Standing">
              <.badge kind={if posting.reversal, do: :warning, else: :success}>
                {if posting.reversal,
                  do: "reversed by entry #{posting.reversal.entry_number}",
                  else: "posted"}
              </.badge>
            </:col>
            <:col :let={posting} label="Reversal reason">
              {if posting.reversal, do: posting.reversal.reason, else: "—"}
            </:col>
            <:col :let={posting} label="">
              <.button
                :if={@can_post? and is_nil(posting.reversal)}
                id={"payroll-reverse-posting-#{posting.id}"}
                phx-click="reverse"
                phx-value-id={posting.id}
              >
                Reverse
              </.button>
            </:col>
            <:empty>Nothing has been posted yet.</:empty>
          </.table>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
