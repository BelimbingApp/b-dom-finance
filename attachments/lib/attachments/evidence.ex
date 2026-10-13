defmodule Bilimbi.Finance.Attachments.Evidence do
  @moduledoc false
  import Ecto.Query
  alias Bilimbi.Base.{Repo, Tenancy}

  # This is an owned export contract, not permission to consume sibling schemas.
  # Freeze field lists with the generator version; the bytes themselves stay in
  # Base Artifacts, and this index names each file, its hash and retain-until.
  @datasets %{
    "attachment" =>
      {Bilimbi.Finance.Attachments.Attachment,
       [
         :id,
         :tenant_id,
         :company_id,
         :attachment_number,
         :source,
         :source_module,
         :document_id,
         :document_label,
         :document_date,
         :artifact_id,
         :file_name,
         :content_type,
         :byte_size,
         :sha256,
         :retention_years,
         :retain_until,
         :captured_by_user_id,
         :captured_by_impersonator_id,
         :captured_at
       ]},
    "attachment_event" =>
      {Bilimbi.Finance.Attachments.AttachmentEvent,
       [
         :id,
         :tenant_id,
         :company_id,
         :attachment_id,
         :event,
         :replacement_id,
         :retain_until,
         :reason,
         :actor_user_id,
         :actor_impersonator_id,
         :actor_system_principal,
         :occurred_at
       ]},
    "retention_change" =>
      {Bilimbi.Finance.Attachments.RetentionChange,
       [
         :id,
         :tenant_id,
         :company_id,
         :change_number,
         :years,
         :reason,
         :changed_by_user_id,
         :changed_by_impersonator_id,
         :changed_at
       ]}
  }

  # The attachments of a source the caller cannot read, and their events,
  # are left out; the company's retention changes belong to no source.
  defp readable(query, "attachment", _scope, _company_id, modules),
    do: where(query, [r], r.source_module in ^modules)

  defp readable(query, "attachment_event", scope, company_id, modules) do
    readable =
      from(a in Tenancy.scope_query(Bilimbi.Finance.Attachments.Attachment, scope),
        where: a.company_id == ^company_id and a.source_module in ^modules,
        select: a.id
      )

    where(query, [r], r.attachment_id in subquery(readable))
  end

  defp readable(query, _dataset, _scope, _company_id, _modules), do: query

  def datasets, do: Map.keys(@datasets) |> Enum.sort()

  def tables do
    for {_dataset, {schema, _fields}} <- @datasets, do: schema.__schema__(:source)
  end

  def page(scope, company_id, dataset, options, readable_modules) do
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
        |> readable(dataset, scope, company_id, readable_modules)
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
