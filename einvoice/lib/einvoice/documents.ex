defmodule Bilimbi.Finance.Einvoice.Documents do
  @moduledoc false
  # Reads over a company's documents, lines, and status events, the plain
  # views the facade returns, and the one writer of status events. Every
  # query begins with `Tenancy.scope_query/2`; callers authorize first.

  import Ecto.Query

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Einvoice.Configuration
  alias Bilimbi.Finance.Einvoice.Consolidation
  alias Bilimbi.Finance.Einvoice.{Document, Line, StatusEvent, SubmitWorker}

  @max_bigint 9_223_372_036_854_775_807
  @reason_length 300

  # Events that move a document's status; any other event records an
  # answer, a posting, or a notice without changing it. `consolidated` and
  # `released` move a source in and out of a consolidated document.
  @status_events ~w(issued submitted refused valid invalid cancelled rejected consolidated released)

  # Statuses in which the authority still holds the document as valid: a
  # buyer's rejection request leaves it so until it is cancelled.
  @valid_statuses ~w(valid rejected)

  @doc "The events that move a document's status, in no particular order."
  def status_events, do: @status_events

  @doc "The statuses in which the authority still holds the document as valid."
  def valid_statuses, do: @valid_statuses

  @doc "The window after validation in which a document can be cancelled, as the authority sets it."
  def cancellation_window_hours, do: Configuration.authority().cancellation_window_hours()

  ## Queries

  @submit_worker inspect(Module.concat(SubmitWorker, ObanAdapter))
  @waiting_states ~w(available scheduled executing retryable)

  @doc "Whether a submit job for the document is waiting or running."
  def submission_queued?(company_id, document_id) do
    args = %{"company_id" => company_id, "document_id" => document_id}

    Repo.exists?(
      from(j in Oban.Job,
        where: j.worker == @submit_worker and j.state in @waiting_states and j.args == ^args
      )
    )
  end

  @doc "Which of these documents have a submit job waiting or running."
  def submissions_queued(_company_id, []), do: MapSet.new()

  def submissions_queued(company_id, document_ids) do
    from(j in Oban.Job,
      where:
        j.worker == @submit_worker and j.state in @waiting_states and
          fragment("?->>'company_id'", j.args) == ^to_string(company_id),
      select: fragment("?->>'document_id'", j.args)
    )
    |> Repo.all()
    |> Enum.flat_map(fn id ->
      case Integer.parse(to_string(id)) do
        {id, ""} -> if id in document_ids, do: [id], else: []
        _other -> []
      end
    end)
    |> MapSet.new()
  end

  def documents_query(%Scope{} = scope, company_id) do
    from(d in Tenancy.scope_query(Document, scope), where: d.company_id == ^company_id)
  end

  @doc "A document with its ordered lines and events, or `nil`."
  def fetch(%Scope{} = scope, company_id, document_id)
      when is_integer(document_id) and document_id > 0 and document_id <= @max_bigint do
    lines = order_by(Tenancy.scope_query(Line, scope), [l], asc: l.line_number)

    scope
    |> documents_query(company_id)
    |> where([d], d.id == ^document_id)
    |> preload(lines: ^lines)
    |> Repo.one()
    |> case do
      nil -> nil
      document -> {document, events(scope, company_id, document.id)}
    end
  end

  def fetch(_scope, _company_id, _document_id), do: nil

  @doc "A document's events in recording order."
  def events(%Scope{} = scope, company_id, document_id) do
    from(e in Tenancy.scope_query(StatusEvent, scope),
      where: e.company_id == ^company_id and e.document_id == ^document_id,
      order_by: [asc: e.sequence]
    )
    |> Repo.all()
  end

  @doc "The current status of each document, by ID."
  def statuses(_scope, _company_id, []), do: %{}

  def statuses(%Scope{} = scope, company_id, document_ids) do
    from(e in Tenancy.scope_query(StatusEvent, scope),
      where:
        e.company_id == ^company_id and e.document_id in ^document_ids and
          e.event in ^@status_events,
      distinct: e.document_id,
      order_by: [asc: e.document_id, desc: e.sequence],
      select: {e.document_id, e.event}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  One page of the company's documents, newest first, each with its status:
  the shape `<.pagination>` reads. Options: `page`, `page_size`, `search`
  (code number or buyer name), `status`, `document_type`, `environment`.
  """
  def page(%Scope{} = scope, company_id, options) do
    page = Keyword.fetch!(options, :page)
    page_size = Keyword.fetch!(options, :page_size)

    latest =
      from(e in Tenancy.scope_query(StatusEvent, scope),
        where: e.company_id == ^company_id and e.event in ^@status_events,
        distinct: e.document_id,
        order_by: [asc: e.document_id, desc: e.sequence],
        select: %{document_id: e.document_id, status: e.event}
      )

    query =
      scope
      |> documents_query(company_id)
      |> join(:left, [d], s in subquery(latest), on: s.document_id == d.id)
      |> filter_search(Keyword.get(options, :search))
      |> filter_equal(:status, Keyword.get(options, :status))
      |> filter_document(:document_type, Keyword.get(options, :document_type))
      |> filter_document(:environment, Keyword.get(options, :environment))

    total = Repo.aggregate(query, :count)
    total_pages = ceil(total / page_size)
    page = if total_pages == 0, do: 1, else: min(page, total_pages)

    entries =
      query
      |> order_by([d], desc: d.id)
      |> offset(^((page - 1) * page_size))
      |> limit(^page_size)
      |> select([d, s], {d, s.status})
      |> Repo.all()
      |> Enum.map(fn {document, status} -> summary_view(document, status) end)

    %{
      entries: entries,
      page: page,
      page_size: page_size,
      total_entries: total,
      total_pages: total_pages,
      has_prev?: total_pages > 0 and page > 1,
      has_next?: total_pages > 0 and page < total_pages
    }
  end

  defp filter_search(query, search) when is_binary(search) and search != "" do
    pattern = "%" <> escape_like(search) <> "%"

    self_billed = Configuration.authority().self_billed_document_types()

    # The counterparty: the buyer, or the supplier of a self-billed document.
    where(
      query,
      [d],
      ilike(d.code_number, ^pattern) or
        (d.document_type not in ^self_billed and ilike(fragment("?->>'name'", d.buyer), ^pattern)) or
        (d.document_type in ^self_billed and ilike(fragment("?->>'name'", d.supplier), ^pattern))
    )
  end

  defp filter_search(query, _search), do: query

  defp filter_equal(query, :status, status) when is_binary(status) and status != "",
    do: where(query, [d, s], s.status == ^status)

  defp filter_equal(query, _field, _value), do: query

  defp filter_document(query, field, value) when is_binary(value) and value != "",
    do: where(query, [d], field(d, ^field) == ^value)

  defp filter_document(query, _field, _value), do: query

  defp escape_like(text), do: Regex.replace(~r/[\\%_]/, text, "\\\\\\0")

  @doc """
  Valid (or rejected, which the authority still holds as valid) documents
  without a ledger entry, and cancelled documents whose entry was not
  reversed, each as a summary with the entry IDs and the reason the last
  posting or reversal failed.
  """
  def reconciliation(%Scope{} = scope, company_id) do
    postings =
      from(e in Tenancy.scope_query(StatusEvent, scope),
        where:
          e.company_id == ^company_id and
            e.event in ["posted", "posting_reversed", "posting_failed", "reversal_failed"],
        order_by: [asc: e.document_id, asc: e.sequence],
        select: {e.document_id, e.event, e.ledger_entry_id, e.reason}
      )
      |> Repo.all()
      |> Enum.group_by(fn {id, _, _, _} -> id end)

    valid_ids =
      from(e in Tenancy.scope_query(StatusEvent, scope),
        where: e.company_id == ^company_id and e.event in ^@status_events,
        distinct: e.document_id,
        order_by: [asc: e.document_id, desc: e.sequence],
        select: {e.document_id, e.event}
      )
      |> Repo.all()

    unposted_ids =
      for {id, status} <- valid_ids,
          status in @valid_statuses,
          is_nil(find_entry(postings[id], "posted")),
          do: id

    unreversed_ids =
      for {id, "cancelled"} <- valid_ids,
          not is_nil(find_entry(postings[id], "posted")),
          is_nil(find_entry(postings[id], "posting_reversed")),
          do: id

    ids = unposted_ids ++ unreversed_ids

    documents =
      if ids == [] do
        %{}
      else
        scope
        |> documents_query(company_id)
        |> where([d], d.id in ^ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
      end

    statuses = Map.new(valid_ids)

    row = fn id, failure ->
      document = Map.fetch!(documents, id)

      document
      |> summary_view(statuses[id])
      |> Map.merge(%{
        ledger_entry_id: find_entry(postings[id], "posted"),
        reversal_entry_id: find_entry(postings[id], "posting_reversed"),
        reason: last_reason(postings[id], failure)
      })
    end

    %{
      unposted: unposted_ids |> Enum.sort(:desc) |> Enum.map(&row.(&1, "posting_failed")),
      unreversed: unreversed_ids |> Enum.sort(:desc) |> Enum.map(&row.(&1, "reversal_failed"))
    }
  end

  defp find_entry(nil, _event), do: nil

  defp find_entry(rows, event),
    do: rows |> Enum.filter(fn {_, name, _, _} -> name == event end) |> List.last() |> entry_id()

  defp entry_id({_id, _event, entry_id, _reason}), do: entry_id
  defp entry_id(nil), do: nil

  defp last_reason(nil, _event), do: nil

  defp last_reason(rows, event) do
    rows
    |> Enum.filter(fn {_, name, _, _} -> name == event end)
    |> List.last()
    |> case do
      {_id, _event, _entry, reason} -> reason
      nil -> nil
    end
  end

  ## Writes

  @doc """
  Records a status event for the document as the scope's actor: a user
  (and any impersonator) or a named system principal. `attributes` carry
  the event name and whatever the answer gave.
  """
  def record_event!(%Scope{} = scope, company_id, document_id, attributes) do
    attributes =
      attributes
      |> Map.new()
      |> Map.update(:reason, nil, &(&1 && String.slice(&1, 0, @reason_length)))

    actor =
      case Scope.actor(scope) do
        %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} ->
          %{actor_type: "user", actor_user_id: user_id, actor_impersonator_id: impersonator_id}

        %Actor{type: :system, system_principal: name} when is_binary(name) ->
          %{actor_type: "system", system_principal: name}
      end

    event =
      Repo.insert!(
        struct!(
          StatusEvent,
          Map.merge(
            %{
              tenant_id: Scope.tenant_id(scope),
              company_id: company_id,
              document_id: document_id
            },
            Map.merge(actor, Map.new(attributes))
          )
        )
      )

    # A consolidated document the authority refused, found invalid, or
    # cancelled releases the documents it covered, in the same transaction.
    Consolidation.release_sources!(scope, company_id, document_id, event.event)
    event
  end

  @doc """
  Runs `fun` in a transaction holding the company's writable lock, as the
  facade's writes do, and returns what it returns. Never call the ledger
  inside it: a ledger refusal rolls back the transaction it joins and the
  commit then fails. `Bilimbi.Finance.Einvoice.Posting` alone calls the
  ledger inside a transaction of its own, rolls all of it back on a
  refusal, and records the failure in a fresh one.
  """
  def write!(%Scope{} = scope, company_id, fun) do
    {:ok, result} =
      Repo.transact(fn ->
        case Company.lock_writable_company(scope, company_id) do
          {:ok, _proof} -> {:ok, fun.()}
          {:error, reason} -> raise "company #{company_id} is not writable: #{inspect(reason)}"
        end
      end)

    result
  end

  @doc """
  Whether the company can be written to: `:ok`, or the refusal
  `lock_writable_company/2` gives (`:company_archived`, `:not_found`).
  Asked before an irreversible call to the authority, so its outcome can
  still be recorded.
  """
  def ensure_writable(%Scope{} = scope, company_id) do
    result =
      Repo.transact(fn ->
        case Company.lock_writable_company(scope, company_id) do
          {:ok, _proof} -> {:ok, :writable}
          {:error, reason} -> {:error, reason}
        end
      end)

    case result do
      {:ok, :writable} -> :ok
      {:error, :not_found} -> {:error, :company_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Records an audit action for the company as the scope's actor. The
  payload names identifiers and outcomes, never a payload, a secret, or a
  party's details.
  """
  def record_action!(%Scope{} = scope, company_id, event, payload) do
    identity =
      case Scope.actor(scope) do
        %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} ->
          %{actor_type: "user", actor_id: user_id, impersonator_id: impersonator_id}

        %Actor{type: :system, system_principal: name} when is_binary(name) ->
          %{actor_type: "system", actor_id: 0, system_principal: name}
      end

    {:ok, _action} =
      Audit.record_action(
        scope,
        Map.merge(identity, %{
          event: event,
          occurred_at: NaiveDateTime.utc_now(),
          company_id: company_id,
          payload: payload
        })
      )

    :ok
  end

  ## Views

  @summary_fields [
    :id,
    :authority,
    :environment,
    :document_type,
    :code_number,
    :issued_at,
    :currency_code,
    :exchange_rate,
    :line_extension_amount,
    :tax_exclusive_amount,
    :tax_amount,
    :tax_inclusive_amount,
    :payable_amount,
    :original_document_id,
    :issued_by_user_id,
    :issued_by_impersonator_id,
    :recorded_at
  ]

  @line_fields [
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
  ]

  @event_fields [
    :sequence,
    :event,
    :submission_id,
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
  ]

  def summary_view(document, status) do
    document
    |> Map.take(@summary_fields)
    |> Map.merge(parties(document))
    |> Map.put(:status, status)
  end

  # The counterparty is the buyer, or the supplier on a self-billed document,
  # where the company's own profile is the buyer.
  defp parties(document) do
    self_billed? =
      document.document_type in Configuration.authority().self_billed_document_types()

    counterparty = if self_billed?, do: document.supplier, else: document.buyer

    %{
      buyer_name: document.buyer["name"],
      counterparty_name: counterparty["name"],
      self_billed?: self_billed?,
      consolidated?: Map.has_key?(document.details, Consolidation.month_key())
    }
  end

  @doc """
  The full view: the document, its lines, its events, its status, and what
  the events say about it: the authority's identifiers, the validation
  instant and link, the ledger entries posted and reversed, the end of the
  cancellation window, the latest PDF, and the flags that need attention.
  """
  def document_view({document, events}) do
    status = events |> Enum.filter(&(&1.event in @status_events)) |> List.last()
    valid = latest(events, "valid")
    submitted = latest(events, "submitted")
    posted = latest(events, "posted")
    reversed = latest(events, "posting_reversed")
    pdf = latest(events, "pdf_generated")

    document_uuid = find_value(events, & &1.document_uuid)
    long_id = find_value(events, & &1.long_id)
    validated_at = valid && (instant(valid.response["dateTimeValidated"]) || valid.recorded_at)

    document
    |> Map.take(@summary_fields ++ [:supplier, :buyer, :details])
    |> Map.merge(parties(document))
    |> Map.merge(%{
      status: status && status.event,
      submission_uid: submitted && submitted.submission_uid,
      document_uuid: document_uuid,
      long_id: long_id,
      validated_at: validated_at,
      validation_url: validation_url(document.environment, document_uuid, long_id),
      cancellable_until:
        validated_at && DateTime.add(validated_at, cancellation_window_hours() * 3600, :second),
      ledger_entry_id: posted && posted.ledger_entry_id,
      reversal_entry_id: reversed && reversed.ledger_entry_id,
      pdf_artifact_id: pdf && pdf.response["artifact_id"],
      attention: attention(events, status, posted, reversed),
      lines: Enum.map(document.lines, &Map.take(&1, @line_fields)),
      events: Enum.map(events, &Map.take(&1, @event_fields))
    })
  end

  defp latest(events, name), do: events |> Enum.filter(&(&1.event == name)) |> List.last()

  defp find_value(events, fun), do: events |> Enum.reverse() |> Enum.find_value(fun)

  defp validation_url(environment, uuid, long_id) when is_binary(uuid) and is_binary(long_id),
    do: Configuration.authority().validation_url(environment, uuid, long_id)

  defp validation_url(_environment, _uuid, _long_id), do: nil

  # What an operator should look at: a submission still unsent past the
  # authority's outage allowance, a buyer's rejection request, a validated document
  # without its ledger entry, a posting that failed, or a cancelled
  # document whose entry was not reversed.
  defp attention(events, status, posted, reversed) do
    since_status = events |> Enum.reverse() |> Enum.take_while(&(&1.event not in @status_events))
    name = status && status.event
    posting_failed? = not is_nil(latest(events, "posting_failed"))
    reversal_failed? = not is_nil(latest(events, "reversal_failed"))

    flags = [
      {Enum.any?(since_status, &(&1.event == "overdue")), :overdue},
      {name == "rejected", :rejection_requested},
      {name in @valid_statuses and is_nil(posted) and posting_failed?, :posting_failed},
      {name in @valid_statuses and is_nil(posted) and not posting_failed?, :unposted},
      {name == "cancelled" and not is_nil(posted) and is_nil(reversed) and reversal_failed?,
       :reversal_failed},
      {name == "cancelled" and not is_nil(posted) and is_nil(reversed) and not reversal_failed?,
       :unreversed}
    ]

    for {true, flag} <- flags, do: flag
  end

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, instant, _offset} -> instant
      _error -> nil
    end
  end

  defp instant(_value), do: nil
end
