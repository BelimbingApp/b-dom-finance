defmodule Bilimbi.Finance.Payables.TaxReport do
  @moduledoc false
  # The tax posted documents carry, for a module that reports it to a tax
  # authority: sums per document type and tax code, and the tax lines behind
  # them. Only posted documents count, each by its document date and the
  # ledger entry it posted, so a reading pinned to an entry number
  # reproduces.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Payables.{Document, TaxLine}

  @max_bigint 9_223_372_036_854_775_807

  def totals(scope, company_id, options) do
    with {:ok, from, to, through} <- window(options) do
      rows =
        scope
        |> posted_lines(company_id, from, to, through)
        |> group_by([l, d], [d.document_type, l.tax_code_id, l.tax_code, l.rate, l.account_id])
        |> order_by([l, d],
          asc: l.tax_code,
          asc: d.document_type,
          asc: l.rate,
          asc: l.account_id
        )
        |> select([l, d], %{
          document_type: d.document_type,
          tax_code_id: l.tax_code_id,
          tax_code: l.tax_code,
          rate: l.rate,
          account_id: l.account_id,
          document_count: count(d.id, :distinct),
          taxable_amount: sum(l.taxable_amount),
          tax_amount: sum(l.tax_amount)
        })
        |> Repo.all()

      {:ok, rows}
    end
  end

  def lines(scope, company_id, options) do
    with {:ok, from, to, through} <- window(options),
         {:ok, limit, cursor} <- page_options(options),
         {:ok, tax_code_id} <- id_option(options, :tax_code_id) do
      rows =
        scope
        |> posted_lines(company_id, from, to, through)
        |> tax_code_bound(tax_code_id)
        |> cursor_bound(cursor)
        |> order_by([l], asc: l.id)
        |> limit(^limit)
        |> select([l, d], %{
          id: l.id,
          document_id: d.id,
          document_type: d.document_type,
          document_number: d.document_number,
          party_document_number: d.party_document_number,
          document_date: d.document_date,
          party_name: d.party_name,
          corrects_document_id: d.corrects_document_id,
          entry_number: d.entry_number,
          tax_code_id: l.tax_code_id,
          tax_code: l.tax_code,
          rate: l.rate,
          account_id: l.account_id,
          taxable_amount: l.taxable_amount,
          tax_amount: l.tax_amount
        })
        |> Repo.all()

      {:ok, rows}
    end
  end

  defp posted_lines(scope, company_id, from, to, through) do
    documents =
      from(d in Tenancy.scope_query(Document, scope),
        where: d.company_id == ^company_id and d.status == "posted"
      )
      |> from_bound(from)
      |> to_bound(to)
      |> through_bound(through)

    from(l in Tenancy.scope_query(TaxLine, scope),
      join: d in subquery(documents),
      on: d.id == l.document_id,
      where: l.company_id == ^company_id
    )
  end

  defp from_bound(query, nil), do: query
  defp from_bound(query, from), do: where(query, [d], d.document_date >= ^from)

  defp to_bound(query, nil), do: query
  defp to_bound(query, to), do: where(query, [d], d.document_date <= ^to)

  defp through_bound(query, nil), do: query
  defp through_bound(query, through), do: where(query, [d], d.entry_number <= ^through)

  defp tax_code_bound(query, nil), do: query
  defp tax_code_bound(query, id), do: where(query, [l], l.tax_code_id == ^id)

  defp cursor_bound(query, nil), do: query
  defp cursor_bound(query, cursor), do: where(query, [l], l.id > ^cursor)

  defp window(options) do
    from = Keyword.get(options, :from)
    to = Keyword.get(options, :to)
    through = Keyword.get(options, :through_entry_number)

    cond do
      not (optional_date?(from) and optional_date?(to)) -> {:error, :invalid_option}
      from && to && Date.compare(from, to) == :gt -> {:error, :invalid_option}
      not (is_nil(through) or (is_integer(through) and through in 0..@max_bigint)) ->
        {:error, :invalid_option}
      true -> {:ok, from, to, through}
    end
  end

  defp page_options(options) do
    limit = Keyword.get(options, :limit, 100)

    with true <- is_integer(limit) and limit in 1..500,
         {:ok, cursor} <- id_option(options, :after) do
      {:ok, limit, cursor}
    else
      _invalid -> {:error, :invalid_option}
    end
  end

  defp id_option(options, key) do
    case Keyword.get(options, key) do
      nil -> {:ok, nil}
      id when is_integer(id) and id in 1..@max_bigint -> {:ok, id}
      _other -> {:error, :invalid_option}
    end
  end

  defp optional_date?(value), do: is_nil(value) or match?(%Date{}, value)
end
