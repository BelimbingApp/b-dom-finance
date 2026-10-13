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
         :legal_hold,
         :status,
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

  # The attachment row keeps the retain-until it was captured with; the index
  # answers with the one in force (the latest extension, as
  # `Bilimbi.Finance.Attachments.get_attachment/3` does), whether a legal hold
  # is on it (its latest hold event), and whether it still stands.
  defp current(query, "attachment") do
    select_merge(query, [r], %{
      retain_until:
        type(
          fragment(
            "GREATEST(?, (SELECT MAX(e.retain_until) FROM finance_attachment_events e WHERE e.attachment_id = ? AND e.event = 'retention_extended'))",
            r.retain_until,
            r.id
          ),
          :utc_datetime_usec
        ),
      legal_hold:
        fragment(
          "COALESCE((SELECT e.event = 'hold_placed' FROM finance_attachment_events e WHERE e.attachment_id = ? AND e.event IN ('hold_placed', 'hold_released') ORDER BY e.id DESC LIMIT 1), false)",
          r.id
        ),
      status:
        fragment(
          "COALESCE((SELECT e.event FROM finance_attachment_events e WHERE e.attachment_id = ? AND e.event IN ('replaced', 'removed')), 'standing')",
          r.id
        )
    })
  end

  defp current(query, _dataset), do: query

  # Fields the index derives in the query rather than reading from a column.
  defp computed("attachment"), do: [:legal_hold, :status]
  defp computed(_dataset), do: []

  def datasets, do: Map.keys(@datasets) |> Enum.sort()

  def tables do
    for {_dataset, {schema, _fields}} <- @datasets, do: schema.__schema__(:source)
  end

  def page(scope, company_id, dataset, options, readable_modules) do
    limit = Keyword.get(options, :limit, 500)
    cursor = Keyword.get(options, :after, 0)

    with {:ok, {schema, fields}} <- Map.fetch(@datasets, dataset),
         true <- is_integer(limit) and limit in 1..500 and is_integer(cursor) and cursor >= 0 do
      columns = fields -- computed(dataset)

      rows =
        from(r in Tenancy.scope_query(schema, scope),
          where: r.company_id == ^company_id and r.id > ^cursor,
          order_by: [asc: r.id],
          limit: ^limit,
          select: map(r, ^columns)
        )
        |> readable(dataset, scope, company_id, readable_modules)
        |> current(dataset)
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
