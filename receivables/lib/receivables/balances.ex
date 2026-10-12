defmodule Bilimbi.Finance.Receivables.Balances do
  @moduledoc false
  # What issued invoices still owe: their total less their issued credit
  # notes and their allocations from payments that were not reversed. The
  # same rule as the migration's finance_receivables_outstanding().
  #
  # `as_of` and `through` bound every event by its own date and by the
  # ledger entry number it posted, so a report reproduces exactly: the
  # events it counted never change and later ones carry later numbers.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Receivables.{Allocation, Document, Payment, PaymentReversal, Records}

  @latest_date ~D[9999-12-31]

  @doc "Issued invoices of the company, as of a date and through an entry number."
  def invoices(scope, company_id, as_of \\ nil, through \\ nil) do
    {as_of, through} = bounds(as_of, through)

    from(d in Records.query(Document, scope, company_id),
      where: d.kind == "invoice" and d.status == "issued",
      where: d.issue_date <= ^as_of and d.ledger_entry_number <= ^through
    )
  end

  @doc """
  `%{invoice_id => outstanding}` for the invoices `invoice_query` selects,
  counting credit notes, payments, and reversals within the same bounds.
  """
  def outstanding(scope, company_id, invoice_query, as_of \\ nil, through \\ nil) do
    scope
    |> with_settlements(company_id, invoice_query, as_of, through)
    |> select([d, c, a], {d.id, d.total - coalesce(c.amount, 0) - coalesce(a.amount, 0)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  `[{invoice, outstanding}]` for the company's issued invoices that still
  owe something as of a date and through an entry number.
  """
  def owing(scope, company_id, as_of, through) do
    scope
    |> with_settlements(company_id, invoices(scope, company_id, as_of, through), as_of, through)
    |> where([d, c, a], d.total - coalesce(c.amount, 0) - coalesce(a.amount, 0) != 0)
    |> select([d, c, a], {d, d.total - coalesce(c.amount, 0) - coalesce(a.amount, 0)})
    |> Repo.all()
  end

  # Joins each invoice to its credited and allocated totals within bounds.
  defp with_settlements(scope, company_id, invoice_query, as_of, through) do
    {as_of, through} = bounds(as_of, through)

    credited =
      from(c in Records.query(Document, scope, company_id),
        where: c.kind == "credit_note" and c.status == "issued",
        where: c.issue_date <= ^as_of and c.ledger_entry_number <= ^through,
        group_by: c.credited_document_id,
        select: %{document_id: c.credited_document_id, amount: sum(c.total)}
      )

    allocated =
      from(a in Records.query(Allocation, scope, company_id),
        join: p in ^Records.query(Payment, scope, company_id),
        on: p.id == a.payment_id,
        left_join: r in ^Records.query(PaymentReversal, scope, company_id),
        on:
          r.payment_id == p.id and r.reversal_date <= ^as_of and
            r.ledger_entry_number <= ^through,
        where: p.payment_date <= ^as_of and p.ledger_entry_number <= ^through,
        where: is_nil(r.id),
        group_by: a.document_id,
        select: %{document_id: a.document_id, amount: sum(a.amount)}
      )

    from(d in invoice_query,
      left_join: c in subquery(credited),
      on: c.document_id == d.id,
      left_join: a in subquery(allocated),
      on: a.document_id == d.id
    )
  end

  @doc "What one issued invoice owes now, or nil for any other document."
  def outstanding_now(scope, company_id, document_id) do
    query = where(invoices(scope, company_id), [d], d.id == ^document_id)
    Map.get(outstanding(scope, company_id, query), document_id)
  end

  @doc "The last ledger entry number any of the company's receivables posted."
  def last_entry_number(scope, company_id) do
    [Document, Payment, PaymentReversal]
    |> Enum.map(fn schema ->
      Records.query(schema, scope, company_id)
      |> select([r], coalesce(max(r.ledger_entry_number), 0))
      |> Repo.one()
    end)
    |> Enum.max()
  end

  defp bounds(as_of, through), do: {as_of || @latest_date, through || Records.max_bigint()}
end
