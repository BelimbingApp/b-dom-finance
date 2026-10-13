defmodule Bilimbi.Finance.Payroll.Events do
  @moduledoc false
  # The posting events: how they are recorded and read. A source's standing
  # is its events: `posted` once, then `reversed` once, with the failures in
  # between; the latest failure after the last success is what a page shows.
  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Payroll.PostingEvent

  @doc "Inserts one event as the scope's actor; raises on a refusal."
  def record!(%Scope{} = scope, company_id, attributes) do
    %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

    %PostingEvent{
      tenant_id: Scope.tenant_id(scope),
      company_id: company_id,
      actor_user_id: user_id,
      actor_impersonator_id: impersonator_id
    }
    |> PostingEvent.changeset(attributes)
    |> Repo.insert!()
  end

  @doc "Inserts one event as the scope's actor, returning the changeset on a refusal."
  def record(%Scope{} = scope, company_id, attributes) do
    %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

    %PostingEvent{
      tenant_id: Scope.tenant_id(scope),
      company_id: company_id,
      actor_user_id: user_id,
      actor_impersonator_id: impersonator_id
    }
    |> PostingEvent.changeset(attributes)
    |> Repo.insert()
  end

  @doc "Every event of the company, oldest first."
  def list(%Scope{} = scope, company_id) do
    scope
    |> query(company_id)
    |> order_by([e], asc: e.id)
    |> Repo.all()
  end

  @doc "The events of one source, oldest first."
  def for_source(%Scope{} = scope, company_id, source_kind, source_id) do
    scope
    |> query(company_id)
    |> where([e], e.source_kind == ^source_kind and e.source_id == ^source_id)
    |> order_by([e], asc: e.id)
    |> Repo.all()
  end

  @doc "The `posted` event of one source, or nil."
  def posted(%Scope{} = scope, company_id, source_kind, source_id) do
    scope
    |> query(company_id)
    |> where([e], e.source_kind == ^source_kind and e.source_id == ^source_id)
    |> where([e], e.event == "posted")
    |> Repo.one()
  end

  @doc "The `posted` event with this ID, or nil."
  def posted_by_id(%Scope{} = scope, company_id, posting_id) when is_integer(posting_id) do
    scope
    |> query(company_id)
    |> where([e], e.id == ^posting_id and e.event == "posted")
    |> Repo.one()
  end

  def posted_by_id(_scope, _company_id, _posting_id), do: nil

  @doc """
  The standing of every source with an event, keyed by `{source_kind,
  source_id}`: the posting view when it posted, else `%{posting: nil,
  last_failure: _}`.
  """
  def standings(%Scope{} = scope, company_id) do
    scope
    |> list(company_id)
    |> Enum.group_by(&{&1.source_kind, &1.source_id})
    |> Map.new(fn {key, events} -> {key, standing(events)} end)
  end

  @doc "The standing of one source from its events, oldest first."
  def standing(events) do
    posted = Enum.find(events, &(&1.event == "posted"))
    reversed = Enum.find(events, &(&1.event == "reversed"))

    # The failures that still matter are the ones after the last success.
    last_success_id = (reversed || posted || %{id: 0}).id

    last_failure =
      events
      |> Enum.filter(
        &(&1.event in ["posting_failed", "reversal_failed"] and &1.id > last_success_id)
      )
      |> List.last()

    %{
      posting: posted && posting_view(posted, reversed),
      last_failure: last_failure && failure_view(last_failure)
    }
  end

  @doc "One posting as the facade shows it: the `posted` event with its reversal."
  def posting_view(%PostingEvent{event: "posted"} = posted, reversed) do
    posted
    |> Map.take([
      :id,
      :source_kind,
      :source_id,
      :source_reference,
      :entry_id,
      :entry_number,
      :entry_date,
      :total,
      :currency_code
    ])
    |> Map.merge(%{
      posted_by_user_id: posted.actor_user_id,
      posted_by_impersonator_id: posted.actor_impersonator_id,
      posted_at: posted.occurred_at,
      reversal: reversed && reversal_view(reversed)
    })
  end

  defp reversal_view(reversed) do
    %{
      entry_id: reversed.entry_id,
      entry_number: reversed.entry_number,
      entry_date: reversed.entry_date,
      reason: reversed.reason,
      reversed_by_user_id: reversed.actor_user_id,
      reversed_by_impersonator_id: reversed.actor_impersonator_id,
      reversed_at: reversed.occurred_at
    }
  end

  defp failure_view(failure) do
    %{
      action: if(failure.event == "posting_failed", do: "post", else: "reverse"),
      reason: failure.reason,
      actor_user_id: failure.actor_user_id,
      occurred_at: failure.occurred_at
    }
  end

  @doc "One event as `list_posting_events/4` shows it."
  def event_view(%PostingEvent{} = event) do
    Map.take(event, [
      :id,
      :source_kind,
      :source_id,
      :source_reference,
      :event,
      :entry_id,
      :entry_number,
      :entry_date,
      :total,
      :currency_code,
      :reason,
      :actor_user_id,
      :actor_impersonator_id,
      :occurred_at
    ])
  end

  defp query(scope, company_id) do
    from(e in Tenancy.scope_query(PostingEvent, scope), where: e.company_id == ^company_id)
  end
end
