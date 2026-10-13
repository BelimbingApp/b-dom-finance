defmodule Bilimbi.Finance.Reconciliation.Matching do
  @moduledoc false
  # Statement lines against ledger entries on the bank account's ledger
  # account: what is unmatched on each side, suggested matches, and the
  # matches themselves with the events that make and unmake them. The facade
  # authorizes every call and holds the company lock for writes.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Ledger

  alias Bilimbi.Finance.Reconciliation.{
    Import,
    Match,
    MatchEntry,
    MatchEvent,
    MatchLine,
    Records,
    Statement,
    StatementLine
  }

  @page 500

  ## Ledger side

  @doc """
  Every entry with a posting on the bank account's ledger account, dated
  through `to` and numbered through `through_entry_number` (both optional),
  as `%{entry_id, entry_number, entry_date, description, reference,
  amount}`; `amount` is the entry's debits less its credits on that account,
  and an entry whose two cancel is left out. Read through the ledger facade
  page by page.
  """
  def ledger_items(scope, company_id, bank_account, options) do
    base =
      [account_id: bank_account.ledger_account_id, limit: @page] ++
        Keyword.take(options, [:to, :through_entry_number])

    collect(scope, company_id, bank_account.ledger_account_id, base, nil, [])
  end

  defp collect(scope, company_id, account_id, options, cursor, acc) do
    options = if cursor, do: Keyword.put(options, :after, cursor), else: options

    with {:ok, entries} <- Ledger.list_entries(scope, company_id, options) do
      items = entries |> Enum.map(&ledger_item(&1, account_id)) |> Enum.reject(&is_nil/1)
      acc = Enum.reverse(items, acc)

      if length(entries) < @page do
        {:ok, Enum.reverse(acc)}
      else
        last = List.last(entries)
        collect(scope, company_id, account_id, options, {last.entry_date, last.id}, acc)
      end
    end
  end

  @doc "One entry's side of the bank account, or nil when its lines there cancel."
  def ledger_item(entry, account_id) do
    amount =
      entry.lines
      |> Enum.filter(&(&1.account_id == account_id))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(Decimal.sub(&1.debit, &1.credit), &2))

    if Decimal.equal?(amount, 0) do
      nil
    else
      %{
        entry_id: entry.id,
        entry_number: entry.entry_number,
        entry_date: entry.entry_date,
        description: entry.description,
        reference: entry.reference,
        amount: amount
      }
    end
  end

  ## Standing matches

  # A match stands at match-event number `through` (nil for now) when its
  # `matched` event is numbered through it and no `unmatched` event is.
  defp standing_query(scope, company_id, bank_account_id, through) do
    unmatched =
      MatchEvent
      |> Records.query(scope, company_id)
      |> where([e], e.action == "unmatched")
      |> through_bound(through)

    from(e in Records.query(MatchEvent, scope, company_id),
      join: m in ^Records.query(Match, scope, company_id),
      on: m.id == e.match_id,
      where: m.bank_account_id == ^bank_account_id and e.action == "matched",
      where: e.match_id not in subquery(select(unmatched, [u], u.match_id)),
      select: m.id
    )
    |> through_bound(through)
  end

  defp through_bound(query, nil), do: query
  defp through_bound(query, through), do: where(query, [e], e.event_number <= ^through)

  @doc "The IDs of the bank account's standing matches at `through` (nil for now)."
  def standing_match_ids(scope, company_id, bank_account_id, through \\ nil) do
    scope |> standing_query(company_id, bank_account_id, through) |> Repo.all()
  end

  @doc "The standing matches at `through` with their lines, entries, and events."
  def standing_matches(scope, company_id, bank_account_id, through \\ nil) do
    ids = standing_query(scope, company_id, bank_account_id, through)

    Match
    |> Records.query(scope, company_id)
    |> where([m], m.id in subquery(ids))
    |> preload_parts(scope, company_id)
    |> order_by([m], asc: m.match_number)
    |> Repo.all()
  end

  defp preload_parts(query, scope, company_id) do
    preload(query,
      lines: ^Records.query(MatchLine, scope, company_id),
      entries: ^order_by(Records.query(MatchEntry, scope, company_id), asc: :entry_number),
      events: ^order_by(Records.query(MatchEvent, scope, company_id), asc: :event_number)
    )
  end

  @doc "The latest match-event number of the company, 0 before any."
  def last_event_number(scope, company_id) do
    MatchEvent
    |> Records.query(scope, company_id)
    |> select([e], coalesce(max(e.event_number), 0))
    |> Repo.one()
  end

  @doc "The latest statement number of the company, 0 before any."
  def last_statement_number(scope, company_id) do
    Statement
    |> Records.query(scope, company_id)
    |> select([s], coalesce(max(s.statement_number), 0))
    |> Repo.one()
  end

  ## Unmatched

  @doc """
  The bank account's statement lines dated through `to` on statements
  numbered through `through_statement_number` (both optional), as line
  views with their statement number.
  """
  def statement_lines(scope, company_id, bank_account_id, options) do
    from(l in Records.query(StatementLine, scope, company_id),
      join: s in ^Records.query(Statement, scope, company_id),
      on: s.id == l.statement_id,
      where: l.bank_account_id == ^bank_account_id,
      order_by: [asc: l.line_date, asc: s.statement_number, asc: l.line_number],
      select: {l, s.statement_number}
    )
    |> line_bound(:to, Keyword.get(options, :to))
    |> line_bound(:through_statement_number, Keyword.get(options, :through_statement_number))
    |> Repo.all()
    |> Enum.map(fn {line, number} ->
      line |> Import.line_view() |> Map.put(:statement_number, number)
    end)
  end

  defp line_bound(query, _bound, nil), do: query
  defp line_bound(query, :to, date), do: where(query, [l, _s], l.line_date <= ^date)

  defp line_bound(query, :through_statement_number, number),
    do: where(query, [_l, s], s.statement_number <= ^number)

  @doc "The statement line IDs and entry IDs the standing matches hold."
  def taken(scope, company_id, bank_account_id, through \\ nil) do
    ids = standing_query(scope, company_id, bank_account_id, through)

    lines =
      MatchLine
      |> Records.query(scope, company_id)
      |> where([l], l.match_id in subquery(ids))
      |> select([l], l.statement_line_id)
      |> Repo.all()

    entries =
      MatchEntry
      |> Records.query(scope, company_id)
      |> where([e], e.match_id in subquery(ids))
      |> select([e], e.entry_id)
      |> Repo.all()

    %{lines: MapSet.new(lines), entries: MapSet.new(entries)}
  end

  @doc """
  What stands unmatched on each side: `%{lines, entries}`. Options `to`,
  `through_entry_number`, `through_statement_number`, and
  `through_match_event_number` pin the reading.
  """
  def unmatched(scope, company_id, bank_account, options \\ []) do
    with {:ok, items} <-
           ledger_items(
             scope,
             company_id,
             bank_account,
             Keyword.take(options, [:to, :through_entry_number])
           ) do
      taken = taken(scope, company_id, bank_account.id, options[:through_match_event_number])

      lines =
        scope
        |> statement_lines(
          company_id,
          bank_account.id,
          Keyword.take(options, [:to, :through_statement_number])
        )
        |> Enum.reject(&MapSet.member?(taken.lines, &1.id))

      {:ok,
       %{lines: lines, entries: Enum.reject(items, &MapSet.member?(taken.entries, &1.entry_id))}}
    end
  end

  ## Suggestions

  @doc """
  One-to-one suggestions: for each unmatched statement line, the unmatched
  entry of the same amount dated within `window_days` of it, preferring one
  whose reference or description names the line's reference (or the other
  way round), then the nearest date. Each entry is suggested once. Returns
  `%{statement_line_id => entry item}`.
  """
  def suggestions(lines, entries, window_days) do
    by_amount = Enum.group_by(entries, &Decimal.to_string(Decimal.normalize(&1.amount), :normal))

    {suggested, _used} =
      Enum.reduce(lines, {%{}, MapSet.new()}, fn line, {acc, used} ->
        candidates =
          by_amount
          |> Map.get(Decimal.to_string(Decimal.normalize(line.amount), :normal), [])
          |> Enum.reject(&MapSet.member?(used, &1.entry_id))
          |> Enum.filter(&(abs(Date.diff(&1.entry_date, line.line_date)) <= window_days))
          |> Enum.sort_by(
            &{if(reference_hit?(line, &1), do: 0, else: 1),
             abs(Date.diff(&1.entry_date, line.line_date)), &1.entry_number}
          )

        case candidates do
          [] -> {acc, used}
          [best | _] -> {Map.put(acc, line.id, best), MapSet.put(used, best.entry_id)}
        end
      end)

    suggested
  end

  defp reference_hit?(line, item) do
    needle = normalize(line.reference)
    haystacks = Enum.map([item.reference, item.description], &normalize/1)
    entry_needle = normalize(item.reference)

    (needle != "" and Enum.any?(haystacks, &String.contains?(&1, needle))) or
      (entry_needle != "" and String.contains?(normalize(line.description), entry_needle))
  end

  defp normalize(nil), do: ""
  defp normalize(text), do: text |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")

  ## Matching

  @doc """
  Matches `statement_line_ids` of the bank account with `entry_ids` on its
  ledger account, with an optional `note`. The two sides must be unmatched
  and sum to the same amount.
  """
  def match(scope, company_id, bank_account, attributes) do
    line_ids = ids(Records.fetch(attributes, :statement_line_ids))
    entry_ids = ids(Records.fetch(attributes, :entry_ids))

    with :ok <- both_sides(line_ids, entry_ids),
         {:ok, lines} <- own_lines(scope, company_id, bank_account.id, line_ids),
         {:ok, items} <- own_entries(scope, company_id, bank_account, entry_ids),
         :ok <- free(scope, company_id, bank_account.id, lines, items),
         :ok <- balanced(lines, items) do
      insert_match(scope, company_id, bank_account, lines, items, attributes)
    end
  end

  defp ids(nil), do: []
  defp ids(list) when is_list(list), do: list |> Enum.map(&Records.id/1) |> Enum.uniq()
  defp ids(_other), do: [nil]

  defp both_sides(line_ids, entry_ids) do
    if line_ids == [] or entry_ids == [] or nil in line_ids or nil in entry_ids,
      do: {:error, :invalid_selection},
      else: :ok
  end

  defp own_lines(scope, company_id, bank_account_id, line_ids) do
    lines =
      StatementLine
      |> Records.query(scope, company_id)
      |> where([l], l.bank_account_id == ^bank_account_id and l.id in ^line_ids)
      |> Repo.all()

    if length(lines) == length(line_ids),
      do: {:ok, lines},
      else: {:error, :statement_line_not_found}
  end

  defp own_entries(scope, company_id, bank_account, entry_ids) do
    Enum.reduce_while(entry_ids, {:ok, []}, fn entry_id, {:ok, acc} ->
      case Ledger.get_entry(scope, company_id, entry_id) do
        {:ok, entry} ->
          case ledger_item(entry, bank_account.ledger_account_id) do
            nil -> {:halt, {:error, :entry_not_on_account}}
            item -> {:cont, {:ok, [item | acc]}}
          end

        {:error, :entry_not_found} ->
          {:halt, {:error, :entry_not_found}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp free(scope, company_id, bank_account_id, lines, items) do
    taken = taken(scope, company_id, bank_account_id)

    cond do
      Enum.any?(lines, &MapSet.member?(taken.lines, &1.id)) -> {:error, :statement_line_matched}
      Enum.any?(items, &MapSet.member?(taken.entries, &1.entry_id)) -> {:error, :entry_matched}
      true -> :ok
    end
  end

  defp balanced(lines, items) do
    statement_side = sum(lines, :amount)
    ledger_side = sum(items, :amount)

    if Decimal.equal?(statement_side, ledger_side),
      do: :ok,
      else: {:error, {:unbalanced, statement_side, ledger_side}}
  end

  defp sum(rows, field),
    do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(Map.fetch!(&1, field), &2))

  @doc false
  def insert_match(scope, company_id, bank_account, lines, items, attributes) do
    {user_id, impersonator_id} = Records.actor_ids(scope)
    tenant_id = Scope.tenant_id(scope)

    changeset =
      %Match{
        tenant_id: tenant_id,
        company_id: company_id,
        bank_account_id: bank_account.id,
        matched_by_user_id: user_id,
        matched_by_impersonator_id: impersonator_id
      }
      |> Match.changeset(attributes)

    with {:ok, match} <- Repo.insert(changeset) do
      Repo.insert_all(
        MatchLine,
        for line <- lines do
          %{
            tenant_id: tenant_id,
            company_id: company_id,
            match_id: match.id,
            statement_line_id: line.id
          }
        end
      )

      Repo.insert_all(
        MatchEntry,
        for item <- items do
          %{
            tenant_id: tenant_id,
            company_id: company_id,
            match_id: match.id,
            bank_account_id: bank_account.id,
            entry_id: item.entry_id,
            entry_number: item.entry_number,
            entry_date: item.entry_date,
            description: item.description,
            reference: item.reference,
            amount: item.amount
          }
        end
      )

      with {:ok, _event} <- record_event(scope, company_id, match, "matched", %{}) do
        {:ok, match_view(fetch!(scope, company_id, match.id))}
      end
    end
  end

  @doc """
  Records the `unmatched` event of a standing match with a `reason`. A match
  a finalised reconciliation counted is kept (`{:error, :match_finalised}`).
  """
  def unmatch(scope, company_id, match, attributes) do
    cond do
      match_status(match) != "matched" ->
        {:error, :match_not_standing}

      finalised?(scope, company_id, match) ->
        {:error, :match_finalised}

      true ->
        with {:ok, _event} <- record_event(scope, company_id, match, "unmatched", attributes) do
          {:ok, match_view(fetch!(scope, company_id, match.id))}
        end
    end
  end

  defp finalised?(scope, company_id, match) do
    matched = Enum.find(match.events, &(&1.action == "matched"))

    from(
      e in Records.query(Bilimbi.Finance.Reconciliation.ReconciliationEvent, scope, company_id),
      join:
        r in ^Records.query(
          Bilimbi.Finance.Reconciliation.ReconciliationRecord,
          scope,
          company_id
        ),
      on: r.id == e.reconciliation_id,
      where: r.bank_account_id == ^match.bank_account_id and e.action == "finalised",
      where: e.through_match_event_number >= ^matched.event_number
    )
    |> Repo.exists?()
  end

  defp record_event(scope, company_id, match, action, attributes) do
    {user_id, impersonator_id} = Records.actor_ids(scope)

    %MatchEvent{
      tenant_id: Scope.tenant_id(scope),
      company_id: company_id,
      match_id: match.id,
      action: action,
      recorded_by_user_id: user_id,
      recorded_by_impersonator_id: impersonator_id
    }
    |> MatchEvent.changeset(attributes)
    |> Repo.insert()
  end

  ## Reading

  def fetch(scope, company_id, match_id) do
    Match
    |> Records.query(scope, company_id)
    |> where([m], m.id == ^match_id)
    |> preload_parts(scope, company_id)
    |> Repo.one()
  end

  def fetch!(scope, company_id, match_id),
    do: fetch(scope, company_id, match_id) || raise("match #{match_id} vanished")

  @doc "The bank account's matches, newest first, paged by `limit` and `after`."
  def list(scope, company_id, bank_account_id, options) do
    with {:ok, limit, cursor} <- Records.page_options(options) do
      matches =
        Match
        |> Records.query(scope, company_id)
        |> where([m], m.bank_account_id == ^bank_account_id)
        |> Records.page(limit, cursor)
        |> preload_parts(scope, company_id)
        |> Repo.all()

      {:ok, Enum.map(matches, &match_view/1)}
    end
  end

  def match_status(%Match{events: events}) do
    if Enum.any?(events, &(&1.action == "unmatched")), do: "unmatched", else: "matched"
  end

  def match_view(%Match{} = match) do
    match
    |> Map.take([
      :id,
      :bank_account_id,
      :match_number,
      :note,
      :matched_by_user_id,
      :matched_by_impersonator_id,
      :matched_at
    ])
    |> Map.merge(%{
      status: match_status(match),
      statement_line_ids: Enum.map(match.lines, & &1.statement_line_id),
      entries: Enum.map(match.entries, &entry_view/1),
      events: Enum.map(match.events, &event_view/1)
    })
  end

  def entry_view(%MatchEntry{} = entry),
    do:
      Map.take(entry, [:entry_id, :entry_number, :entry_date, :description, :reference, :amount])

  def event_view(%MatchEvent{} = event) do
    Map.take(event, [
      :event_number,
      :action,
      :reason,
      :recorded_by_user_id,
      :recorded_by_impersonator_id,
      :recorded_at
    ])
  end
end
