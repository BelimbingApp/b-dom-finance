defmodule Bilimbi.Finance.FixedAssets.Evidence do
  @moduledoc false
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Tenancy}

  # This is an owned export contract, not permission to consume sibling schemas.
  # Freeze field lists with the generator version; never export credentials.
  @datasets %{
    "category" =>
      {Bilimbi.Finance.FixedAssets.Category,
       [
         :id,
         :tenant_id,
         :company_id,
         :name,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]},
    "category_revision" =>
      {Bilimbi.Finance.FixedAssets.CategoryRevision,
       [
         :id,
         :tenant_id,
         :company_id,
         :category_id,
         :cost_account_id,
         :accumulated_account_id,
         :expense_account_id,
         :gain_account_id,
         :loss_account_id,
         :method,
         :life_months,
         :annual_rate,
         :reason,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]},
    "asset" =>
      {Bilimbi.Finance.FixedAssets.Asset,
       [
         :id,
         :tenant_id,
         :company_id,
         :asset_number,
         :category_revision_id,
         :description,
         :acquisition_date,
         :in_service_date,
         :cost,
         :residual_value,
         :method,
         :life_months,
         :annual_rate,
         :entry_id,
         :entry_number,
         :entry_line_number,
         :bill_id,
         :bill_line_number,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]},
    "run" =>
      {Bilimbi.Finance.FixedAssets.Run,
       [
         :id,
         :tenant_id,
         :company_id,
         :period,
         :entry_id,
         :entry_number,
         :total,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]},
    "run_item" =>
      {Bilimbi.Finance.FixedAssets.RunItem,
       [
         :id,
         :tenant_id,
         :company_id,
         :run_id,
         :asset_id,
         :amount,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]},
    "run_exception" =>
      {Bilimbi.Finance.FixedAssets.RunException,
       [
         :id,
         :tenant_id,
         :company_id,
         :run_id,
         :asset_id,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]},
    "event" =>
      {Bilimbi.Finance.FixedAssets.Event,
       [
         :id,
         :tenant_id,
         :company_id,
         :event_number,
         :asset_id,
         :run_id,
         :action,
         :effective_date,
         :entry_id,
         :entry_number,
         :reverses_event_id,
         :proceeds,
         :accumulated,
         :reason,
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
