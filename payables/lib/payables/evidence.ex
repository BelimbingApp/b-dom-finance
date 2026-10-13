defmodule Bilimbi.Finance.Payables.Evidence do
  @moduledoc false
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Tenancy}

  # This is an owned export contract, not permission to consume sibling schemas.
  # Freeze field lists with the generator version; never export credentials.
  @datasets %{
    "settings" =>
      {Bilimbi.Finance.Payables.Settings,
       [
         :id,
         :tenant_id,
         :company_id,
         :payable_account_id,
         :quantity_tolerance_kind,
         :quantity_tolerance,
         :price_tolerance_kind,
         :price_tolerance,
         :inserted_at,
         :updated_at
       ]},
    "settings_change" =>
      {Bilimbi.Finance.Payables.SettingsChange,
       [
         :id,
         :tenant_id,
         :company_id,
         :old_payable_account_id,
         :new_payable_account_id,
         :old_quantity_tolerance_kind,
         :new_quantity_tolerance_kind,
         :old_quantity_tolerance,
         :new_quantity_tolerance,
         :old_price_tolerance_kind,
         :new_price_tolerance_kind,
         :old_price_tolerance,
         :new_price_tolerance,
         :reason,
         :changed_by_user_id,
         :changed_by_impersonator_id,
         :changed_at
       ]},
    "tax_code" =>
      {Bilimbi.Finance.Payables.TaxCode,
       [
         :id,
         :tenant_id,
         :company_id,
         :code,
         :name,
         :rate,
         :account_id,
         :active,
         :inserted_at,
         :updated_at
       ]},
    "tax_code_change" =>
      {Bilimbi.Finance.Payables.TaxCodeChange,
       [
         :id,
         :tenant_id,
         :company_id,
         :tax_code_id,
         :old_name,
         :new_name,
         :old_rate,
         :new_rate,
         :old_account_id,
         :new_account_id,
         :old_active,
         :new_active,
         :reason,
         :changed_by_user_id,
         :changed_by_impersonator_id,
         :changed_at
       ]},
    "document" =>
      {Bilimbi.Finance.Payables.Document,
       [
         :id,
         :tenant_id,
         :company_id,
         :document_type,
         :status,
         :document_number,
         :corrects_document_id,
         :party_key,
         :party_name,
         :party_tax_id,
         :party_registration_id,
         :party_address,
         :party_document_number,
         :document_date,
         :due_date,
         :currency_code,
         :description,
         :total_net,
         :total_tax,
         :total,
         :created_by_user_id,
         :created_by_impersonator_id,
         :created_at,
         :approved_by_user_id,
         :approved_by_impersonator_id,
         :approved_at,
         :posted_by_user_id,
         :posted_by_impersonator_id,
         :posted_at,
         :payable_account_id,
         :entry_id,
         :entry_number,
         :voided_by_user_id,
         :voided_by_impersonator_id,
         :voided_at,
         :void_reason
       ]},
    "document_line" =>
      {Bilimbi.Finance.Payables.DocumentLine,
       [
         :id,
         :tenant_id,
         :company_id,
         :document_id,
         :line_number,
         :description,
         :account_id,
         :amount,
         :tax_code_id,
         :external_order_line_id,
         :order_line_id,
         :quantity
       ]},
    "tax_line" =>
      {Bilimbi.Finance.Payables.TaxLine,
       [
         :id,
         :tenant_id,
         :company_id,
         :document_id,
         :line_number,
         :tax_code_id,
         :tax_code,
         :rate,
         :account_id,
         :taxable_amount,
         :tax_amount
       ]},
    "payment" =>
      {Bilimbi.Finance.Payables.Payment,
       [
         :id,
         :tenant_id,
         :company_id,
         :payment_number,
         :payment_date,
         :party_key,
         :party_name,
         :paid_from_account_id,
         :amount,
         :currency_code,
         :reference,
         :description,
         :reverses_payment_id,
         :entry_id,
         :entry_number,
         :posted_by_user_id,
         :posted_by_impersonator_id,
         :posted_at
       ]},
    "allocation" =>
      {Bilimbi.Finance.Payables.Allocation,
       [:id, :tenant_id, :company_id, :payment_id, :line_number, :document_id, :amount]},
    "match_event" =>
      {Bilimbi.Finance.Payables.MatchEvent,
       [
         :id,
         :tenant_id,
         :company_id,
         :document_id,
         :event,
         :reason,
         :held_event_id,
         :actor_user_id,
         :actor_impersonator_id,
         :occurred_at
       ]},
    "match_exception" =>
      {Bilimbi.Finance.Payables.MatchException,
       [:id, :tenant_id, :company_id, :match_line_id, :code, :detail]},
    "match_line" =>
      {Bilimbi.Finance.Payables.MatchLine,
       [
         :id,
         :tenant_id,
         :company_id,
         :event_id,
         :document_id,
         :line_number,
         :order_line_id,
         :order_number,
         :billed_quantity,
         :billed_unit_price,
         :previously_billed_quantity,
         :ordered_quantity,
         :ordered_unit_price,
         :received_quantity,
         :quantity_tolerance_kind,
         :quantity_tolerance,
         :price_tolerance_kind,
         :price_tolerance
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
