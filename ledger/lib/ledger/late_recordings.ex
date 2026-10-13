defmodule Bilimbi.Finance.Ledger.LateRecordings do
  @moduledoc false

  # Entries recorded late, and their independent reviews. An entry's days are
  # whole UTC days from its entry date (its transaction date) to the day the
  # database stamped it. The facade authorizes and takes the company lock.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Ledger.{Duties, Entry, LateRecordingReview}

  @approaching_days 45
  @late_days 60

  @doc "The days from entry date to recording at which an entry is listed, and at which it is late."
  def thresholds, do: %{approaching_days: @approaching_days, late_days: @late_days}

  @doc "Whole UTC days from an entry's date to its recording."
  def days(%Entry{entry_date: entry_date, posted_at: posted_at}),
    do: Date.diff(DateTime.to_date(posted_at), entry_date)

  @doc "`\"late\"` past the late threshold, `\"approaching\"` otherwise (within the listed range)."
  def status(days) when days > @late_days, do: "late"
  def status(_days), do: "approaching"

  @doc "The posted entry of the company, or nil."
  def entry(scope, company_id, entry_id) when is_integer(entry_id) do
    scope
    |> entries_query(company_id)
    |> where([e], e.id == ^entry_id)
    |> Repo.one()
  end

  def entry(_scope, _company_id, _entry_id), do: nil

  @doc """
  The listed entries, oldest number first, each with its review or nil.
  `filters` has `status` (nil, `"approaching"` or `"late"`), `reviewed` (nil,
  true or false), `limit`, and `after` (an entry number).
  """
  def list(scope, company_id, filters) do
    entries =
      scope
      |> entries_query(company_id)
      |> by_status(filters.status)
      |> reviewed(scope, filters.reviewed)
      |> after_number(filters.after)
      |> order_by([e], asc: e.entry_number)
      |> limit(^filters.limit)
      |> Repo.all()

    reviews = reviews_by_entry(scope, Enum.map(entries, & &1.id))
    Enum.map(entries, &%{entry: &1, review: Map.get(reviews, &1.id)})
  end

  @doc """
  Appends an independent review of a late entry. The entry must be listed
  (`:not_late_recorded`), reviewed once (`:already_reviewed`), and not posted
  by whoever reviews it or whoever they impersonate (`:reviewer_not_independent`).
  """
  def review(scope, company_id, entry, attributes) do
    %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)
    reviewer = {user_id, impersonator_id}
    poster = {entry.posted_by_user_id, entry.posted_by_impersonator_id}

    cond do
      days(entry) < @approaching_days ->
        {:error, :not_late_recorded}

      reviews_by_entry(scope, [entry.id]) != %{} ->
        {:error, :already_reviewed}

      Duties.same_person?(reviewer, poster) ->
        {:error, :reviewer_not_independent}

      true ->
        %LateRecordingReview{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          entry_id: entry.id,
          reviewed_by_user_id: user_id,
          reviewed_by_impersonator_id: impersonator_id
        }
        |> LateRecordingReview.changeset(attributes)
        |> Repo.insert()
    end
  end

  defp by_status(query, nil) do
    where(
      query,
      [e],
      fragment("CAST(? AS date) - ? >= ?", e.posted_at, e.entry_date, ^@approaching_days)
    )
  end

  defp by_status(query, "approaching") do
    where(
      query,
      [e],
      fragment(
        "CAST(? AS date) - ? BETWEEN ? AND ?",
        e.posted_at,
        e.entry_date,
        ^@approaching_days,
        ^@late_days
      )
    )
  end

  defp by_status(query, "late") do
    where(query, [e], fragment("CAST(? AS date) - ? > ?", e.posted_at, e.entry_date, ^@late_days))
  end

  defp reviewed(query, _scope, nil), do: query

  defp reviewed(query, scope, reviewed?) do
    reviewed_ids = select(reviews_query(scope), [r], r.entry_id)

    if reviewed?,
      do: where(query, [e], e.id in subquery(reviewed_ids)),
      else: where(query, [e], e.id not in subquery(reviewed_ids))
  end

  defp after_number(query, nil), do: query
  defp after_number(query, number), do: where(query, [e], e.entry_number > ^number)

  defp reviews_by_entry(scope, entry_ids) do
    scope
    |> reviews_query()
    |> where([r], r.entry_id in ^entry_ids)
    |> Repo.all()
    |> Map.new(&{&1.entry_id, &1})
  end

  defp entries_query(scope, company_id),
    do: where(Tenancy.scope_query(Entry, scope), [e], e.company_id == ^company_id)

  defp reviews_query(scope), do: Tenancy.scope_query(LateRecordingReview, scope)
end
