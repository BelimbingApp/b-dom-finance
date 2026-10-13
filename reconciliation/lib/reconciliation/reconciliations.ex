defmodule Bilimbi.Finance.Reconciliation.Reconciliations do
  @moduledoc false
  # A bank account's reconciliations: the figures as of a statement end
  # date, and the events that open, finalise, and abandon them. The facade
  # authorizes every call and holds the company lock for writes.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Ledger

  alias Bilimbi.Finance.Reconciliation.{
    Matching,
    Records,
    ReconciliationEvent,
    ReconciliationItem,
    ReconciliationRecord,
    StatementLine
  }

  @zero Decimal.new(0)

  ## Figures

  @doc """
  The reconciliation of the bank account as of `end_date` against
  `statement_balance`, read at the pinned numbers (`through_entry_number`,
  `through_statement_number`, `through_match_event_number`; each defaults
  to the latest). The book balance is the ledger account's debits less
  credits through `end_date`, summed by PostgreSQL. The items that explain
  the difference are the statement lines through `end_date` with no
  standing match, the entries through `end_date` with none, and each
  standing match whose two sides do not both fall through `end_date`
  (`timing`). `difference` is the statement balance less the book balance,
  less the unmatched statement lines, plus the unmatched entries, plus the
  timing items; zero means the two balances are explained.
  """
  def compute(scope, company_id, bank_account, end_date, statement_balance, pins \\ []) do
    through_statement =
      Keyword.get(pins, :through_statement_number) ||
        Matching.last_statement_number(scope, company_id)

    through_event =
      Keyword.get(pins, :through_match_event_number) ||
        Matching.last_event_number(scope, company_id)

    with {:ok, totals} <-
           Ledger.account_totals(
             scope,
             company_id,
             [to: end_date] ++ Keyword.take(pins, [:through_entry_number])
           ),
         through_entry = totals.through_entry_number,
         {:ok, unmatched} <-
           Matching.unmatched(scope, company_id, bank_account,
             to: end_date,
             through_entry_number: through_entry,
             through_statement_number: through_statement,
             through_match_event_number: through_event
           ) do
      book_balance =
        case Enum.find(totals.rows, &(&1.id == bank_account.ledger_account_id)) do
          nil -> @zero
          row -> Decimal.sub(row.debits, row.credits)
        end

      timing =
        scope
        |> Matching.standing_matches(company_id, bank_account.id, through_event)
        |> Enum.flat_map(&timing_item(scope, company_id, &1, end_date))

      lines = Enum.map(unmatched.lines, &line_item/1)
      entries = Enum.map(unmatched.entries, &entry_item/1)

      difference =
        statement_balance
        |> Decimal.sub(book_balance)
        |> Decimal.sub(sum(lines))
        |> Decimal.add(sum(entries))
        |> Decimal.add(sum(timing))

      {:ok,
       %{
         bank_account_id: bank_account.id,
         end_date: end_date,
         statement_balance: statement_balance,
         book_balance: book_balance,
         difference: difference,
         currency_code: totals.currency_code,
         minor_units: totals.minor_units,
         through_entry_number: through_entry,
         through_statement_number: through_statement,
         through_match_event_number: through_event,
         items: lines ++ entries ++ timing
       }}
    end
  end

  defp line_item(line) do
    %{
      kind: "statement_line",
      statement_line_id: line.id,
      entry_id: nil,
      match_id: nil,
      item_date: line.line_date,
      description: line.description,
      reference: line.reference,
      amount: line.amount
    }
  end

  defp entry_item(item) do
    %{
      kind: "entry",
      statement_line_id: nil,
      entry_id: item.entry_id,
      match_id: nil,
      item_date: item.entry_date,
      description: "Entry #{item.entry_number}: #{item.description}",
      reference: item.reference,
      amount: item.amount
    }
  end

  # A match whose statement side through the end date differs from its
  # ledger side through the end date is a timing difference: money the books
  # and the bank saw on either side of the date.
  defp timing_item(scope, company_id, match, end_date) do
    line_ids = Enum.map(match.lines, & &1.statement_line_id)

    statement_side =
      StatementLine
      |> Records.query(scope, company_id)
      |> where([l], l.id in ^line_ids and l.line_date <= ^end_date)
      |> select([l], coalesce(sum(l.amount), 0))
      |> Repo.one()

    ledger_side =
      match.entries
      |> Enum.filter(&(Date.compare(&1.entry_date, end_date) != :gt))
      |> Enum.reduce(@zero, &Decimal.add(&1.amount, &2))

    amount = Decimal.sub(ledger_side, statement_side)

    if Decimal.equal?(amount, 0) do
      []
    else
      dates =
        Enum.map(match.entries, & &1.entry_date) ++
          (StatementLine
           |> Records.query(scope, company_id)
           |> where([l], l.id in ^line_ids)
           |> select([l], l.line_date)
           |> Repo.all())

      [
        %{
          kind: "timing",
          statement_line_id: nil,
          entry_id: nil,
          match_id: match.id,
          item_date:
            dates
            |> Enum.filter(&(Date.compare(&1, end_date) != :gt))
            |> Enum.max(Date, fn -> end_date end),
          description: "Match #{match.match_number}: cleared after the statement date",
          reference: nil,
          amount: amount
        }
      ]
    end
  end

  defp sum(items), do: Enum.reduce(items, @zero, &Decimal.add(&1.amount, &2))

  ## Opening, finalising, abandoning

  @doc "Opens a reconciliation of the bank account: `end_date` and `statement_balance`."
  def open(scope, company_id, bank_account, book, attributes) do
    {user_id, impersonator_id} = Records.actor_ids(scope)

    changeset =
      %ReconciliationRecord{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        bank_account_id: bank_account.id,
        opened_by_user_id: user_id,
        opened_by_impersonator_id: impersonator_id
      }
      |> ReconciliationRecord.changeset(attributes, book.minor_units)
      |> validate_open(scope, company_id, bank_account.id)

    with {:ok, reconciliation} <- Repo.insert(changeset),
         {:ok, _event} <- record_event(scope, company_id, reconciliation, "opened", %{}, []) do
      {:ok, view(fetch!(scope, company_id, reconciliation.id))}
    end
  end

  # One open reconciliation per bank account, each ending after the last
  # finalised one; the database refuses the same.
  defp validate_open(changeset, scope, company_id, bank_account_id) do
    others = scope |> list_records(company_id, bank_account_id) |> Enum.map(&{&1, status(&1)})

    changeset =
      if Enum.any?(others, fn {_r, status} -> status == "open" end),
        do:
          Ecto.Changeset.add_error(
            changeset,
            :bank_account_id,
            "already has an open reconciliation"
          ),
        else: changeset

    last =
      others
      |> Enum.filter(fn {_r, status} -> status == "finalised" end)
      |> Enum.map(fn {r, _status} -> r.end_date end)
      |> Enum.max(Date, fn -> nil end)

    Ecto.Changeset.validate_change(changeset, :end_date, fn :end_date, date ->
      if last && Date.compare(date, last) != :gt,
        do: [end_date: "must be after the last finalised reconciliation, #{last}"],
        else: []
    end)
  end

  @doc """
  Finalises an open reconciliation: reads its figures now, refuses a
  difference other than zero (`{:error, {:difference, amount}}`), and
  records the `finalised` event with the figures and the numbers they were
  read at, and the items as they stood.
  """
  def finalise(scope, company_id, reconciliation, bank_account) do
    with :ok <- open?(reconciliation),
         {:ok, figures} <-
           compute(
             scope,
             company_id,
             bank_account,
             reconciliation.end_date,
             reconciliation.statement_balance
           ),
         :ok <- zero_difference(figures),
         {:ok, _event} <-
           record_event(scope, company_id, reconciliation, "finalised", %{},
             book_balance: figures.book_balance,
             difference: figures.difference,
             through_entry_number: figures.through_entry_number,
             through_statement_number: figures.through_statement_number,
             through_match_event_number: figures.through_match_event_number
           ) do
      tenant_id = Scope.tenant_id(scope)

      Repo.insert_all(
        ReconciliationItem,
        figures.items
        |> Enum.with_index(1)
        |> Enum.map(fn {item, number} ->
          item
          |> Map.merge(%{
            tenant_id: tenant_id,
            company_id: company_id,
            reconciliation_id: reconciliation.id,
            item_number: number
          })
        end)
      )

      {:ok, view(fetch!(scope, company_id, reconciliation.id))}
    end
  end

  defp open?(reconciliation) do
    case status(reconciliation) do
      "open" -> :ok
      "finalised" -> {:error, :reconciliation_finalised}
      "abandoned" -> {:error, :reconciliation_abandoned}
    end
  end

  defp zero_difference(%{difference: difference}) do
    if Decimal.equal?(difference, 0), do: :ok, else: {:error, {:difference, difference}}
  end

  @doc "Abandons an open reconciliation with a `reason`."
  def abandon(scope, company_id, reconciliation, attributes) do
    with :ok <- open?(reconciliation),
         {:ok, _event} <-
           record_event(scope, company_id, reconciliation, "abandoned", attributes, []) do
      {:ok, view(fetch!(scope, company_id, reconciliation.id))}
    end
  end

  defp record_event(scope, company_id, reconciliation, action, attributes, fields) do
    {user_id, impersonator_id} = Records.actor_ids(scope)

    %ReconciliationEvent{
      tenant_id: Scope.tenant_id(scope),
      company_id: company_id,
      reconciliation_id: reconciliation.id,
      action: action,
      recorded_by_user_id: user_id,
      recorded_by_impersonator_id: impersonator_id
    }
    |> struct(fields)
    |> ReconciliationEvent.changeset(attributes)
    |> Repo.insert()
  end

  ## Report

  @doc """
  A reconciliation with its figures and items: an open one's are read now,
  a finalised one's are the stored snapshot, which the pinned numbers
  reproduce, and an abandoned one has none.
  """
  def report(scope, company_id, reconciliation, bank_account) do
    case status(reconciliation) do
      "open" ->
        with {:ok, figures} <-
               compute(
                 scope,
                 company_id,
                 bank_account,
                 reconciliation.end_date,
                 reconciliation.statement_balance
               ) do
          {:ok,
           Map.merge(
             view(reconciliation),
             Map.drop(figures, [:bank_account_id, :end_date, :statement_balance])
           )}
        end

      "finalised" ->
        event = Enum.find(reconciliation.events, &(&1.action == "finalised"))

        with {:ok, book} <- Ledger.get_book(scope, company_id) do
          {:ok,
           Map.merge(view(reconciliation), %{
             book_balance: event.book_balance,
             difference: event.difference,
             currency_code: book.currency_code,
             minor_units: book.minor_units,
             through_entry_number: event.through_entry_number,
             through_statement_number: event.through_statement_number,
             through_match_event_number: event.through_match_event_number,
             items: Enum.map(reconciliation.items, &item_view/1)
           })}
        end

      "abandoned" ->
        {:ok, view(reconciliation)}
    end
  end

  ## Reading

  def fetch(scope, company_id, reconciliation_id) do
    ReconciliationRecord
    |> Records.query(scope, company_id)
    |> where([r], r.id == ^reconciliation_id)
    |> preload_parts(scope, company_id)
    |> Repo.one()
  end

  def fetch!(scope, company_id, reconciliation_id),
    do:
      fetch(scope, company_id, reconciliation_id) ||
        raise("reconciliation #{reconciliation_id} vanished")

  defp list_records(scope, company_id, bank_account_id) do
    ReconciliationRecord
    |> Records.query(scope, company_id)
    |> where([r], r.bank_account_id == ^bank_account_id)
    |> order_by([r], asc: r.reconciliation_number)
    |> preload_parts(scope, company_id)
    |> Repo.all()
  end

  @doc "The bank account's reconciliations, oldest first."
  def list(scope, company_id, bank_account_id) do
    scope |> list_records(company_id, bank_account_id) |> Enum.map(&view/1)
  end

  defp preload_parts(query, scope, company_id) do
    preload(query,
      events:
        ^order_by(Records.query(ReconciliationEvent, scope, company_id), asc: :event_number),
      items: ^order_by(Records.query(ReconciliationItem, scope, company_id), asc: :item_number)
    )
  end

  def status(%ReconciliationRecord{events: events}) do
    cond do
      Enum.any?(events, &(&1.action == "finalised")) -> "finalised"
      Enum.any?(events, &(&1.action == "abandoned")) -> "abandoned"
      true -> "open"
    end
  end

  def view(%ReconciliationRecord{} = reconciliation) do
    reconciliation
    |> Map.take([
      :id,
      :bank_account_id,
      :reconciliation_number,
      :end_date,
      :statement_balance,
      :opened_by_user_id,
      :opened_by_impersonator_id,
      :opened_at
    ])
    |> Map.merge(%{
      status: status(reconciliation),
      events: Enum.map(reconciliation.events, &event_view/1)
    })
  end

  def event_view(%ReconciliationEvent{} = event) do
    Map.take(event, [
      :event_number,
      :action,
      :reason,
      :book_balance,
      :difference,
      :through_entry_number,
      :through_statement_number,
      :through_match_event_number,
      :recorded_by_user_id,
      :recorded_by_impersonator_id,
      :recorded_at
    ])
  end

  def item_view(%ReconciliationItem{} = item) do
    Map.take(item, [
      :kind,
      :statement_line_id,
      :entry_id,
      :match_id,
      :item_date,
      :description,
      :reference,
      :amount
    ])
  end
end
