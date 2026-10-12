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
  or refund note names the validated (or buyer-rejected) original it corrects. A recorded
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
      `country_code`);
    * optionally `payment_means_code`, `payment_terms`, and a billing period
      (`billing_period_start`, `billing_period_end`,
      `billing_period_description`);
    * for a credit, debit, or refund note (the authority's `02` to `04`),
      `original_document_id`: a validated document of this company, whose
      code number and UUID the note carries;
    * `lines`, each with `description`, `classification_code`, `quantity`,
      `unit_price`, `tax_type`, and `tax_rate` (always stated, `0` where the
      authority takes no tax), and optionally `unit_code`, `discount_amount`,
      `charge_amount` (blank is none), `tax_exemption_reason`, `tariff_code`,
      and `origin_country_code`.

  The supplier comes from the company's e-invoicing settings and the
  environment from its current setting. Amounts are derived, never taken:
  a line's subtotal is quantity times unit price, less its discount plus
  its charge, and its tax is that times the rate, each rounded half up to
  two places. Refusals are a changeset; `{:error, :code_number_taken}` when
  the company already issued that number in the environment.
  """
  @spec issue_document(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :code_number_taken | Changeset.t()}
  def issue_document(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @issue, fn company ->
      %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} =
        Scope.actor(scope)

      supplier = Configuration.supplier(scope, company_id, company.display_name)
      codes = code_lookup(scope, company_id)
      draft_changeset = Draft.changeset(attributes, DateTime.utc_now())
      original = original_document(scope, company_id, draft_changeset)

      changeset =
        validate_with_authority(draft_changeset, %{
          supplier: supplier,
          codes: codes,
          original: original
        })

      with {:ok, draft} <- Changeset.apply_action(changeset, :insert),
           :ok <- unused_code_number(scope, company_id, environment(scope, company_id), draft) do
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
            supplier: supplier_snapshot(supplier),
            buyer: party_snapshot(draft.buyer),
            details: details(draft, original),
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

        view = Documents.document_view(Documents.fetch(scope, company_id, document.id))

        record_action(scope, company_id, "finance.einvoice.document.issued", %{
          "document_id" => view.id,
          "document_type" => view.document_type,
          "code_number" => view.code_number,
          "environment" => view.environment,
          "original_document_id" => view.original_document_id
        })

        {:ok, view}
      end
    end)
  end

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
  `refused`, `valid`, `invalid`, `cancelled`, or `rejected`). The view also
  carries what the events say: `submission_uid`, `document_uuid`,
  `long_id`, `validated_at`, `validation_url`, `cancellable_until`,
  `ledger_entry_id`, `reversal_entry_id`, `pdf_artifact_id`, and
  `attention`, the flags an operator should look at (`:overdue`,
  `:rejection_requested`, `:unposted`, `:posting_failed`, `:unreversed`,
  `:reversal_failed`).
  """
  @spec get_document(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :document_not_found}
  def get_document(%Scope{} = scope, company_id, document_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case Documents.fetch(scope, company_id, document_id) do
        nil -> {:error, :document_not_found}
        document -> {:ok, Documents.document_view(document)}
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
  the company lacks credentials for the document's environment
  (`:missing_credentials`), or the chosen format version needs a signature
  and the certificate and key are missing or mismatched
  (`:signing_key_required`).
  """
  @spec submit_document(Scope.t(), term(), term()) ::
          {:ok, %{job_id: pos_integer()}}
          | {:error,
             write_refusal()
             | :document_not_found
             | :not_submittable
             | :missing_credentials
             | :signing_key_required
             | atom()}
  def submit_document(%Scope{} = scope, company_id, document_id) do
    write(scope, company_id, @submit, fn _company ->
      with {:ok, document} <- found(Documents.fetch(scope, company_id, document_id)),
           {:ok, _prepared} <- Clearance.prepare(scope, company_id, document),
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
  it otherwise).
  """
  @spec generate_pdf(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, write_refusal() | :document_not_found | term()}
  def generate_pdf(%Scope{} = scope, company_id, document_id) do
    with {:ok, _company} <- authorize_company(scope, company_id, @view),
         {:ok, document} <- found(Documents.fetch(scope, company_id, document_id)),
         {:ok, stored} <-
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
          response: %{"artifact_id" => stored.id, "sha256" => stored.sha256}
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
