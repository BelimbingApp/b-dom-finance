defmodule Bilimbi.Finance.Receivables.Aging do
  @moduledoc false
  # Aged receivables: what each customer's issued invoices still owe as of a
  # date, by how long past due. The facade authorizes the call.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Receivables.{Balances, Customer, Records}

  def report(scope, company_id, book, as_of, through, bucket_days) do
    through = through || Balances.last_entry_number(scope, company_id)
    buckets = buckets(bucket_days)
    owing = Balances.owing(scope, company_id, as_of, through)

    rows =
      Enum.map(owing, fn {invoice, outstanding} ->
        days = Date.diff(as_of, invoice.due_date)

        %{
          customer_id: invoice.customer_id,
          document_id: invoice.id,
          document_reference: invoice.document_reference,
          party_name: invoice.party_name,
          issue_date: invoice.issue_date,
          due_date: invoice.due_date,
          total: invoice.total,
          outstanding: outstanding,
          days_overdue: max(days, 0),
          bucket: bucket_index(buckets, days)
        }
      end)

    customers_by_id =
      Records.query(Customer, scope, company_id)
      |> where([c], c.id in ^Enum.map(rows, & &1.customer_id))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    customer_rows =
      rows
      |> Enum.group_by(& &1.customer_id, &Map.delete(&1, :customer_id))
      |> Enum.map(fn {customer_id, documents} ->
        customer = Map.fetch!(customers_by_id, customer_id)

        %{
          customer_id: customer_id,
          code: customer.code,
          name: customer.name,
          documents:
            documents |> Enum.sort_by(& &1.document_id) |> Enum.sort_by(& &1.due_date, Date),
          bucket_totals: bucket_totals(documents, buckets),
          total: total(documents)
        }
      end)
      |> Enum.sort_by(& &1.code)

    %{
      company_id: company_id,
      as_of: as_of,
      through_entry_number: through,
      currency_code: book.currency_code,
      minor_units: book.minor_units,
      buckets: buckets,
      customers: customer_rows,
      bucket_totals: bucket_totals(rows, buckets),
      total: total(rows)
    }
  end

  # Not yet due, then one bucket per limit, then everything older.
  defp buckets(days) do
    {ranges, last} =
      Enum.map_reduce(days, 1, fn limit, from ->
        {%{from_days: from, to_days: limit}, limit + 1}
      end)

    [%{from_days: nil, to_days: 0}] ++ ranges ++ [%{from_days: last, to_days: nil}]
  end

  defp bucket_index(_buckets, days) when days <= 0, do: 0

  defp bucket_index(buckets, days) do
    Enum.find_index(buckets, fn %{from_days: from, to_days: to} ->
      from && days >= from && (is_nil(to) or days <= to)
    end)
  end

  defp bucket_totals(rows, buckets) do
    for index <- 0..(length(buckets) - 1) do
      rows |> Enum.filter(&(&1.bucket == index)) |> total()
    end
  end

  defp total(rows), do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(&1.outstanding, &2))
end
