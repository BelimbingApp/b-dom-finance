defmodule Bilimbi.Finance.Receivables.TaxReport do
  @moduledoc false
  # The tax issued documents carry, for a module that reports it to a tax
  # authority: sums per document kind and tax code, and the tax share of what
  # customers paid. Every document, payment, and reversal counts by its own
  # date and the ledger entry it posted, so a reading pinned to an entry
  # number reproduces.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Receivables.{Allocation, Balances, Document, Payment}
  alias Bilimbi.Finance.Receivables.{PaymentReversal, Records, TaxLine}

  @max_bigint Records.max_bigint()
  @zero Decimal.new(0)

  # The day after `months` months from the issue date have run, the issue
  # date itself not counted.
  defmacrop due_day(issue_date, months) do
    quote do
      fragment(
        "((? + make_interval(months => ?::integer))::date + 1)",
        unquote(issue_date),
        unquote(months)
      )
    end
  end

  def totals(scope, company_id, options) do
    with {:ok, from, to, through} <- window(options) do
      # A credit note credits an earlier period's invoice when that invoice
      # was issued before the window. Grouped outside, so the flag's
      # parameter appears once.
      lines =
        scope
        |> issued_lines(company_id, from, to, through)
        |> join(:left, [l, d], i in ^Records.query(Document, scope, company_id),
          on: i.id == d.credited_document_id
        )
        |> select([l, d, i], %{
          kind: d.kind,
          document_id: d.id,
          credits_prior_period:
            fragment("coalesce(? < ?, false)", i.issue_date, type(^from, :date)),
          tax_code_id: l.tax_code_id,
          tax_code: l.tax_code,
          tax_rate: l.tax_rate,
          account_id: l.account_id,
          taxable_amount: l.taxable_amount,
          tax_amount: l.tax_amount
        })

      rows =
        from(r in subquery(lines),
          group_by: [
            r.kind,
            r.credits_prior_period,
            r.tax_code_id,
            r.tax_code,
            r.tax_rate,
            r.account_id
          ],
          order_by: [
            asc: r.tax_code,
            asc: r.kind,
            asc: r.credits_prior_period,
            asc: r.tax_rate,
            asc: r.account_id
          ],
          select: %{
            kind: r.kind,
            credits_prior_period: r.credits_prior_period,
            tax_code_id: r.tax_code_id,
            tax_code: r.tax_code,
            tax_rate: r.tax_rate,
            account_id: r.account_id,
            document_count: count(r.document_id, :distinct),
            taxable_amount: sum(r.taxable_amount),
            tax_amount: sum(r.tax_amount)
          }
        )
        |> Repo.all()

      {:ok, rows}
    end
  end

  @doc """
  The tax share of invoices settled in the window, for tax due when payment
  is received. An invoice's due day under the unpaid-period rule is the day
  after `unpaid_months` months from its issue date have run (the issue
  date itself not counted). Three measures:

  - `received`: each allocation of a payment dated in the window before
    its invoice's due day, as that allocation's share of the invoice total,
    less the same share of every such payment reversed in the window before
    that day (a later reversal leaves the unpaid balance to `unpaid`);
  - `unpaid`: each invoice whose due day falls in the window, as the share
    of its total it still owed the day before;
  - `credited_after_due`: the tax lines of credit notes issued in the
    window on an invoice whose due day had passed.

  A share applies to each of the invoice's tax lines; amounts are exact
  sums, rounded by the caller.
  """
  def received_totals(scope, company_id, options) do
    with {:ok, from, to, through} <- window(options),
         :ok <- bounded(from, to),
         {:ok, months} <- months_option(options) do
      through = through || @max_bigint

      rows =
        received(scope, company_id, from, to, through, months) ++
          unpaid(scope, company_id, from, to, through, months) ++
          credited_after_due(scope, company_id, from, to, through, months)

      {:ok, summarise(rows)}
    end
  end

  # `{measure, tax line, invoice ID, taxable share, tax share}` per
  # allocation, reversed allocations negative.
  defp received(scope, company_id, from, to, through, months) do
    paid =
      scope
      |> allocated_lines(company_id, through, months)
      |> where([l, d, a, p], p.payment_date >= ^from and p.payment_date <= ^to)
      |> select([l, d, a, p], {l, d.id, a.amount, d.total})
      |> Repo.all()

    reversed =
      scope
      |> allocated_lines(company_id, through, months)
      |> join(:inner, [l, d, a, p], r in ^Records.query(PaymentReversal, scope, company_id),
        on: r.payment_id == p.id
      )
      |> where([l, d, a, p, r], r.reversal_date >= ^from and r.reversal_date <= ^to)
      |> where([l, d, a, p, r], r.reversal_date < due_day(d.issue_date, ^months))
      |> where([l, d, a, p, r], r.ledger_entry_number <= ^through)
      |> select([l, d, a, p], {l, d.id, a.amount, d.total})
      |> Repo.all()

    Enum.map(paid, &share("received", &1, 1)) ++ Enum.map(reversed, &share("received", &1, -1))
  end

  # Invoice tax lines joined to each allocation of a payment dated before
  # the invoice's due day.
  defp allocated_lines(scope, company_id, through, months) do
    from(l in Records.query(TaxLine, scope, company_id),
      join: d in ^Records.query(Document, scope, company_id),
      on: d.id == l.document_id,
      join: a in ^Records.query(Allocation, scope, company_id),
      on: a.document_id == d.id,
      join: p in ^Records.query(Payment, scope, company_id),
      on: p.id == a.payment_id,
      where: d.kind == "invoice" and d.status == "issued",
      where: d.ledger_entry_number <= ^through and p.ledger_entry_number <= ^through,
      where: p.payment_date < due_day(d.issue_date, ^months)
    )
  end

  defp unpaid(scope, company_id, from, to, through, months) do
    due =
      from(d in Balances.invoices(scope, company_id, nil, through),
        where: due_day(d.issue_date, ^months) >= ^from,
        where: due_day(d.issue_date, ^months) <= ^to,
        select: {d.id, d.total, due_day(d.issue_date, ^months)}
      )
      |> Repo.all()

    owed =
      due
      |> Enum.group_by(fn {_id, _total, day} -> day end, fn {id, _total, _day} -> id end)
      |> Enum.flat_map(fn {day, ids} ->
        query = where(Balances.invoices(scope, company_id, nil, through), [d], d.id in ^ids)

        scope
        |> Balances.outstanding(company_id, query, Date.add(day, -1), through)
        |> Enum.to_list()
      end)
      |> Map.new()

    totals = Map.new(due, fn {id, total, _day} -> {id, total} end)

    from(l in Records.query(TaxLine, scope, company_id),
      where: l.document_id in ^Map.keys(totals)
    )
    |> Repo.all()
    |> Enum.flat_map(fn line ->
      amount = Map.fetch!(owed, line.document_id)
      total = Map.fetch!(totals, line.document_id)

      if Decimal.gt?(amount, 0),
        do: [share("unpaid", {line, line.document_id, amount, total}, 1)],
        else: []
    end)
  end

  defp credited_after_due(scope, company_id, from, to, through, months) do
    from(l in Records.query(TaxLine, scope, company_id),
      join: c in ^Records.query(Document, scope, company_id),
      on: c.id == l.document_id,
      join: d in ^Records.query(Document, scope, company_id),
      on: d.id == c.credited_document_id,
      where: c.kind == "credit_note" and c.status == "issued",
      where: c.issue_date >= ^from and c.issue_date <= ^to,
      where: c.ledger_entry_number <= ^through,
      where: c.issue_date >= due_day(d.issue_date, ^months),
      select: {l, c.id}
    )
    |> Repo.all()
    |> Enum.map(fn {line, id} ->
      {"credited_after_due", line, id, line.taxable_amount, line.tax_amount}
    end)
  end

  defp share(measure, {line, document_id, amount, total}, sign) do
    factor = Decimal.mult(sign, Decimal.div(amount, total))

    {measure, line, document_id, Decimal.mult(line.taxable_amount, factor),
     Decimal.mult(line.tax_amount, factor)}
  end

  defp summarise(rows) do
    rows
    |> Enum.group_by(fn {measure, line, _id, _taxable, _tax} ->
      {measure, line.tax_code_id, line.tax_code, line.tax_rate, line.account_id}
    end)
    |> Enum.map(fn {{measure, tax_code_id, tax_code, rate, account_id}, group} ->
      %{
        measure: measure,
        tax_code_id: tax_code_id,
        tax_code: tax_code,
        tax_rate: rate,
        account_id: account_id,
        document_count: group |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> length(),
        taxable_amount: Enum.reduce(group, @zero, &Decimal.add(elem(&1, 3), &2)),
        tax_amount: Enum.reduce(group, @zero, &Decimal.add(elem(&1, 4), &2))
      }
    end)
    |> Enum.sort_by(&{&1.tax_code, &1.measure, Decimal.to_string(&1.tax_rate), &1.account_id})
  end

  defp issued_lines(scope, company_id, from, to, through) do
    documents =
      Records.query(Document, scope, company_id)
      |> where([d], d.status == "issued")
      |> from_bound(from)
      |> to_bound(to)
      |> through_bound(through)

    from(l in Records.query(TaxLine, scope, company_id),
      join: d in subquery(documents),
      on: d.id == l.document_id
    )
  end

  defp from_bound(query, nil), do: query
  defp from_bound(query, from), do: where(query, [d], d.issue_date >= ^from)

  defp to_bound(query, nil), do: query
  defp to_bound(query, to), do: where(query, [d], d.issue_date <= ^to)

  defp through_bound(query, nil), do: query
  defp through_bound(query, through), do: where(query, [d], d.ledger_entry_number <= ^through)

  defp window(options) do
    from = Keyword.get(options, :from)
    to = Keyword.get(options, :to)
    through = Keyword.get(options, :through_entry_number)

    cond do
      not (optional_date?(from) and optional_date?(to)) ->
        {:error, :invalid_option}

      from && to && Date.compare(from, to) == :gt ->
        {:error, :invalid_option}

      not (is_nil(through) or (is_integer(through) and through in 0..@max_bigint)) ->
        {:error, :invalid_option}

      true ->
        {:ok, from, to, through}
    end
  end

  defp bounded(%Date{}, %Date{}), do: :ok
  defp bounded(_from, _to), do: {:error, :invalid_option}

  defp months_option(options) do
    case Keyword.get(options, :unpaid_months, 12) do
      months when is_integer(months) and months in 1..120 -> {:ok, months}
      _other -> {:error, :invalid_option}
    end
  end

  defp optional_date?(value), do: is_nil(value) or match?(%Date{}, value)
end
