defmodule Bilimbi.Finance.Sst.Evidence do
  @moduledoc false
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Tenancy}

  # This is an owned export contract, not permission to consume sibling schemas.
  # Freeze field lists with the generator version; never export credentials.
  @datasets %{
    "registration" =>
      {Bilimbi.Finance.Sst.Registration,
       [
         :id,
         :tenant_id,
         :company_id,
         :version,
         :sales_tax_number,
         :service_tax_number,
         :period_months,
         :period_start,
         :service_tax_basis,
         :reason,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]},
    "mapping" =>
      {Bilimbi.Finance.Sst.Mapping,
       [
         :id,
         :tenant_id,
         :company_id,
         :mapping_number,
         :source,
         :tax_code_id,
         :tax_code,
         :box,
         :reason,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]},
    "return" =>
      {Bilimbi.Finance.Sst.TaxReturn,
       [
         :id,
         :tenant_id,
         :company_id,
         :return_number,
         :tax_type,
         :registration_id,
         :period_start,
         :period_end,
         :due_date,
         :amends_return_id,
         :reason,
         :opened_by_user_id,
         :opened_by_impersonator_id,
         :opened_at
       ]},
    "return_event" =>
      {Bilimbi.Finance.Sst.ReturnEvent,
       [
         :id,
         :tenant_id,
         :company_id,
         :event_number,
         :return_id,
         :action,
         :reason,
         :version,
         :through_entry_number,
         :through_mapping_number,
         :through_adjustment_number,
         :currency_code,
         :minor_units,
         :tax_payable,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]},
    "return_box" =>
      {Bilimbi.Finance.Sst.ReturnBox,
       [
         :id,
         :tenant_id,
         :company_id,
         :return_id,
         :line_number,
         :box,
         :taxable_amount,
         :tax_amount
       ]},
    "return_account" =>
      {Bilimbi.Finance.Sst.ReturnAccount,
       [
         :id,
         :tenant_id,
         :company_id,
         :return_id,
         :line_number,
         :account_id,
         :account_code,
         :account_name,
         :ledger_debits,
         :ledger_credits,
         :document_debits,
         :document_credits,
         :difference
       ]},
    "return_source" =>
      {Bilimbi.Finance.Sst.ReturnSource,
       [
         :id,
         :tenant_id,
         :company_id,
         :return_id,
         :line_number,
         :source,
         :document_kind,
         :measure,
         :prior_period,
         :tax_code_id,
         :tax_code,
         :rate,
         :account_id,
         :box,
         :mapping_number,
         :document_count,
         :taxable_amount,
         :tax_amount
       ]},
    "adjustment" =>
      {Bilimbi.Finance.Sst.Adjustment,
       [
         :id,
         :tenant_id,
         :company_id,
         :adjustment_number,
         :return_id,
         :action,
         :withdraws_adjustment_id,
         :copied_from_adjustment_id,
         :box,
         :taxable_amount,
         :tax_amount,
         :description,
         :reference,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]}
  }

  def datasets, do: Map.keys(@datasets) |> Enum.sort()

  def tables do
    for {_dataset, {schema, _fields}} <- @datasets, do: schema.__schema__(:source)
  end

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
