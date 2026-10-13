defmodule Bilimbi.Finance.Payroll.Evidence do
  @moduledoc false
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Tenancy}

  # This is an owned export contract, not permission to consume sibling schemas.
  # Freeze field lists with the generator version; never export credentials.
  @datasets %{
    "settings" =>
      {Bilimbi.Finance.Payroll.Settings,
       [
         :id,
         :tenant_id,
         :company_id,
         :net_pay_account_id,
         :claims_payable_account_id,
         :inserted_at,
         :updated_at
       ]},
    "settings_change" =>
      {Bilimbi.Finance.Payroll.SettingsChange,
       [
         :id,
         :tenant_id,
         :company_id,
         :old_net_pay_account_id,
         :new_net_pay_account_id,
         :old_claims_payable_account_id,
         :new_claims_payable_account_id,
         :reason,
         :changed_by_user_id,
         :changed_by_impersonator_id,
         :changed_at
       ]},
    "mapping" =>
      {Bilimbi.Finance.Payroll.Mapping,
       [
         :id,
         :tenant_id,
         :company_id,
         :kind,
         :code,
         :direction,
         :expense_account_id,
         :liability_account_id,
         :inserted_at,
         :updated_at
       ]},
    "mapping_change" =>
      {Bilimbi.Finance.Payroll.MappingChange,
       [
         :id,
         :tenant_id,
         :company_id,
         :mapping_id,
         :old_expense_account_id,
         :new_expense_account_id,
         :old_liability_account_id,
         :new_liability_account_id,
         :reason,
         :changed_by_user_id,
         :changed_by_impersonator_id,
         :changed_at
       ]},
    "posting_event" =>
      {Bilimbi.Finance.Payroll.PostingEvent,
       [
         :id,
         :tenant_id,
         :company_id,
         :source_kind,
         :source_id,
         :source_reference,
         :event,
         :entry_id,
         :entry_number,
         :entry_date,
         :total,
         :currency_code,
         :reason,
         :actor_user_id,
         :actor_impersonator_id,
         :occurred_at
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
