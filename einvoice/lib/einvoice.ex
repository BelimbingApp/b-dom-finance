defmodule Bilimbi.Finance.Einvoice do
  @moduledoc """
  A company's fiscal documents, cleared by a tax authority: what it issued,
  what it submitted, and every answer the authority gave.

  Every function takes the validated `Bilimbi.Base.Tenancy.Scope` it was
  handed and an explicit company ID, and authorizes its capability for the
  scope's signed-in actor and the target company when it runs, through
  `Bilimbi.Core.Company.authorize_company_target/3`: a system scope, a
  missing grant, or a sibling company without tenant-wide reach is
  `{:error, :unauthorized}`, and a company the scope cannot see is
  `{:error, :company_not_found}`. A write holds
  `Bilimbi.Core.Company.lock_writable_company/2` for its transaction, so an
  archived company is `{:error, :company_archived}`.

  `issue_document/3` takes plain attributes, so a form, an import, an agent
  operation, and later receivables all issue through it. It derives every
  amount from the lines, checks the document against the authority's rules
  and the company's code lists, and records it with its lines, its supplier
  and buyer as they stood, and an `issued` status event. A credit, debit,
  or refund note names the validated (or buyer-rejected) original it corrects.
  A self-billed document is issued by the company as the buyer, with the
  supplier as the counterparty. `issue_consolidated_document/3` reports a
  month of sales no buyer asked an individual document for in one
  consolidated document (`Bilimbi.Finance.Einvoice.Consolidation`). A recorded
  document is never edited or deleted: the database refuses it (see the
  migration), and a cancellation, a rejection, or any other answer from the
  authority is a new status event.

  `submit_document/3` queues the submission as the signed-in user;
  `Bilimbi.Finance.Einvoice.Clearance` owns what the submit and poll jobs
  record, `refresh_status/3` and `cancel_document/4` the user-driven
  reads and the guarded cancellation, and
  `Bilimbi.Finance.Einvoice.Posting` the ledger entry a validated document
  posts and a cancelled one reverses. `generate_pdf/3` renders the
  printable document through Base Artifacts.

  Results are plain maps; the schemas stay private to this module.
  """

  import Ecto.Query

  alias Bilimbi.Base.Artifacts
  alias Bilimbi.Base.Queue
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Einvoice.ArtifactOwner
  alias Bilimbi.Finance.Einvoice.Certificate
  alias Bilimbi.Finance.Einvoice.Clearance
  alias Bilimbi.Finance.Einvoice.CodeLists
  alias Bilimbi.Finance.Einvoice.Configuration
  alias Bilimbi.Finance.Einvoice.Consolidation
  alias Bilimbi.Finance.Einvoice.Documents
  alias Bilimbi.Finance.Einvoice.{Document, Draft, Line, StatusEvent, SubmitWorker}
  alias Bilimbi.Finance.Ledger
  alias Ecto.Changeset

  @view "finance.einvoice.view"
  @issue "finance.einvoice.documents.issue"
  @submit "finance.einvoice.documents.submit"
  @cancel "finance.einvoice.documents.cancel"
  @settings "finance.einvoice.settings.manage"

  @default_limit 50
  @max_limit 200
  @max_bigint 9_223_372_036_854_775_807
  @page_sizes [25, 50, 100, 300]

  @type refusal :: :unauthorized | :company_not_found
  @type write_refusal :: refusal() | :company_archived

  @doc "The capability every read asks for."
  def view_capability, do: @view

  @doc "The capability that issues documents."
  def issue_capability, do: @issue

  @doc "The capability that submits documents to the authority and refreshes their status."
  def submit_capability, do: @submit

  @doc "The capability that cancels a validated document."
  def cancel_capability, do: @cancel

  @doc "The capability that manages the company's e-invoicing settings and code overrides."
  def settings_capability, do: @settings

  @doc "The events that move a document's status."
  def status_events, do: Documents.status_events()

  ## Documents

  @doc """
  Issues a document from plain attributes:

    * `document_type` (the authority's code; `01` for an invoice) and
      `code_number`, the company's own number for it, unique per environment;
    * optionally `issued_at` (UTC, not in the future; default now);
    * `currency_code` and, for a currency other than the authority's,
      `exchange_rate`;
    * `buyer`: `name`, `tax_id`, `registration_type` and
      `registration_number`, optional `sales_tax_registration`, `email`,
      `phone`, and `address` (`lines`, `city`, `postcode`, `state_code`,
      `country_code`); or, for a self-billed document (the authority's `11`
      to `14`), `supplier` in the same shape plus `industry_code` and
      `business_activity`, the company's own profile being the buyer;
    * optionally `payment_means_code`, `payment_terms`, and a billing period
      (`billing_period_start`, `billing_period_end`,
      `billing_period_description`);
    * for a credit, debit, or refund note (the authority's `02` to `04`, or
      self-billed `12` to `14`), `original_document_id`: a validated
      invoice of this company of the same kind, whose code number and UUID
      the note carries;
    * `lines`, each with `description`, `classification_code`, `quantity`,
      `unit_price`, `tax_type`, and `tax_rate` (always stated, `0` where the
      authority takes no tax), and optionally `unit_code`, `discount_amount`,
      `charge_amount` (blank is none), `tax_exemption_reason`, `tariff_code`,
      and `origin_country_code`;
    * optionally `source`, the transaction this document is the tax document
      of, when another module already recognised it in the ledger: `module`
      (that module's descriptor ID, `finance/receivables` or
      `finance/payables`), `record` (its record, `document:17`), and
      `ledger_entry_id`, the entry that record posted. The ledger must hold
      that entry for that owner, unreversed and not itself a reversal, in
      the document's currency and for the document's total; and no other
      document that stands (submitted, valid, rejected, or consolidated)
      may link the same source. The link is recorded with the document. A
      linked document never posts to the ledger when validated, nor
      reverses when cancelled: its accounting, and its correction (a credit
      note, a payment reversal), belong to the source module, and the note
      issued for that correction links to the correcting record, and is
      refused without a `source` when its original is linked. Reading
      the entry needs `finance.ledger.view`.

  The company's own party (the supplier, or the buyer of a self-billed
  document) comes from its e-invoicing settings and the environment from
  its current setting. Amounts are derived, never taken:
  a line's subtotal is quantity times unit price, less its discount plus
  its charge, and its tax is that times the rate, each rounded half up to
  two places. Refusals are a changeset (a `source` error says what the
  ledger holds instead); `{:error, :code_number_taken}` when the company
  already issued that number in the environment.
  """
  @spec issue_document(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :code_number_taken | Changeset.t()}
  def issue_document(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @issue, fn company ->
      profile = Configuration.supplier(scope, company_id, company.display_name)
      codes = code_lookup(scope, company_id)

      draft_changeset =
        Draft.changeset(attributes, DateTime.utc_now(),
          self_billed_types: authority().self_billed_document_types()
        )

      original = original_document(scope, company_id, draft_changeset)

      changeset =
        validate_with_authority(draft_changeset, %{
          supplier: profile,
          codes: codes,
          original: original
        })

      with {:ok, draft} <- Changeset.apply_action(changeset, :insert),
           :ok <- unused_code_number(scope, company_id, environment(scope, company_id), draft),
           {:ok, source} <- source_link(scope, company_id, changeset, draft, original, attributes) do
        document =
          record_document!(scope, company_id, profile, draft, details(draft, original), original)

        if source, do: Documents.record_source_link!(scope, company_id, document.id, source)
        view = get_view(scope, company_id, document.id)

        record_action(scope, company_id, "finance.einvoice.document.issued", %{
          "document_id" => view.id,
          "document_type" => view.document_type,
          "code_number" => view.code_number,
          "environment" => view.environment,
          "original_document_id" => view.original_document_id,
          "source_module" => source && source.module,
          "source_record" => source && source.record,
          "source_ledger_entry_id" => source && source.ledger_entry_id
        })

        {:ok, view}
      end
    end)
  end

  # The document, its lines, and its `issued` event. The company's profile
  # is the supplier, or the buyer of a self-billed document, whose supplier
  # is the counterparty the caller gave.
  defp record_document!(scope, company_id, profile, draft, details, original) do
    %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

    {supplier, buyer} =
      if draft.document_type in authority().self_billed_document_types(),
        do: {supplier_party_snapshot(draft.supplier), supplier_snapshot(profile)},
        else: {supplier_snapshot(profile), party_snapshot(draft.buyer)}

    document =
      Repo.insert!(%Document{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        authority: authority().id(),
        environment: environment(scope, company_id),
        document_type: draft.document_type,
        code_number: draft.code_number,
        issued_at: draft.issued_at,
        currency_code: draft.currency_code,
        exchange_rate: draft.exchange_rate,
        supplier: supplier,
        buyer: buyer,
        details: details,
        original_document_id: original && original.id,
        line_extension_amount: draft.line_extension_amount,
        tax_exclusive_amount: draft.line_extension_amount,
        tax_amount: draft.tax_amount,
        tax_inclusive_amount: Decimal.add(draft.line_extension_amount, draft.tax_amount),
        payable_amount: Decimal.add(draft.line_extension_amount, draft.tax_amount),
        issued_by_user_id: user_id,
        issued_by_impersonator_id: impersonator_id
      })

    insert_lines(document, draft.lines)

    Repo.insert!(%StatusEvent{
      tenant_id: document.tenant_id,
      company_id: company_id,
      document_id: document.id,
      event: "issued",
      actor_type: "user",
      actor_user_id: user_id,
      actor_impersonator_id: impersonator_id
    })

    document
  end

  ## Consolidated documents

  @doc """
  What a consolidated document for `month` (`"YYYY-MM"`, or a `Date` in
  it) would cover in the company's current environment:
  `%{month, from, until, closes_at, open?, documents, refused,
  line_extension_amount, tax_amount, payable_amount}`. `documents` are
  the eligible documents, oldest first, as summaries; `refused` pairs each
  document the authority's limits keep out (`document`) with its `reason`;
  the amounts are the eligible documents' totals. `from` and `until` bound
  the issue instants it covers, and it may be issued from `until` until
  `closes_at` (`open?` says whether that is now). `{:error, :invalid_month}`
  for a month that cannot be read.
  """
  @spec consolidation_candidates(Scope.t(), term(), String.t() | Date.t()) ::
          {:ok, map()} | {:error, refusal() | :invalid_month}
  def consolidation_candidates(%Scope{} = scope, company_id, month) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, month} <- month(month) do
      window = authority().consolidation_window(month)
      environment = environment(scope, company_id)
      {eligible, refused} = Consolidation.candidates(scope, company_id, environment, window)
      statuses = Documents.statuses(scope, company_id, Enum.map(eligible, & &1.id))

      {:ok,
       %{
         month: month,
         environment: environment,
         from: window.from,
         until: window.until,
         closes_at: window.closes_at,
         open?: Consolidation.open(window, consolidation_clock()) == :ok,
         documents: Enum.map(eligible, &Documents.summary_view(&1, statuses[&1.id])),
         refused:
           Enum.map(refused, fn {document, reason} ->
             %{document: Documents.summary_view(document, nil), reason: reason}
           end),
         line_extension_amount: sum(eligible, :line_extension_amount),
         tax_amount: sum(eligible, :tax_amount),
         payable_amount: sum(eligible, :payable_amount)
       }}
    end
  end

  @doc """
  Issues the consolidated document for a month's sales no buyer asked an
  individual document for, from plain attributes: `month` (`"YYYY-MM"`),
  `code_number`, optionally `document_ids` (the eligible documents to
  cover; default every one `consolidation_candidates/3` lists). Its lines
  are one per covered document and tax.

  It is issued now, which must fall inside the authority's window after
  the month ends (`{:error, :period_not_ended}`,
  `{:error, :consolidation_window_closed}`). The authority shapes it
  (the general buyer, the consolidated classification, the month as its
  billing period); each line's amount and tax are its documents' exact
  sums, so its totals equal theirs. It records which documents each line
  covers and a `consolidated` event on each, so none is consolidated twice
  or submitted on its own while it holds them; once the authority refuses
  it, finds it invalid, or it is cancelled, it releases them (`released`)
  and is never submitted again. It is
  submitted, polled, posted, and cancelled like any document, and is the
  audit action `finance.einvoice.document.consolidated`. Sources issued
  with a `source` (a transaction another module recognised in the ledger)
  pass their links on: the consolidated document then never posts either.
  Sources with links and sources without do not consolidate together
  (`{:error, :mixed_source_links}`).

  Other refusals: `{:error, :nothing_to_consolidate}`,
  `{:error, {:not_consolidatable, document_id}}` for a named document that
  is not eligible, `{:error, :invalid_month}`, `{:error, :invalid_option}`,
  `{:error, :code_number_taken}`, or a changeset.
  """
  @spec issue_consolidated_document(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, term()}
  def issue_consolidated_document(%Scope{} = scope, company_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @issue, fn company ->
      now = consolidation_clock()

      with {:ok, request} <- consolidation_request(attributes),
           window = authority().consolidation_window(request.month),
           :ok <- Consolidation.open(window, now),
           environment = environment(scope, company_id),
           {eligible, _refused} = Consolidation.candidates(scope, company_id, environment, window),
           {:ok, sources} <- chosen_sources(eligible, request.document_ids),
           links = Documents.source_links_of(scope, company_id, Enum.map(sources, & &1.id)),
           :ok <- consistent_links(sources, links) do
        groups = Consolidation.group(sources)
        profile = Configuration.supplier(scope, company_id, company.display_name)

        attributes =
          authority().consolidated_document(%{
            code_number: request.code_number,
            issued_at: DateTime.truncate(now, :second),
            month: request.month,
            lines: groups
          })

        changeset =
          attributes
          |> Draft.changeset(now, source_tax: true)
          |> validate_with_authority(%{
            supplier: profile,
            codes: code_lookup(scope, company_id),
            original: nil,
            consolidated: true
          })

        with {:ok, draft} <- Changeset.apply_action(changeset, :insert),
             :ok <- unused_code_number(scope, company_id, environment, draft) do
          details =
            draft
            |> details(nil)
            |> Map.put(Consolidation.month_key(), Calendar.strftime(request.month, "%Y-%m"))

          document = record_document!(scope, company_id, profile, draft, details, nil)
          Consolidation.record_sources!(scope, company_id, document, groups)

          for source <- sources,
              link <- Map.get(links, source.id, []),
              do: Documents.record_source_link!(scope, company_id, document.id, link)

          view = get_view(scope, company_id, document.id)

          record_action(scope, company_id, "finance.einvoice.document.consolidated", %{
            "document_id" => view.id,
            "code_number" => view.code_number,
            "environment" => view.environment,
            "month" => details[Consolidation.month_key()],
            "document_count" => length(sources)
          })

          {:ok, view}
        end
      end
    end)
  end

  # The instant a consolidated document is issued and its window judged at.
  # Only tests set `:clock` (a function of no arguments), to stand inside a
  # window that a real clock reaches only after a month's end.
  defp consolidation_clock do
    case Application.get_env(:bilimbi_finance_einvoice, :clock) do
      nil -> DateTime.utc_now()
      clock when is_function(clock, 0) -> clock.()
    end
  end

  defp month(month) do
    case Consolidation.parse_month(month) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, :invalid_month}
    end
  end

  defp consolidation_request(attributes) do
    get = fn key -> Map.get(attributes, key, Map.get(attributes, Atom.to_string(key))) end
    ids = get.(:document_ids)

    with {:ok, month} <- month(get.(:month)),
         true <-
           (is_nil(ids) or
              (is_list(ids) and ids != [] and Enum.all?(ids, &(is_integer(&1) and &1 > 0)))) ||
             {:error, :invalid_option} do
      {:ok,
       %{
         month: month,
         code_number: get.(:code_number),
         document_ids: ids && Enum.uniq(ids)
       }}
    end
  end

  # A consolidated document's accounting is either its own or its sources'.
  defp consistent_links(sources, links) do
    if map_size(links) in [0, length(sources)], do: :ok, else: {:error, :mixed_source_links}
  end

  defp chosen_sources([], nil), do: {:error, :nothing_to_consolidate}
  defp chosen_sources(eligible, nil), do: {:ok, eligible}

  defp chosen_sources(eligible, ids) do
    by_id = Map.new(eligible, &{&1.id, &1})

    case Enum.find(ids, &(not Map.has_key?(by_id, &1))) do
      nil -> {:ok, eligible |> Enum.filter(&(&1.id in ids))}
      id -> {:error, {:not_consolidatable, id}}
    end
  end

  defp sum(documents, field),
    do: Enum.reduce(documents, Decimal.new("0.00"), &Decimal.add(Map.fetch!(&1, field), &2))

  # A note's original, read before the authority judges it: the same
  # company's document, or `nil`.
  defp original_document(scope, company_id, changeset) do
    case Changeset.get_field(changeset, :original_document_id) do
      id when is_integer(id) and id > 0 ->
        case Documents.fetch(scope, company_id, id) do
          nil -> nil
          fetched -> Documents.document_view(fetched)
        end

      _none ->
        nil
    end
  end

  @doc """
  One document with its lines, its status events in order, and its current
  `status`: the latest status-moving event (`issued`, `submitted`,
  `refused`, `valid`, `invalid`, `cancelled`, `rejected`, and for a
  document a consolidated document covers, `consolidated` or `released`).
  The view names the `counterparty_name` (the buyer, or the supplier of a
  self-billed document) and says whether the document is `self_billed?`
  or `consolidated?`; a consolidated document lists the documents it
  covers as `sources` (each with the `line_numbers` carrying it), and a
  covered document names its holder as `consolidated_by`. It also
  carries what the events say: `submission_uid`, `document_uuid`,
  `long_id`, `validated_at`, `validation_url`, `cancellable_until`,
  `ledger_entry_id`, `reversal_entry_id`, `source_links` (the transactions
  it is the tax document of, each `module`, `record`, and
  `ledger_entry_id`; `recognised_by_source?` when there are any, and then
  it never posts or reverses an entry itself), `pdf_artifact_id`, and
  `attention`, the flags an operator should look at (`:overdue`,
  `:rejection_requested`, `:unposted`, `:posting_failed`, `:unreversed`,
  `:reversal_failed`), and `submission_queued`, whether a submit job for
  the document is waiting or running.
  """
  @spec get_document(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :document_not_found}
  def get_document(%Scope{} = scope, company_id, document_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case Documents.fetch(scope, company_id, document_id) do
        nil ->
          {:error, :document_not_found}

        {record, _events, _links} ->
          {:ok, get_view(scope, company_id, record.id)}
      end
    end
  end

  @doc """
  The company's documents, newest first, without lines or events. Options:
  `limit` (1 to #{@max_limit}, default #{@default_limit}) and `before`, the
  ID of the last document already read. A malformed option is
  `{:error, :invalid_option}`.
  """
  @spec list_documents(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_documents(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    limit = Keyword.get(options, :limit, @default_limit)
    before = Keyword.get(options, :before)

    with :ok <- authorize(scope, company_id, @view),
         true <-
           (is_integer(limit) and limit in 1..@max_limit and
              (is_nil(before) or (is_integer(before) and before in 1..@max_bigint))) ||
             {:error, :invalid_option} do
      documents =
        scope
        |> Documents.documents_query(company_id)
        |> then(fn query -> if before, do: where(query, [d], d.id < ^before), else: query end)
        |> order_by([d], desc: d.id)
        |> limit(^limit)
        |> Repo.all()

      statuses = Documents.statuses(scope, company_id, Enum.map(documents, & &1.id))
      {:ok, Enum.map(documents, &Documents.summary_view(&1, Map.get(statuses, &1.id)))}
    end
  end

  @doc """
  One page of the company's documents, newest first, for a list page:
  `%{entries, page, page_size, total_entries, total_pages, has_prev?,
  has_next?}`. Options: `page` (default 1), `page_size` (one of
  #{inspect(@page_sizes)}, default 25), `search` (code number or buyer
  name), `status`, `document_type`, and `environment`. A malformed option
  is `{:error, :invalid_option}`.
  """
  @spec page_documents(Scope.t(), term(), keyword()) ::
          {:ok, map()} | {:error, refusal() | :invalid_option}
  def page_documents(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    page = Keyword.get(options, :page, 1)
    page_size = Keyword.get(options, :page_size, 25)

    filters =
      Enum.map([:search, :status, :document_type, :environment], &{&1, Keyword.get(options, &1)})

    with :ok <- authorize(scope, company_id, @view),
         true <-
           (is_integer(page) and page > 0 and page_size in @page_sizes and
              Enum.all?(filters, fn {_key, value} -> is_nil(value) or is_binary(value) end)) ||
             {:error, :invalid_option} do
      {:ok, Documents.page(scope, company_id, [page: page, page_size: page_size] ++ filters)}
    end
  end

  @doc "The page sizes `page_documents/3` accepts."
  def page_sizes, do: @page_sizes

  ## Clearance

  @doc """
  Queues the document's submission to the authority as the signed-in
  user: `{:ok, %{job_id: id}}`. Refused before queuing when the document's
  status is not `issued`, `refused`, or `invalid` (`:not_submittable`),
  another document that stands already links a source of this one and
  no earlier attempt of this one is unresolved (`:source_taken`; an
  unresolved attempt is looked up at the authority first), the company
  lacks credentials for the document's environment (`:missing_credentials`),
  or the chosen format version needs a signature and the certificate and key
  are missing or mismatched (`:signing_key_required`), or a submit job for
  the document is already waiting or running (`:already_queued`).
  """
  @spec submit_document(Scope.t(), term(), term()) ::
          {:ok, %{job_id: pos_integer()}}
          | {:error,
             write_refusal()
             | :document_not_found
             | :not_submittable
             | :source_taken
             | :missing_credentials
             | :signing_key_required
             | atom()}
  def submit_document(%Scope{} = scope, company_id, document_id) do
    write(scope, company_id, @submit, fn _company ->
      with {:ok, document} <- found(Documents.fetch(scope, company_id, document_id)),
           {:ok, _prepared} <- Clearance.prepare(scope, company_id, document),
           :ok <- source_free_to_submit(scope, company_id, document),
           :ok <- not_queued(company_id, document.id),
           {:ok, job} <-
             Queue.enqueue_for(scope, SubmitWorker, %{
               "company_id" => company_id,
               "document_id" => document.id
             }) do
        record_action(scope, company_id, "finance.einvoice.submission.queued", %{
          "document_id" => document.id,
          "code_number" => document.code_number,
          "environment" => document.environment,
          "job_id" => job.id
        })

        {:ok, %{job_id: job.id}}
      end
    end)
  end

  defp source_free_to_submit(scope, company_id, document) do
    if Clearance.unresolved_attempts(scope, company_id, document) == [] and
         Documents.source_taken?(scope, company_id, document),
       do: {:error, :source_taken},
       else: :ok
  end

  defp not_queued(company_id, document_id) do
    if Documents.submission_queued?(company_id, document_id),
      do: {:error, :already_queued},
      else: :ok
  end

  # The full view with the consolidation it takes part in and whether a
  # submit job for it is waiting.
  defp get_view(scope, company_id, document_id) do
    scope
    |> Documents.fetch(company_id, document_id)
    |> Documents.document_view()
    |> Map.merge(Consolidation.view(scope, company_id, document_id))
    |> Map.put(:submission_queued, Documents.submission_queued?(company_id, document_id))
  end

  @doc """
  Reads the document's status at the authority and records what changed
  (see `Bilimbi.Finance.Einvoice.Clearance`): the document's view
  afterwards. `{:error, :not_submitted}` before the authority has given
  it a UUID; `{:error, {:authority, reason}}` when the authority could not
  answer.
  """
  @spec refresh_status(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error, refusal() | :document_not_found | :not_submitted | {:authority, term()}}
  def refresh_status(%Scope{} = scope, company_id, document_id) do
    with {:ok, _company} <- authorize_company(scope, company_id, @submit),
         {:ok, document} <- found(Documents.fetch(scope, company_id, document_id)) do
      Clearance.refresh(scope, company_id, document.id, DateTime.utc_now())
    end
  end

  @doc """
  Cancels a validated document at the authority with `reason` (1 to 300
  characters), inside the #{Documents.cancellation_window_hours()}-hour
  window after validation and only while no note the authority holds
  references it; then records `cancelled` and reverses the document's
  ledger entry. Refusals: `:not_cancellable`,
  `:cancellation_period_over`, `:active_referencing_documents`,
  `:invalid_reason`, `{:refused, code, reason}` from the authority,
  `:rate_limited`, and `:authority_unavailable`.
  """
  @spec cancel_document(Scope.t(), term(), term(), String.t()) ::
          {:ok, map()} | {:error, refusal() | :document_not_found | term()}
  def cancel_document(%Scope{} = scope, company_id, document_id, reason) do
    with {:ok, _company} <- authorize_company(scope, company_id, @cancel),
         {:ok, document} <- found(Documents.fetch(scope, company_id, document_id)) do
      Clearance.cancel(scope, company_id, document.id, reason, DateTime.utc_now())
    end
  end

  @doc """
  Posts the ledger entry of a valid document whose posting failed or was
  never attempted, once its cause is fixed. It needs the submit capability
  and also the ledger's entry-posting grant, so a refused actor leaves no
  failed event behind. A document that already has its entry comes back
  unchanged. `{:error, {:failed, reason}}` when the posting fails again
  (recorded as a `posting_failed` event), `{:error, :not_postable}` for a
  document that is neither valid nor rejected. Each try is the audit action
  `finance.einvoice.posting.retried`.
  """
  @spec retry_posting(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error, refusal() | :document_not_found | :not_postable | {:failed, String.t()}}
  def retry_posting(%Scope{} = scope, company_id, document_id) do
    with {:ok, _company} <- authorize_company(scope, company_id, @submit),
         {:ok, _company} <- authorize_company(scope, company_id, Ledger.post_entries_capability()) do
      Clearance.retry_posting(scope, company_id, document_id)
    end
  end

  @doc """
  Reverses the ledger entry of a cancelled document whose reversal failed
  or was never attempted. The same guards, results, and audit action as
  `retry_posting/3`; `{:error, :not_reversible}` for a document that is
  not cancelled.
  """
  @spec retry_reversal(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error, refusal() | :document_not_found | :not_reversible | {:failed, String.t()}}
  def retry_reversal(%Scope{} = scope, company_id, document_id) do
    with {:ok, _company} <- authorize_company(scope, company_id, @submit),
         {:ok, _company} <- authorize_company(scope, company_id, Ledger.post_entries_capability()) do
      Clearance.retry_reversal(scope, company_id, document_id, DateTime.utc_now())
    end
  end

  @doc false
  # The submit job's body: one attempt, as the job's user.
  def run_submission(%Scope{} = scope, company_id, document_id) do
    with {:ok, _company} <- authorize_company(scope, company_id, @submit) do
      Clearance.submit(scope, company_id, document_id, DateTime.utc_now())
    end
  end

  @doc false
  # The poll job's body.
  def run_poll(%Scope{} = scope, company_id, document_id) do
    with {:ok, _company} <- authorize_company(scope, company_id, @submit) do
      Clearance.poll(scope, company_id, document_id, DateTime.utc_now())
    end
  end

  ## Reconciliation

  @doc """
  The documents whose ledger side does not match their status: `unposted`,
  valid (or buyer-rejected) documents without a ledger entry (with the reason the last
  posting failed, if one did), and `unreversed`, cancelled documents
  whose entry stands. Each row is a
  document summary with `ledger_entry_id`, `reversal_entry_id`, and
  `reason`.
  """
  @spec reconciliation(Scope.t(), term()) ::
          {:ok, %{unposted: [map()], unreversed: [map()]}} | {:error, refusal()}
  def reconciliation(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok, Documents.reconciliation(scope, company_id)}
    end
  end

  ## Printable document

  @doc """
  Renders the document as a PDF through Base Artifacts and records it on a
  `pdf_generated` event: `{:ok, %{artifact_id, byte_size, sha256}}`. The
  artifact is read back with `read_pdf/3`. Base Artifacts must have a
  storage root and retention period configured (`{:error, reason}` from
  it otherwise). The event keeps the sequence of the last other event the
  PDF was rendered from; while the document has gained none since, asking
  again returns that artifact and records nothing.
  """
  @spec generate_pdf(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, write_refusal() | :document_not_found | term()}
  def generate_pdf(%Scope{} = scope, company_id, document_id) do
    with {:ok, _company} <- authorize_company(scope, company_id, @view),
         {:ok, document} <- found(Documents.fetch(scope, company_id, document_id)) do
      case current_pdf(document) do
        {:ok, stored} -> {:ok, stored}
        nil -> render_pdf(scope, company_id, document)
      end
    end
  end

  defp current_pdf(%{events: events}) do
    as_of = rendered_sequence(events)

    with %{response: %{"as_of_sequence" => ^as_of} = response} <-
           events |> Enum.filter(&(&1.event == "pdf_generated")) |> List.last(),
         %{"artifact_id" => id, "byte_size" => size, "sha256" => sha256} <- response do
      {:ok, %{artifact_id: id, byte_size: size, sha256: sha256}}
    else
      _other -> nil
    end
  end

  defp rendered_sequence(events) do
    events |> Enum.reject(&(&1.event == "pdf_generated")) |> Enum.map(& &1.sequence) |> Enum.max()
  end

  defp render_pdf(scope, company_id, document) do
    with {:ok, stored} <-
           Artifacts.generate_pdf(
             scope,
             company_id,
             ArtifactOwner,
             ArtifactOwner.reference(document),
             %{document: document}
           ) do
      write(scope, company_id, @view, fn _company ->
        Documents.record_event!(scope, company_id, document.id, %{
          event: "pdf_generated",
          response: %{
            "artifact_id" => stored.id,
            "byte_size" => stored.byte_size,
            "sha256" => stored.sha256,
            "as_of_sequence" => rendered_sequence(document.events)
          }
        })

        record_action(scope, company_id, "finance.einvoice.pdf.generated", %{
          "document_id" => document.id,
          "code_number" => document.code_number,
          "artifact_id" => stored.id
        })

        {:ok, %{artifact_id: stored.id, byte_size: stored.byte_size, sha256: stored.sha256}}
      end)
    end
  end

  @doc "The bytes of a PDF `generate_pdf/3` stored, for the download route."
  @spec read_pdf(Scope.t(), term(), String.t()) ::
          {:ok, %{bytes: binary(), filename: String.t()}} | {:error, term()}
  def read_pdf(%Scope{} = scope, company_id, artifact_id) when is_binary(artifact_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, %{bytes: bytes, metadata: metadata}} <-
           Artifacts.read(scope, company_id, ArtifactOwner, artifact_id) do
      {:ok, %{bytes: bytes, filename: ArtifactOwner.filename(metadata)}}
    end
  end

  def read_pdf(%Scope{}, _company_id, _artifact_id), do: {:error, :not_found}

  ## Code lists

  @doc "The company's active codes in one of the authority's lists, code to description."
  @spec list_codes(Scope.t(), term(), String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, refusal() | :unknown_list}
  def list_codes(%Scope{} = scope, company_id, list) do
    with :ok <- authorize(scope, company_id, @view) do
      if list in CodeLists.lists(authority().id()),
        do: {:ok, CodeLists.codes(scope, company_id, authority().id(), list)},
        else: {:error, :unknown_list}
    end
  end

  @doc """
  Overrides one code for the company: `description` renames it, or names a
  code the shipped list lacks, and `active: false` retires it.
  """
  @spec override_code(Scope.t(), term(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :unknown_list | Changeset.t()}
  def override_code(%Scope{} = scope, company_id, list, code, attributes)
      when is_binary(list) and is_binary(code) and is_map(attributes) do
    write(scope, company_id, @settings, fn _company ->
      with {:ok, override} <-
             CodeLists.put_override(scope, company_id, authority().id(), list, code, attributes) do
        record_action(scope, company_id, "finance.einvoice.code.overridden", %{
          "list" => override.list,
          "code" => override.code,
          "description" => override.description,
          "active" => override.active
        })

        {:ok, override}
      end
    end)
  end

  ## Setup

  @doc """
  What the company has configured, without any secret: the environment,
  which credentials are present, the client secret's expiry, the
  certificate's issuer, serial, subject numbers and validity, whether the
  private key matches it, and the supplier profile's missing fields.
  `expiring` lists what expires within the alert window (or already has):
  `:certificate` and `:client_secret`.
  """
  @spec setup(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, refusal()}
  def setup(%Scope{} = scope, company_id, now \\ DateTime.utc_now()) do
    with {:ok, company} <- authorize_company(scope, company_id, @settings) do
      credentials = Configuration.credentials(scope, company_id)
      supplier = Configuration.supplier(scope, company_id, company.display_name)
      certificate = certificate_summary(credentials, now)
      alert_days = credentials.expiry_alert_days

      secret_days =
        credentials.secret_expires_on &&
          Date.diff(credentials.secret_expires_on, DateTime.to_date(now))

      expiring =
        Enum.reject(
          [
            certificate[:days_until_expiry] && certificate.days_until_expiry <= alert_days &&
              :certificate,
            secret_days && secret_days <= alert_days && :client_secret
          ],
          &(&1 in [nil, false])
        )

      {:ok,
       %{
         environment: credentials.environment,
         document_version: Configuration.document_version(scope, company_id),
         posting_accounts: Configuration.posting_accounts(scope, company_id),
         client_id?: not is_nil(credentials.client_id),
         client_secret?: not is_nil(credentials.client_secret),
         client_secret_expires_on: credentials.secret_expires_on,
         certificate: certificate,
         expiry_alert_days: alert_days,
         expiring: expiring,
         supplier_missing: authority().supplier_missing(supplier),
         tax_id_matches_certificate?:
           not is_nil(supplier.tax_id) and is_map(certificate) and
             certificate[:tax_id] == supplier.tax_id
       }}
    end
  end

  @doc """
  Logs in to the authority with the company's current environment and
  credentials, and records the outcome as the audit action
  `finance.einvoice.connection.tested`. `:ok`, or `{:error, reason}` where
  `reason` is `:missing_credentials`, `{:http, status, body}`, or
  `{:transport, exception}`.
  """
  @spec test_connection(Scope.t(), term()) :: :ok | {:error, term()}
  def test_connection(%Scope{} = scope, company_id) do
    with {:ok, _company} <- authorize_company(scope, company_id, @settings) do
      credentials = Configuration.credentials(scope, company_id)

      outcome = authority().login(scope, company_id, credentials)

      record_action(scope, company_id, "finance.einvoice.connection.tested", %{
        "environment" => credentials.environment,
        "outcome" => outcome_name(outcome)
      })

      outcome
    end
  end

  defp outcome_name(:ok), do: "succeeded"
  defp outcome_name({:error, :missing_credentials}), do: "missing_credentials"
  defp outcome_name({:error, {:http, status, _body}}), do: "refused_#{status}"
  defp outcome_name({:error, {:retry_after, _seconds, status, _body}}), do: "refused_#{status}"
  defp outcome_name({:error, {:transport, _exception}}), do: "unreachable"
  defp outcome_name({:error, _reason}), do: "failed"

  ## Authorization and writes

  defp authorize(scope, company_id, capability) do
    with {:ok, _company} <- authorize_company(scope, company_id, capability), do: :ok
  end

  # The actor's current grant and company reach decide every call.
  defp authorize_company(scope, company_id, capability) do
    case Company.authorize_company_target(scope, company_id, capability) do
      {:ok, _company} ->
        case Company.identity(scope, company_id) do
          {:ok, identity} -> {:ok, identity}
          {:error, :not_found} -> {:error, :company_not_found}
        end

      {:error, :not_found} ->
        {:error, :company_not_found}

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  defp write(scope, company_id, capability, fun) do
    with {:ok, company} <- authorize_company(scope, company_id, capability) do
      Repo.transact(fn ->
        case Company.lock_writable_company(scope, company_id) do
          {:ok, _proof} -> fun.(company)
          {:error, :not_found} -> {:error, :company_not_found}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  defp record_action(scope, company_id, event, payload),
    do: Documents.record_action!(scope, company_id, event, payload)

  defp found(nil), do: {:error, :document_not_found}
  defp found(fetched), do: {:ok, Documents.document_view(fetched)}

  ## Issuing

  defp environment(scope, company_id), do: Configuration.environment(scope, company_id)

  defp authority, do: Configuration.authority()

  # Every list once per issue, so each rule reads the same snapshot.
  defp code_lookup(scope, company_id) do
    codes = CodeLists.all_codes(scope, company_id, authority().id())
    &Map.fetch!(codes, &1)
  end

  defp validate_with_authority(%{valid?: false} = changeset, _context), do: changeset
  defp validate_with_authority(changeset, context), do: authority().validate(changeset, context)

  defp unused_code_number(scope, company_id, environment, draft) do
    taken? =
      scope
      |> Documents.documents_query(company_id)
      |> where([d], d.environment == ^environment and d.code_number == ^draft.code_number)
      |> Repo.exists?()

    if taken?, do: {:error, :code_number_taken}, else: :ok
  end

  @owner_module ~r"\A[a-z][a-z0-9_]*/[a-z][a-z0-9_]*\z"
  @owner_record ~r"\A[a-z][a-z0-9_]*:[1-9][0-9]*\z"

  # The source a caller names is held to the ledger: the entry exists, that
  # module and record own it, it stands unreversed, and it recognises what
  # the document bills, in the document's currency; and no other standing
  # document links the source. A problem is a `source` error on the draft.
  defp source_link(scope, company_id, changeset, draft, original, attributes) do
    case attribute(attributes, :source) do
      nil ->
        unlinked(changeset, original)

      source when is_map(source) ->
        module = attribute(source, :module)
        record = attribute(source, :record)
        entry_id = attribute(source, :ledger_entry_id)

        with :ok <- source_shape(module, record, entry_id),
             {:ok, entry} <- source_entry(scope, company_id, entry_id),
             :ok <- source_fits(entry, module, record, draft),
             :ok <- source_free(scope, company_id, module, record) do
          {:ok, %{module: module, record: record, ledger_entry_id: entry_id}}
        else
          {:error, message} -> {:error, Changeset.add_error(changeset, :source, message)}
        end

      _other ->
        {:error,
         Changeset.add_error(changeset, :source, "names a module, a record, and a ledger entry")}
    end
  end

  # A note whose original is linked corrects a transaction another module
  # recognised: it names the record that module corrected it with, or its
  # own correcting entry would be a second one.
  defp unlinked(changeset, %{recognised_by_source?: true}) do
    {:error,
     Changeset.add_error(
       changeset,
       :source,
       "is required: the original document is the tax document of a transaction another module recognised"
     )}
  end

  defp unlinked(_changeset, _original), do: {:ok, nil}

  defp attribute(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp source_shape(module, record, entry_id) do
    if is_binary(module) and is_binary(record) and is_integer(entry_id) and entry_id > 0 and
         entry_id <= @max_bigint and String.length(module) <= 100 and
         String.length(record) <= 100 and Regex.match?(@owner_module, module) and
         Regex.match?(@owner_record, record),
       do: :ok,
       else: {:error, "names a module, a record, and a ledger entry"}
  end

  defp source_entry(scope, company_id, entry_id) do
    case Ledger.get_entry(scope, company_id, entry_id) do
      {:ok, entry} ->
        {:ok, entry}

      {:error, :entry_not_found} ->
        {:error, "names ledger entry #{entry_id}, which does not exist"}

      {:error, reason} ->
        {:error, "cannot read ledger entry #{entry_id}: #{inspect(reason)}"}
    end
  end

  defp source_fits(entry, module, record, draft) do
    recognised = Enum.reduce(entry.lines, Decimal.new(0), &Decimal.add(&1.debit, &2))
    billed = Decimal.add(draft.line_extension_amount, draft.tax_amount)

    cond do
      entry.owner != %{module: module, record: record} ->
        {:error, "ledger entry #{entry.id} is not owned by #{module} #{record}"}

      entry.reverses_entry_id ->
        {:error, "ledger entry #{entry.id} is a reversal"}

      entry.reversed_by_entry_id ->
        {:error, "ledger entry #{entry.id} was reversed by entry #{entry.reversed_by_entry_id}"}

      entry.currency_code != draft.currency_code ->
        {:error,
         "ledger entry #{entry.id} is in #{entry.currency_code}, the document in #{draft.currency_code}"}

      not Decimal.equal?(recognised, billed) ->
        {:error,
         "ledger entry #{entry.id} recognises #{money(recognised)}, " <>
           "not the document's #{money(billed)}"}

      true ->
        :ok
    end
  end

  defp money(amount), do: amount |> Decimal.round(2) |> Decimal.to_string(:normal)

  defp source_free(scope, company_id, module, record) do
    case Documents.standing_source_document(scope, company_id, module, record) do
      nil -> :ok
      document_id -> {:error, "is already the source of document #{document_id}, which stands"}
    end
  end

  defp insert_lines(document, lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.each(fn {line, number} ->
      Repo.insert!(%Line{
        tenant_id: document.tenant_id,
        company_id: document.company_id,
        document_id: document.id,
        line_number: number,
        description: line.description,
        classification_code: line.classification_code,
        tariff_code: line.tariff_code,
        origin_country_code: line.origin_country_code,
        quantity: line.quantity,
        unit_code: line.unit_code,
        unit_price: line.unit_price,
        subtotal: line.subtotal,
        discount_amount: line.discount_amount,
        charge_amount: line.charge_amount,
        line_extension_amount: line.line_extension_amount,
        tax_type: line.tax_type,
        tax_rate: line.tax_rate,
        tax_amount: line.tax_amount,
        tax_exemption_reason: line.tax_exemption_reason
      })
    end)
  end

  defp supplier_snapshot(supplier) do
    %{
      "name" => supplier.name,
      "tax_id" => supplier.tax_id,
      "registration_type" => supplier.registration_type,
      "registration_number" => supplier.registration_number,
      "sales_tax_registration" => supplier.sales_tax_registration,
      "tourism_tax_registration" => supplier.tourism_tax_registration,
      "industry_code" => supplier.industry_code,
      "business_activity" => supplier.business_activity,
      "phone" => supplier.phone,
      "email" => supplier.email,
      "address" => %{
        "lines" =>
          Enum.reject(
            [supplier.address_line1, supplier.address_line2, supplier.address_line3],
            &is_nil/1
          ),
        "city" => supplier.city,
        "postcode" => supplier.postcode,
        "state_code" => supplier.state_code,
        "country_code" => supplier.country_code
      }
    }
  end

  # A self-billed document's supplier carries a supplier's fields too.
  defp supplier_party_snapshot(party) do
    party
    |> party_snapshot()
    |> Map.merge(%{
      "industry_code" => party.industry_code,
      "business_activity" => party.business_activity,
      "tourism_tax_registration" => nil
    })
  end

  defp party_snapshot(party) do
    %{
      "name" => party.name,
      "tax_id" => party.tax_id,
      "registration_type" => party.registration_type,
      "registration_number" => party.registration_number,
      "sales_tax_registration" => party.sales_tax_registration,
      "email" => party.email,
      "phone" => party.phone,
      "address" => %{
        "lines" => party.address.lines,
        "city" => party.address.city,
        "postcode" => party.address.postcode,
        "state_code" => party.address.state_code,
        "country_code" => party.address.country_code
      }
    }
  end

  # A note snapshots the original's code number and UUID: what the payload
  # references, as it stood when the note was issued.
  defp details(draft, original) do
    %{
      "payment_means_code" => draft.payment_means_code,
      "payment_terms" => draft.payment_terms,
      "billing_period_start" =>
        draft.billing_period_start && Date.to_iso8601(draft.billing_period_start),
      "billing_period_end" =>
        draft.billing_period_end && Date.to_iso8601(draft.billing_period_end),
      "billing_period_description" => draft.billing_period_description,
      "original_code_number" => original && original.code_number,
      "original_document_uuid" => original && original.document_uuid
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  ## Setup

  defp certificate_summary(%{certificate_pem: nil}, _now), do: nil

  defp certificate_summary(credentials, now) do
    case Certificate.parse(credentials.certificate_pem) do
      {:ok, certificate} ->
        key_matches? =
          case Certificate.private_key(credentials.private_key_pem) do
            {:ok, key} -> Certificate.key_matches?(certificate, key)
            {:error, _} -> false
          end

        identity = authority().certificate_identity(certificate.subject)

        %{
          issuer_name: certificate.issuer_name,
          subject_name: certificate.subject_name,
          serial_number: certificate.serial_number,
          tax_id: identity.tax_id,
          registration_number: identity.registration_number,
          not_before: certificate.not_before,
          not_after: certificate.not_after,
          days_until_expiry: Certificate.days_until_expiry(certificate, now),
          private_key_matches?: key_matches?
        }

      {:error, :invalid_certificate} ->
        %{invalid?: true}
    end
  end
end
