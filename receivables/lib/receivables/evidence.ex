defmodule Bilimbi.Finance.Receivables.Evidence do
  @moduledoc false
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Tenancy}

  # This is an owned export contract, not permission to consume sibling schemas.
  # Freeze field lists with the generator version; never export credentials.
  @datasets %{
    "customer" =>
      {Bilimbi.Finance.Receivables.Customer,
       [
         :id,
         :tenant_id,
         :company_id,
         :code,
         :name,
         :tax_identifier,
         :registration_identifier,
         :email,
         :phone,
         :line1,
         :line2,
         :line3,
         :locality,
         :postcode,
         :admin1_code,
         :country_iso,
         :payment_terms_days,
         :active,
         :inserted_at,
         :updated_at
       ]},
    "series" =>
      {Bilimbi.Finance.Receivables.Series,
       [
         :id,
         :tenant_id,
         :company_id,
         :code,
         :name,
         :kind,
         :prefix,
         :number_width,
         :active,
         :inserted_at,
         :updated_at
       ]},
    "tax_code" =>
      {Bilimbi.Finance.Receivables.TaxCode,
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
    "setup" =>
      {Bilimbi.Finance.Receivables.Setup,
       [
         :id,
         :tenant_id,
         :company_id,
         :receivable_account_id,
         :income_account_id,
         :inserted_at,
         :updated_at
       ]},
    "setup_change" =>
      {Bilimbi.Finance.Receivables.SetupChange,
       [
         :id,
         :tenant_id,
         :company_id,
         :field,
         :old_value,
         :new_value,
         :changed_by_user_id,
         :changed_by_impersonator_id,
         :changed_at
       ]},
    "document" =>
      {Bilimbi.Finance.Receivables.Document,
       [
         :id,
         :tenant_id,
         :company_id,
         :kind,
         :status,
         :series_id,
         :customer_id,
         :credited_document_id,
         :receivable_account_id,
         :currency_code,
         :issue_date,
         :due_date,
         :description,
         :subtotal,
         :tax_total,
         :total,
         :document_number,
         :document_reference,
         :party_name,
         :party_tax_identifier,
         :party_registration_identifier,
         :party_email,
         :party_phone,
         :party_line1,
         :party_line2,
         :party_line3,
         :party_locality,
         :party_postcode,
         :party_admin1_code,
         :party_country_iso,
         :ledger_entry_id,
         :ledger_entry_number,
         :issued_by_user_id,
         :issued_by_impersonator_id,
         :issued_at,
         :discarded_by_user_id,
         :discarded_at,
         :inserted_at,
         :updated_at
       ]},
    "document_line" =>
      {Bilimbi.Finance.Receivables.DocumentLine,
       [
         :id,
         :tenant_id,
         :company_id,
         :document_id,
         :line_number,
         :description,
         :quantity,
         :unit_price,
         :amount,
         :account_id,
         :tax_code_id,
         :tax_rate,
         :tax_amount,
         :quantity
       ]},
    "tax_line" =>
      {Bilimbi.Finance.Receivables.TaxLine,
       [
         :id,
         :tenant_id,
         :company_id,
         :document_id,
         :tax_code_id,
         :tax_code,
         :tax_rate,
         :taxable_amount,
         :tax_amount,
         :account_id
       ]},
    "payment" =>
      {Bilimbi.Finance.Receivables.Payment,
       [
         :id,
         :tenant_id,
         :company_id,
         :series_id,
         :customer_id,
         :payment_number,
         :payment_reference,
         :payment_date,
         :amount,
         :currency_code,
         :deposit_account_id,
         :reference,
         :description,
         :ledger_entry_id,
         :ledger_entry_number,
         :recorded_by_user_id,
         :recorded_by_impersonator_id,
         :recorded_at
       ]},
    "payment_reversal" =>
      {Bilimbi.Finance.Receivables.PaymentReversal,
       [
         :id,
         :tenant_id,
         :company_id,
         :payment_id,
         :reversal_date,
         :reason,
         :ledger_entry_id,
         :ledger_entry_number,
         :reversed_by_user_id,
         :reversed_by_impersonator_id,
         :reversed_at
       ]},
    "allocation" =>
      {Bilimbi.Finance.Receivables.Allocation,
       [:id, :tenant_id, :company_id, :payment_id, :document_id, :amount]}
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
