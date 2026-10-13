defmodule Bilimbi.Finance.Reconciliation.Evidence do
  @moduledoc false
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Tenancy}

  # This is an owned export contract, not permission to consume sibling schemas.
  # Freeze field lists with the generator version; never export credentials.
  @datasets %{
    "bank_account" =>
      {Bilimbi.Finance.Reconciliation.BankAccount,
       [
         :id,
         :tenant_id,
         :company_id,
         :name,
         :ledger_account_id,
         :charges_account_id,
         :interest_account_id,
         :match_window_days,
         :import_mapping,
         :active,
         :inserted_at,
         :updated_at
       ]},
    "bank_account_change" =>
      {Bilimbi.Finance.Reconciliation.BankAccountChange,
       [
         :id,
         :tenant_id,
         :company_id,
         :bank_account_id,
         :field,
         :old_value,
         :new_value,
         :reason,
         :changed_by_user_id,
         :changed_by_impersonator_id,
         :changed_at
       ]},
    "statement" =>
      {Bilimbi.Finance.Reconciliation.Statement,
       [
         :id,
         :tenant_id,
         :company_id,
         :bank_account_id,
         :statement_number,
         :file_name,
         :file_sha256,
         :line_count,
         :start_date,
         :end_date,
         :opening_balance,
         :closing_balance,
         :imported_by_user_id,
         :imported_by_impersonator_id,
         :imported_at
       ]},
    "statement_line" =>
      {Bilimbi.Finance.Reconciliation.StatementLine,
       [
         :id,
         :tenant_id,
         :company_id,
         :statement_id,
         :bank_account_id,
         :line_number,
         :line_date,
         :description,
         :reference,
         :amount,
         :running_balance,
         :fingerprint
       ]},
    "match" =>
      {Bilimbi.Finance.Reconciliation.Match,
       [
         :id,
         :tenant_id,
         :company_id,
         :bank_account_id,
         :match_number,
         :note,
         :matched_by_user_id,
         :matched_by_impersonator_id,
         :matched_at
       ]},
    "match_line" =>
      {Bilimbi.Finance.Reconciliation.MatchLine,
       [:id, :tenant_id, :company_id, :match_id, :statement_line_id]},
    "match_entry" =>
      {Bilimbi.Finance.Reconciliation.MatchEntry,
       [
         :id,
         :tenant_id,
         :company_id,
         :match_id,
         :bank_account_id,
         :entry_id,
         :entry_number,
         :entry_date,
         :description,
         :reference,
         :amount
       ]},
    "match_event" =>
      {Bilimbi.Finance.Reconciliation.MatchEvent,
       [
         :id,
         :tenant_id,
         :company_id,
         :event_number,
         :match_id,
         :action,
         :reason,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]},
    "reconciliation_record" =>
      {Bilimbi.Finance.Reconciliation.ReconciliationRecord,
       [
         :id,
         :tenant_id,
         :company_id,
         :bank_account_id,
         :reconciliation_number,
         :end_date,
         :statement_balance,
         :opened_by_user_id,
         :opened_by_impersonator_id,
         :opened_at
       ]},
    "reconciliation_event" =>
      {Bilimbi.Finance.Reconciliation.ReconciliationEvent,
       [
         :id,
         :tenant_id,
         :company_id,
         :event_number,
         :reconciliation_id,
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
       ]},
    "reconciliation_item" =>
      {Bilimbi.Finance.Reconciliation.ReconciliationItem,
       [
         :id,
         :tenant_id,
         :company_id,
         :reconciliation_id,
         :item_number,
         :kind,
         :statement_line_id,
         :entry_id,
         :match_id,
         :item_date,
         :description,
         :reference,
         :amount
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
