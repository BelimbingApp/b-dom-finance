defmodule Bilimbi.Finance.Payables.Balances do
  @moduledoc false
  # What is owed on posted bills, now or as of a date and a ledger entry
  # number. Callers authorize first; every query starts from the scope.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Payables.{Allocation, Document, Payment}

  @end_of_time ~D[9999-12-31]
  @max_bigint 9_223_372_036_854_775_807

  @doc """
  What is still owed on each posted bill among `documents`, by ID: now, or as
  of `as_of`, when a bill dated after it is left out.
  """
  def outstanding(scope, company_id, documents, as_of \\ @end_of_time) do
    case bill_ids(documents) do
      [] ->
        %{}

      ids ->
        scope
        |> owed_query(company_id, as_of, @max_bigint, ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1.owed})
    end
  end

  @doc """
  The least each posted bill among `documents` is owed on any date from
  `since` on, by ID: on `since`, on each later date a payment, a payment
  reversal, or a debit note against it is dated, and now. A new amount taken
  off a bill fits only if it fits this least.
  """
  def lowest_outstanding(scope, company_id, documents, %Date{} = since) do
    case bill_ids(documents) do
      [] ->
        %{}

      ids ->
        [since | event_dates(scope, company_id, ids, since)]
        |> Enum.map(&outstanding(scope, company_id, documents, &1))
        |> Enum.reduce(outstanding(scope, company_id, documents), fn owed, lowest ->
          Map.merge(lowest, owed, fn _id, left, right -> Decimal.min(left, right) end)
        end)
    end
  end

  defp bill_ids(documents),
    do: for(%Document{document_type: "bill", status: "posted", id: id} <- documents, do: id)

  defp event_dates(scope, company_id, ids, since) do
    paid =
      from(a in Tenancy.scope_query(Allocation, scope),
        join: p in ^Tenancy.scope_query(Payment, scope),
        on: p.id == a.payment_id,
        left_join: r in ^Tenancy.scope_query(Payment, scope),
        on: r.reverses_payment_id == p.id,
        where: a.company_id == ^company_id and a.document_id in ^ids,
        select: [p.payment_date, r.payment_date]
      )

    noted =
      from(d in Tenancy.scope_query(Document, scope),
        where: d.company_id == ^company_id and d.document_type == "debit_note",
        where: d.status == "posted" and d.corrects_document_id in ^ids,
        select: [d.document_date]
      )

    (Repo.all(paid) ++ Repo.all(noted))
    |> List.flatten()
    |> Enum.filter(&(&1 && Date.compare(&1, since) == :gt))
    |> Enum.uniq()
  end

  @doc """
  What is owed on every posted bill as of a date and through an entry
  number, summed on the payable account each bill recorded, by account ID.
  """
  def owed_by_account(scope, company_id, as_of, through) do
    from(o in subquery(owed_query(scope, company_id, as_of, through, nil)),
      join: b in ^Tenancy.scope_query(Document, scope),
      on: b.id == o.id,
      group_by: b.payable_account_id,
      select: {b.payable_account_id, sum(o.owed)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "The aged payables report; see `Bilimbi.Finance.Payables.aged_payables/4`."
  def aged_payables(scope, company_id, as_of, through, bucket_days) do
    through = through || last_entry_number(scope, company_id)
    owed = owed_query(scope, company_id, as_of, through, nil)
    empty = List.duplicate(Decimal.new(0), length(bucket_days) + 2)

    {owing, exceptions} =
      from(o in subquery(owed),
        join: b in ^Tenancy.scope_query(Document, scope),
        on: b.id == o.id,
        where: o.owed != 0,
        order_by: [asc: b.party_key, asc: b.due_date, asc: b.id],
        select: {b, o.owed}
      )
      |> Repo.all()
      |> Enum.split_with(fn {_bill, owed} -> Decimal.gt?(owed, 0) end)

    exceptions = Enum.map(exceptions, fn {bill, owed} -> exception(bill, owed) end)

    parties =
      owing
      |> Enum.chunk_by(fn {bill, _owed} -> bill.party_key end)
      |> Enum.map(fn [{first, _owed} | _rest] = bills ->
        documents = Enum.map(bills, fn {bill, owed} -> row(bill, owed, as_of, bucket_days) end)

        latest =
          bills
          |> Enum.map(&elem(&1, 0))
          |> Enum.max_by(&{Date.to_gregorian_days(&1.document_date), &1.id})

        %{
          party_key: first.party_key,
          party_name: latest.party_name,
          documents: documents,
          buckets: add_to_buckets(documents, empty),
          total: sum(documents, :outstanding)
        }
      end)

    %{
      company_id: company_id,
      as_of: as_of,
      through_entry_number: through,
      bucket_days: bucket_days,
      parties: parties,
      buckets: Enum.reduce(parties, empty, &add_buckets(&1.buckets, &2)),
      total: sum(parties, :total),
      exceptions: exceptions,
      exceptions_total: sum(exceptions, :outstanding)
    }
  end

  # Each posted bill's total less its debit notes and the payments allocated
  # to it, counting only what is dated on or before `as_of` and posted at or
  # before ledger entry `through`. A payment reversed by then counts as
  # unpaid. `ids` limits the bills, and the sums over their debit notes and
  # allocations, to those bills; nil takes every bill of the company.
  defp owed_query(scope, company_id, as_of, through, ids) do
    debit_notes =
      from(d in Tenancy.scope_query(Document, scope),
        where: d.company_id == ^company_id and d.document_type == "debit_note",
        where: d.status == "posted" and d.document_date <= ^as_of,
        where: d.entry_number <= ^through,
        group_by: d.corrects_document_id,
        select: %{document_id: d.corrects_document_id, amount: sum(d.total)}
      )
      |> only(:corrects_document_id, ids)

    paid =
      from(a in Tenancy.scope_query(Allocation, scope),
        join: p in ^Tenancy.scope_query(Payment, scope),
        on: p.id == a.payment_id,
        left_join: r in ^Tenancy.scope_query(Payment, scope),
        on:
          r.reverses_payment_id == p.id and r.payment_date <= ^as_of and
            r.entry_number <= ^through,
        where: a.company_id == ^company_id and p.payment_date <= ^as_of,
        where: p.entry_number <= ^through and is_nil(r.id),
        group_by: a.document_id,
        select: %{document_id: a.document_id, amount: sum(a.amount)}
      )
      |> only(:document_id, ids)

    from(b in Tenancy.scope_query(Document, scope),
      left_join: d in subquery(debit_notes),
      on: d.document_id == b.id,
      left_join: p in subquery(paid),
      on: p.document_id == b.id,
      where: b.company_id == ^company_id and b.document_type == "bill",
      where: b.status == "posted" and b.document_date <= ^as_of,
      where: b.entry_number <= ^through,
      select: %{id: b.id, owed: b.total - coalesce(d.amount, 0) - coalesce(p.amount, 0)}
    )
    |> only(:id, ids)
  end

  defp only(query, _field, nil), do: query
  defp only(query, field, ids), do: where(query, [r], field(r, ^field) in ^ids)

  defp row(bill, owed, as_of, bucket_days) do
    days_overdue = Date.diff(as_of, bill.due_date)

    bill
    |> Map.take([
      :id,
      :document_number,
      :party_document_number,
      :document_date,
      :due_date,
      :currency_code,
      :total
    ])
    |> Map.merge(%{
      outstanding: owed,
      days_overdue: max(days_overdue, 0),
      bucket: bucket(days_overdue, bucket_days)
    })
  end

  # A bill owed less than nothing is reported as it stands, outside the aged
  # rows, so the report still adds up to the payable accounts.
  defp exception(bill, owed) do
    bill
    |> Map.take([
      :id,
      :document_number,
      :party_key,
      :party_name,
      :party_document_number,
      :document_date,
      :due_date,
      :currency_code,
      :total
    ])
    |> Map.put(:outstanding, owed)
  end

  # 0 is not yet due; i is overdue up to bucket_days[i - 1]; the last is beyond.
  defp bucket(days_overdue, _bucket_days) when days_overdue <= 0, do: 0

  defp bucket(days_overdue, bucket_days) do
    case Enum.find_index(bucket_days, &(days_overdue <= &1)) do
      nil -> length(bucket_days) + 1
      index -> index + 1
    end
  end

  defp add_to_buckets(documents, empty) do
    Enum.reduce(documents, empty, fn document, buckets ->
      List.update_at(buckets, document.bucket, &Decimal.add(&1, document.outstanding))
    end)
  end

  defp add_buckets(left, right), do: Enum.zip_with(left, right, &Decimal.add/2)

  defp sum(rows, field),
    do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(Map.fetch!(&1, field), &2))

  # The last ledger entry number of a payables posting in the company.
  defp last_entry_number(scope, company_id) do
    documents =
      from(d in Tenancy.scope_query(Document, scope),
        where: d.company_id == ^company_id,
        select: max(d.entry_number)
      )

    payments =
      from(p in Tenancy.scope_query(Payment, scope),
        where: p.company_id == ^company_id,
        select: max(p.entry_number)
      )

    max(Repo.one(documents) || 0, Repo.one(payments) || 0)
  end
end
