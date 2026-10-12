defmodule Bilimbi.Finance.Einvoice.Consolidation do
  @moduledoc """
  A consolidated document: one document to the authority for a month's
  sales that no buyer asked an individual document for.

  The sources are the company's recorded documents issued in the month (in
  the authority's calendar, `Authority.consolidation_window/1`) in the
  current environment that were never submitted on their own, are not held
  by another consolidated document, are not waiting in a submit job, and
  pass the authority's own limits (`Authority.consolidation_refusal/1`).
  They are grouped into a line per source and tax, each line's amount and
  tax being the exact sums of that source's lines of the tax, so the
  consolidated totals equal the sources' totals. The authority shapes the document itself
  (`Authority.consolidated_document/1`).

  Recording one writes a row per source and line it covers and a
  `consolidated` status event on each source, which then cannot be
  submitted on its own (the database refuses that as well). When the
  authority refuses the consolidated document, finds it invalid, or it is
  cancelled, its sources are released (`released`) and may be
  consolidated again; the document itself, whose bytes and issue date
  never change, is never submitted again.

  The facade (`Bilimbi.Finance.Einvoice.issue_consolidated_document/3`)
  authorizes, takes the company lock, and records; this module selects and
  groups, and is called only inside that transaction.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Einvoice.{ConsolidatedSource, Configuration, Documents, Line, Submission}

  # A source's status before it is consolidated: recorded, or released by a
  # consolidated document that was cancelled or found invalid.
  @open_statuses ["issued", "released"]
  # The events after which a consolidated document no longer holds its
  # sources (see the consolidation migration).
  @releasing ["refused", "invalid", "cancelled"]

  @doc "The details key that marks a consolidated document and names its month."
  def month_key, do: "consolidation_month"

  @doc "The events after which a consolidated document releases its sources."
  def releasing_events, do: @releasing

  @doc "Whether a document view is a consolidated document."
  def consolidated?(%{details: details}) when is_map(details),
    do: Map.has_key?(details, month_key())

  def consolidated?(_document), do: false

  @doc """
  The month a caller names, as its first day: a `Date` in it, or
  `"YYYY-MM"`. `:error` otherwise.
  """
  def parse_month(%Date{} = date), do: {:ok, Date.beginning_of_month(date)}

  def parse_month(<<year::binary-size(4), "-", month::binary-size(2)>>) do
    case Date.from_iso8601("#{year}-#{month}-01") do
      {:ok, date} -> {:ok, date}
      {:error, _} -> :error
    end
  end

  def parse_month(_other), do: :error

  @doc """
  Whether a consolidated document for the window may be issued at `now`:
  `:ok`, `{:error, :period_not_ended}`, or
  `{:error, :consolidation_window_closed}`.
  """
  def open(%{until: until, closes_at: closes_at}, %DateTime{} = now) do
    cond do
      DateTime.compare(now, until) == :lt -> {:error, :period_not_ended}
      DateTime.compare(now, closes_at) != :lt -> {:error, :consolidation_window_closed}
      true -> :ok
    end
  end

  @doc """
  The window's documents a consolidated document may cover, oldest first,
  each with its lines: `{eligible, refused}`, where `refused` pairs a
  document the authority's limits keep out with the reason.
  """
  def candidates(%Scope{} = scope, company_id, environment, %{from: from, until: until}) do
    lines = order_by(Tenancy.scope_query(Line, scope), [l], asc: l.line_number)

    documents =
      scope
      |> Documents.documents_query(company_id)
      |> where(
        [d],
        d.environment == ^environment and d.issued_at >= ^from and d.issued_at < ^until
      )
      |> order_by([d], asc: d.issued_at, asc: d.id)
      |> preload(lines: ^lines)
      |> Repo.all()

    ids = Enum.map(documents, & &1.id)
    statuses = Documents.statuses(scope, company_id, ids)
    submitted = submitted_ids(scope, company_id, ids)
    queued = Documents.submissions_queued(company_id, ids)

    documents
    |> Enum.filter(fn document ->
      statuses[document.id] in @open_statuses and document.id not in submitted and
        document.id not in queued and not Map.has_key?(document.details, month_key())
    end)
    |> Enum.map(&{&1, Configuration.authority().consolidation_refusal(&1)})
    |> Enum.split_with(fn {_document, refusal} -> is_nil(refusal) end)
    |> then(fn {eligible, refused} -> {Enum.map(eligible, &elem(&1, 0)), refused} end)
  end

  defp submitted_ids(_scope, _company_id, []), do: MapSet.new()

  defp submitted_ids(scope, company_id, ids) do
    from(s in Tenancy.scope_query(Submission, scope),
      where: s.company_id == ^company_id and s.document_id in ^ids,
      distinct: true,
      select: s.document_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  The consolidated document's lines from its sources, in order: each with
  `description`, `amount`, `tax_amount`, `tax_type`, `tax_rate`,
  `tax_exemption_reason`, and `source_ids`.
  """
  def group(sources) do
    Enum.flat_map(sources, fn source ->
      source.lines
      |> by_tax()
      |> Enum.map(fn {key, lines} ->
        line(key, Enum.map(lines, &{source, &1}), source.code_number)
      end)
    end)
  end

  defp by_tax(lines) do
    lines
    |> Enum.group_by(&tax_key/1)
    |> Enum.sort_by(fn {{type, rate, reason}, _} -> {type, Decimal.to_float(rate), reason} end)
  end

  defp tax_key(line),
    do: {line.tax_type, Decimal.normalize(line.tax_rate), line.tax_exemption_reason}

  defp line({tax_type, tax_rate, reason}, pairs, description) do
    %{
      description: description,
      amount: sum(pairs, :line_extension_amount),
      tax_amount: sum(pairs, :tax_amount),
      tax_type: tax_type,
      tax_rate: tax_rate,
      tax_exemption_reason: reason,
      source_ids: pairs |> Enum.map(fn {source, _} -> source.id end) |> Enum.uniq()
    }
  end

  defp sum(pairs, field),
    do:
      Enum.reduce(pairs, Decimal.new("0.00"), fn {_, line}, total ->
        Decimal.add(total, Map.fetch!(line, field))
      end)

  @doc """
  Records which sources each line of the consolidated document carries,
  and a `consolidated` status event on each source, inside the transaction
  that recorded the document.
  """
  def record_sources!(%Scope{} = scope, company_id, document, groups) do
    groups
    |> Enum.with_index(1)
    |> Enum.each(fn {group, line_number} ->
      for source_id <- group.source_ids do
        Repo.insert!(%ConsolidatedSource{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          document_id: document.id,
          source_document_id: source_id,
          line_number: line_number
        })
      end
    end)

    groups
    |> Enum.flat_map(& &1.source_ids)
    |> Enum.uniq()
    |> Enum.each(fn source_id ->
      Documents.record_event!(scope, company_id, source_id, %{
        event: "consolidated",
        reason: "consolidated in #{document.code_number}"
      })
    end)
  end

  @doc """
  What a document's consolidation says: `sources`, the documents a
  consolidated document covers (each a summary with the `line_numbers`
  carrying it), and `consolidated_by`, the consolidated document that
  holds a source now (`nil` when none does).
  """
  def view(%Scope{} = scope, company_id, document_id) do
    covered =
      from(c in Tenancy.scope_query(ConsolidatedSource, scope),
        where: c.company_id == ^company_id and c.document_id == ^document_id,
        order_by: [asc: c.line_number, asc: c.source_document_id],
        select: {c.source_document_id, c.line_number}
      )
      |> Repo.all()

    holders =
      from(c in Tenancy.scope_query(ConsolidatedSource, scope),
        where: c.company_id == ^company_id and c.source_document_id == ^document_id,
        distinct: true,
        select: c.document_id
      )
      |> Repo.all()

    ids = Enum.uniq(Enum.map(covered, &elem(&1, 0)) ++ holders)
    documents = documents(scope, company_id, ids)
    statuses = Documents.statuses(scope, company_id, ids)

    sources =
      covered
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {id, line_numbers} ->
        documents
        |> Map.fetch!(id)
        |> Documents.summary_view(statuses[id])
        |> Map.put(:line_numbers, line_numbers)
      end)
      |> Enum.sort_by(&{DateTime.to_unix(&1.issued_at), &1.id})

    holder = Enum.find(holders, fn id -> statuses[id] not in @releasing end)

    %{
      sources: sources,
      consolidated_by:
        holder && Documents.summary_view(Map.fetch!(documents, holder), statuses[holder])
    }
  end

  defp documents(_scope, _company_id, []), do: %{}

  defp documents(scope, company_id, ids) do
    scope
    |> Documents.documents_query(company_id)
    |> where([d], d.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  Records `released` on each source a consolidated document holds, once
  the authority refused it, found it invalid, or cancelled it, inside the
  transaction recording that event. A source already released, or never
  consolidated, is left alone.
  """
  def release_sources!(%Scope{} = scope, company_id, document_id, event)
      when event in @releasing do
    source_ids =
      from(c in Tenancy.scope_query(ConsolidatedSource, scope),
        where: c.company_id == ^company_id and c.document_id == ^document_id,
        distinct: true,
        select: c.source_document_id
      )
      |> Repo.all()

    code_number =
      scope
      |> Documents.documents_query(company_id)
      |> where([d], d.id == ^document_id)
      |> select([d], d.code_number)
      |> Repo.one()

    scope
    |> Documents.statuses(company_id, source_ids)
    |> Enum.filter(fn {_id, status} -> status == "consolidated" end)
    |> Enum.sort()
    |> Enum.each(fn {source_id, _status} ->
      Documents.record_event!(scope, company_id, source_id, %{
        event: "released",
        reason: "#{code_number} is #{event}"
      })
    end)
  end

  def release_sources!(_scope, _company_id, _document_id, _event), do: :ok
end
