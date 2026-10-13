defmodule Bilimbi.Finance.Ledger.Evidence do
  @moduledoc false
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Tenancy}

  # This is an owned export contract, not permission to consume sibling schemas.
  # Freeze field lists with the generator version; never export credentials.
  @datasets %{
    "book" =>
      {Bilimbi.Finance.Ledger.Book,
       [:id, :tenant_id, :company_id, :currency_code, :minor_units, :inserted_at]},
    "account" =>
      {Bilimbi.Finance.Ledger.Account,
       [
         :id,
         :tenant_id,
         :company_id,
         :code,
         :name,
         :account_type,
         :parent_id,
         :active,
         :retained_earnings,
         :inserted_at,
         :updated_at
       ]},
    "entry" =>
      {Bilimbi.Finance.Ledger.Entry,
       [
         :id,
         :tenant_id,
         :company_id,
         :entry_number,
         :entry_date,
         :description,
         :reference,
         :currency_code,
         :reverses_entry_id,
         :posted_by_user_id,
         :posted_by_impersonator_id,
         :posted_at
       ]},
    "line" =>
      {Bilimbi.Finance.Ledger.Line,
       [
         :id,
         :tenant_id,
         :company_id,
         :entry_id,
         :line_number,
         :account_id,
         :debit,
         :credit,
         :description
       ]},
    "fiscal_year" =>
      {Bilimbi.Finance.Ledger.FiscalYear,
       [
         :id,
         :tenant_id,
         :company_id,
         :start_date,
         :end_date,
         :opened_by_user_id,
         :opened_by_impersonator_id,
         :opened_at
       ]},
    "period" =>
      {Bilimbi.Finance.Ledger.Period,
       [:id, :tenant_id, :company_id, :fiscal_year_id, :period_number, :start_date, :end_date]},
    "closing_event" =>
      {Bilimbi.Finance.Ledger.ClosingEvent,
       [
         :id,
         :tenant_id,
         :company_id,
         :event_number,
         :fiscal_year_id,
         :period_id,
         :action,
         :reason,
         :entry_id,
         :retained_earnings_account_id,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]}
  }

  def datasets, do: Map.keys(@datasets) |> Enum.sort()

  def page(scope, company_id, dataset, options) do
    limit = Keyword.get(options, :limit, 500)
    cursor = Keyword.get(options, :after, 0)

    with {:ok, {schema, fields}} <- Map.fetch(@datasets, dataset),
         true <- is_integer(limit) and limit in 1..500 and is_integer(cursor) and cursor >= 0 do
      rows =
        from(r in Tenancy.scope_query(schema, scope),
          where: r.company_id == ^company_id and r.id > ^cursor,
          order_by: [asc: r.id],
          limit: ^limit,
          select: map(r, ^fields)
        )
        |> Repo.all()

      {:ok,
       %{
         fields: fields,
         rows: rows,
         next: if(length(rows) == limit, do: List.last(rows).id, else: nil)
       }}
    else
      _ -> {:error, :invalid_option}
    end
  end
end
