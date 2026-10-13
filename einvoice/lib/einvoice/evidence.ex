defmodule Bilimbi.Finance.Einvoice.Evidence do
  @moduledoc false
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Tenancy}

  # This is an owned export contract, not permission to consume sibling schemas.
  # Freeze field lists with the generator version; never export credentials.
  @datasets %{
    "source_link" =>
      {Bilimbi.Finance.Einvoice.SourceLink,
       [
         :id,
         :tenant_id,
         :company_id,
         :document_id,
         :source_module,
         :source_record,
         :ledger_entry_id
       ]},
    "document" =>
      {Bilimbi.Finance.Einvoice.Document,
       [
         :id,
         :tenant_id,
         :company_id,
         :authority,
         :environment,
         :document_type,
         :code_number,
         :issued_at,
         :currency_code,
         :exchange_rate,
         :supplier,
         :buyer,
         :details,
         :original_document_id,
         :line_extension_amount,
         :tax_exclusive_amount,
         :tax_amount,
         :tax_inclusive_amount,
         :payable_amount,
         :issued_by_user_id,
         :issued_by_impersonator_id,
         :recorded_at
       ]},
    "line" =>
      {Bilimbi.Finance.Einvoice.Line,
       [
         :id,
         :tenant_id,
         :company_id,
         :document_id,
         :line_number,
         :description,
         :classification_code,
         :tariff_code,
         :origin_country_code,
         :quantity,
         :unit_code,
         :unit_price,
         :subtotal,
         :discount_amount,
         :charge_amount,
         :line_extension_amount,
         :tax_type,
         :tax_rate,
         :tax_amount,
         :tax_exemption_reason
       ]},
    "status_event" =>
      {Bilimbi.Finance.Einvoice.StatusEvent,
       [
         :id,
         :tenant_id,
         :company_id,
         :document_id,
         :sequence,
         :submission_id,
         :event,
         :authority_status,
         :submission_uid,
         :document_uuid,
         :long_id,
         :reason,
         :http_status,
         :response,
         :ledger_entry_id,
         :actor_type,
         :actor_user_id,
         :actor_impersonator_id,
         :system_principal,
         :recorded_at
       ]},
    "submission" =>
      {Bilimbi.Finance.Einvoice.Submission,
       [
         :id,
         :tenant_id,
         :company_id,
         :document_id,
         :environment,
         :format,
         :document_version,
         :payload,
         :payload_sha256,
         :actor_type,
         :actor_user_id,
         :actor_impersonator_id,
         :system_principal,
         :recorded_at
       ]},
    "consolidated_source" =>
      {Bilimbi.Finance.Einvoice.ConsolidatedSource,
       [:id, :tenant_id, :company_id, :document_id, :source_document_id, :line_number]},
    "code_override" =>
      {Bilimbi.Finance.Einvoice.CodeOverride,
       [
         :id,
         :tenant_id,
         :company_id,
         :authority,
         :list,
         :code,
         :description,
         :active,
         :inserted_at,
         :updated_at
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
