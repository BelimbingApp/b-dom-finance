defmodule Bilimbi.Finance.Einvoice.Clearance do
  @moduledoc """
  Clearing a recorded document with the authority: submitting it, polling
  until it is validated or refused, refreshing its status, and cancelling
  it. Every outcome is a new status event with the authority's answer
  beside it, and every outcome the authority decides is also an audit
  action; nothing here edits a document.

  The facade authorizes each call and the workers run as the user who
  asked (`Bilimbi.Base.Queue.enqueue_for/3`), so a recorded event, an
  audit action, and a ledger entry all name that person.

  ## Submitting

  A submission row holding the exact bytes is committed before the HTTP
  call, so an attempt that dies mid-flight still leaves what it sent. The
  authority's answer is then recorded: `submitted` (accepted, with the
  submission UID and document UUID; the poll job is queued), `refused`
  (the authority explained why), `duplicate` (the same bytes were
  submitted inside the authority's window, so an earlier attempt reached
  it), `rate_limited` (the job retries after the queue's backoff), or
  `unavailable` (an outage or transport failure: the job retries, and
  when the outage has lasted #{72} hours an `overdue` event and the audit
  action `finance.einvoice.submission.overdue` give the operator notice).
  A document whose status is already `submitted`, `valid`, or `cancelled`
  is never submitted again, whatever the job says.

  A duplicate, or an outage that may have hidden an accepted request,
  never resubmits blindly: the authority is asked for the document by its
  code number (`Authority.find_submission/4`). When it holds one, its
  submission UID and document UUID are recorded as `submitted` with the
  authority's own entry, and the poll job is queued. Only when nothing is
  found is the `duplicate` recorded and the job stopped for an operator,
  or the outage retried.

  ## Polling

  The poll job reads the submission's progress every few seconds, a
  bounded number of times per job, and retries later while the authority
  is still processing. Once done it reads the document's status and
  records `valid` (with the long ID that completes the validation link)
  or `invalid` (with the validation results), then posts the ledger entry
  for a valid document (`Bilimbi.Finance.Einvoice.Posting`). A posting that
  fails stays on the reconciliation page until `retry_posting/3`; a status
  read never posts again.

  ## Refreshing and cancelling

  A refresh reads the document's status and records what changed: a
  buyer's rejection request becomes `rejected`, a cancellation made on
  the portal becomes `cancelled`, and an unchanged status is kept as
  `status_checked`. A cancellation is guarded before the authority is
  asked: only a valid (or rejected) document, inside its 72-hour window,
  with no active note referencing it; the authority's own refusal is
  recorded as `cancellation_refused`.

  ## Ledger follow-up

  `retry_posting/3` and `retry_reversal/4` post or reverse the entry of a
  document the reconciliation page lists, once the cause (the book, the
  accounts, a grant) is fixed. Each is idempotent and records an audit
  action; the facade asks for the ledger grant before calling them.
  """

  import Ecto.Query

  alias Bilimbi.Base.Queue
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Einvoice.{Certificate, Configuration, Document, Documents, Posting}
  alias Bilimbi.Finance.Einvoice.{PollWorker, Submission}

  @submittable ["issued", "refused", "invalid"]
  @cancellable ["valid", "rejected"]
  # Notes in these statuses still reference their original at the authority.
  @active_note_statuses ["submitted", "valid", "rejected"]
  @outage_hours 72
  @max_reads_per_job 10

  @type job_result :: :ok | {:retry, atom()} | {:cancel, atom()}

  ## Preparing a submission

  @doc "Whether a document in this status may be submitted."
  def submittable?(status), do: status in @submittable

  @doc """
  What a submission needs, checked before a job is queued and again when
  it runs: the company's credentials for the document's environment, the
  format version, and the signing key a signed version needs.
  """
  @spec prepare(Scope.t(), pos_integer(), map()) ::
          {:ok, map()}
          | {:error, :not_submittable | :missing_credentials | :signing_key_required}
  def prepare(%Scope{} = scope, company_id, document) do
    credentials = Configuration.credentials(scope, company_id, document.environment)
    version = Configuration.document_version(scope, company_id)
    signed? = Enum.any?(authority().document_versions(), &(&1.version == version and &1.signed))

    cond do
      not submittable?(document.status) ->
        {:error, :not_submittable}

      is_nil(credentials.client_id) or is_nil(credentials.client_secret) ->
        {:error, :missing_credentials}

      signed? ->
        case signing_key(credentials) do
          {:ok, key} -> {:ok, %{credentials: credentials, version: version, signing_key: key}}
          :error -> {:error, :signing_key_required}
        end

      true ->
        {:ok, %{credentials: credentials, version: version, signing_key: nil}}
    end
  end

  defp signing_key(%{certificate_pem: pem, private_key_pem: key_pem})
       when is_binary(pem) and is_binary(key_pem) do
    with {:ok, certificate} <- Certificate.parse(pem),
         {:ok, key} <- Certificate.private_key(key_pem),
         true <- Certificate.key_matches?(certificate, key) do
      {:ok, %{certificate: certificate, key: key}}
    else
      _other -> :error
    end
  end

  defp signing_key(_credentials), do: :error

  ## Submitting

  @doc "Runs one submission attempt for the document, as the poll and submit jobs do."
  @spec submit(Scope.t(), pos_integer(), pos_integer(), DateTime.t()) :: job_result()
  def submit(%Scope{} = scope, company_id, document_id, %DateTime{} = now) do
    case Documents.ensure_writable(scope, company_id) do
      :ok -> submit_writable(scope, company_id, document_id, now)
      {:error, reason} -> {:cancel, reason}
    end
  end

  defp submit_writable(scope, company_id, document_id, now) do
    case Documents.fetch(scope, company_id, document_id) do
      nil ->
        {:cancel, :document_not_found}

      fetched ->
        document = Documents.document_view(fetched)

        if submittable?(document.status),
          do: submit_document(scope, company_id, document, now),
          else: :ok
    end
  end

  defp submit_document(scope, company_id, document, now) do
    case prepare(scope, company_id, document) do
      {:error, reason} ->
        record(scope, company_id, document.id, %{
          event: "unsendable",
          reason: "cannot submit: #{reason}"
        })

        {:cancel, reason}

      {:ok, %{credentials: credentials, version: version, signing_key: key}} ->
        case authority().payload(document, %{version: version, signing_key: key}, now) do
          {:ok, payload} ->
            submission = store_submission!(scope, company_id, document, payload)

            outcome =
              authority().submit(scope, company_id, credentials, %{
                format: payload.format,
                bytes: payload.bytes,
                code_number: document.code_number
              })

            record_submission_outcome(
              scope,
              company_id,
              document,
              submission,
              outcome,
              credentials,
              now
            )

          {:error, reason} ->
            record(scope, company_id, document.id, %{
              event: "unsendable",
              reason: "cannot build the payload: #{reason}"
            })

            {:cancel, reason}
        end
    end
  end

  # The bytes are committed before the authority sees them.
  defp store_submission!(scope, company_id, document, payload) do
    actor = actor_columns(scope)

    write!(scope, company_id, fn ->
      Repo.insert!(
        struct!(
          Submission,
          Map.merge(actor, %{
            tenant_id: Scope.tenant_id(scope),
            company_id: company_id,
            document_id: document.id,
            environment: document.environment,
            format: payload.format,
            document_version: payload.version,
            payload: payload.bytes,
            payload_sha256: :sha256 |> :crypto.hash(payload.bytes) |> Base.encode16(case: :lower)
          })
        )
      )
    end)
  end

  defp record_submission_outcome(
         scope,
         company_id,
         document,
         submission,
         outcome,
         credentials,
         now
       ) do
    outcome = recover_outcome(scope, company_id, credentials, document, outcome, now)

    base = %{
      "document_id" => document.id,
      "code_number" => document.code_number,
      "environment" => document.environment,
      "submission_id" => submission.id
    }

    write!(scope, company_id, fn ->
      case outcome do
        {:accepted, answer} ->
          record(scope, company_id, document.id, %{
            event: "submitted",
            submission_id: submission.id,
            authority_status: "Submitted",
            submission_uid: answer.submission_uid,
            document_uuid: answer.document_uuid,
            reason: answer[:reason],
            http_status: answer.http_status,
            response: answer.response
          })

          action(scope, company_id, "finance.einvoice.submitted", base, answer)

          {:ok, _job} =
            Queue.enqueue_for(scope, PollWorker, %{
              "company_id" => company_id,
              "document_id" => document.id
            })

          :ok

        {kind, answer} when kind in [:rejected, :refused] ->
          record(scope, company_id, document.id, %{
            event: "refused",
            submission_id: submission.id,
            submission_uid: answer[:submission_uid],
            reason: answer[:reason],
            http_status: answer[:http_status],
            response: answer[:response]
          })

          action(scope, company_id, "finance.einvoice.refused", base, answer)
          :ok

        {:duplicate, answer} ->
          record(scope, company_id, document.id, %{
            event: "duplicate",
            submission_id: submission.id,
            reason:
              "the authority holds an identical submission; read its status before resubmitting",
            http_status: answer[:http_status],
            response: answer[:response]
          })

          action(scope, company_id, "finance.einvoice.submission.duplicate", base, answer)
          {:cancel, :duplicate_submission}

        {:rate_limited, answer} ->
          record(scope, company_id, document.id, %{
            event: "rate_limited",
            submission_id: submission.id,
            reason: retry_after_reason(answer),
            http_status: answer[:http_status],
            response: answer[:response]
          })

          {:retry, :rate_limited}

        {:unavailable, answer} ->
          record(scope, company_id, document.id, %{
            event: "unavailable",
            submission_id: submission.id,
            reason: answer[:reason],
            http_status: answer[:http_status],
            response: answer[:response]
          })

          notice_if_overdue(scope, company_id, document, now)
          {:retry, :authority_unavailable}
      end
    end)
  end

  # A duplicate, or an outage that may have hidden an accepted request,
  # means the authority may hold the document already: ask for it by its
  # code number, among what was submitted since the document last became
  # submittable, instead of sending the bytes again. A lookup that finds
  # nothing leaves the outcome as it was; one that cannot answer retries.
  defp recover_outcome(scope, company_id, credentials, document, {kind, _answer} = outcome, now)
       when kind in [:duplicate, :unavailable] do
    since =
      document.events
      |> Enum.filter(&(&1.event in Documents.status_events()))
      |> List.last()
      |> Map.fetch!(:recorded_at)

    lookup = %{code_number: document.code_number, since: since, until: now}

    case authority().find_submission(scope, company_id, credentials, lookup) do
      {:found, found} -> {:accepted, found}
      {status, answer} when status in [:rate_limited, :unavailable] -> {status, answer}
      {_not_found_or_refused, _answer} -> outcome
    end
  end

  defp recover_outcome(_scope, _company_id, _credentials, _document, outcome, _now), do: outcome

  # Once the authority has been unreachable for 72 hours since this
  # document's first failed attempt, the operator is told once, through an
  # event the page shows and an audit action; the job keeps retrying.
  defp notice_if_overdue(scope, company_id, document, now) do
    events = Documents.events(scope, company_id, document.id)

    since_status =
      events
      |> Enum.reverse()
      |> Enum.take_while(&(&1.event not in Documents.status_events()))
      |> Enum.reverse()

    first = Enum.find(since_status, &(&1.event == "unavailable"))
    noticed? = Enum.any?(since_status, &(&1.event == "overdue"))

    if first && not noticed? &&
         DateTime.diff(now, first.recorded_at, :second) >= @outage_hours * 3600 do
      record(scope, company_id, document.id, %{
        event: "overdue",
        reason:
          "not submitted within #{@outage_hours} hours of the authority becoming unavailable"
      })

      Documents.record_action!(scope, company_id, "finance.einvoice.submission.overdue", %{
        "document_id" => document.id,
        "code_number" => document.code_number,
        "environment" => document.environment,
        "unavailable_since" => DateTime.to_iso8601(first.recorded_at)
      })
    end

    :ok
  end

  ## Polling

  @doc "Reads a submitted document's progress until the authority decides, within one job's bounds."
  @spec poll(Scope.t(), pos_integer(), pos_integer(), DateTime.t()) :: job_result()
  def poll(%Scope{} = scope, company_id, document_id, %DateTime{} = now) do
    case Documents.ensure_writable(scope, company_id) do
      :ok -> poll_writable(scope, company_id, document_id, now)
      {:error, reason} -> {:cancel, reason}
    end
  end

  defp poll_writable(scope, company_id, document_id, now) do
    case Documents.fetch(scope, company_id, document_id) do
      nil ->
        {:cancel, :document_not_found}

      fetched ->
        document = Documents.document_view(fetched)

        if document.status == "submitted" and is_binary(document.submission_uid),
          do: poll_submission(scope, company_id, document, now, @max_reads_per_job),
          else: :ok
    end
  end

  defp poll_submission(scope, company_id, document, now, reads_left) do
    credentials = Configuration.credentials(scope, company_id, document.environment)

    case authority().submission_progress(scope, company_id, credentials, document.submission_uid) do
      {:in_progress, _answer} when reads_left > 1 ->
        Process.sleep(poll_interval_ms())
        poll_submission(scope, company_id, document, now, reads_left - 1)

      {:in_progress, _answer} ->
        {:retry, :in_progress}

      {:done, _answer} ->
        case read_status(scope, company_id, document, credentials, now) do
          {:ok, "submitted"} -> {:retry, :in_progress}
          {:ok, _status} -> :ok
          {:error, code} -> code
        end

      {:rate_limited, _answer} ->
        {:retry, :rate_limited}

      {:unavailable, _answer} ->
        {:retry, :authority_unavailable}

      {:refused, answer} ->
        record(scope, company_id, document.id, %{
          event: "status_unreadable",
          reason: answer[:reason],
          http_status: answer[:http_status],
          response: answer[:response]
        })

        {:cancel, :status_unreadable}
    end
  end

  ## Refreshing

  @doc "Reads the document's status at the authority and records what changed."
  @spec refresh(Scope.t(), pos_integer(), pos_integer(), DateTime.t()) ::
          {:ok, map()}
          | {:error,
             :document_not_found
             | :not_submitted
             | :company_archived
             | :company_not_found
             | {:authority, term()}}
  def refresh(%Scope{} = scope, company_id, document_id, %DateTime{} = now) do
    case Documents.ensure_writable(scope, company_id) do
      :ok -> refresh_writable(scope, company_id, document_id, now)
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_writable(scope, company_id, document_id, now) do
    case Documents.fetch(scope, company_id, document_id) do
      nil ->
        {:error, :document_not_found}

      fetched ->
        document = Documents.document_view(fetched)

        if is_binary(document.document_uuid) do
          credentials = Configuration.credentials(scope, company_id, document.environment)

          case read_status(scope, company_id, document, credentials, now) do
            {:ok, _status} ->
              {:ok, Documents.document_view(Documents.fetch(scope, company_id, document_id))}

            {:error, {:retry, reason}} ->
              {:error, {:authority, reason}}

            {:error, {:cancel, reason}} ->
              {:error, {:authority, reason}}
          end
        else
          {:error, :not_submitted}
        end
    end
  end

  # The authority's current view of the document, recorded as the event it
  # implies. Returns the status the document now has. A 404 right after a
  # submission is the authority not having indexed the document yet (the
  # sandbox answers "not authorized to get document details" for a few
  # seconds), so it is retried rather than recorded as unreadable.
  defp read_status(scope, company_id, document, credentials, now) do
    case authority().document_status(scope, company_id, credentials, document.document_uuid) do
      {:ok, answer} ->
        {status, follow_up} =
          write!(scope, company_id, fn ->
            current = Documents.document_view(Documents.fetch(scope, company_id, document.id))
            apply_status(scope, company_id, current, answer)
          end)

        settle(scope, company_id, document.id, follow_up, now)
        {:ok, status}

      {:rate_limited, _answer} ->
        {:error, {:retry, :rate_limited}}

      {:unavailable, _answer} ->
        {:error, {:retry, :authority_unavailable}}

      {:refused, %{http_status: 404}} ->
        {:error, {:retry, :not_yet_available}}

      {:refused, answer} ->
        record(scope, company_id, document.id, %{
          event: "status_unreadable",
          reason: answer[:reason],
          http_status: answer[:http_status],
          response: answer[:response]
        })

        {:error, {:cancel, :status_unreadable}}
    end
  end

  # Records the status event and returns the status with the ledger work it
  # leaves for after the transaction commits: `:post`, `:reverse`, or `nil`.
  defp apply_status(scope, company_id, document, answer) do
    base = %{
      "document_id" => document.id,
      "code_number" => document.code_number,
      "environment" => document.environment,
      "document_uuid" => document.document_uuid
    }

    common = %{
      document_uuid: document.document_uuid,
      long_id: answer[:long_id],
      http_status: answer[:http_status],
      response: answer[:response]
    }

    rejected? = not is_nil(answer[:rejection_requested_at])

    cond do
      answer.status == :valid and rejected? and document.status not in ["rejected", "cancelled"] ->
        record_valid_if_new(scope, company_id, document, answer, common, base)

        record(
          scope,
          company_id,
          document.id,
          Map.merge(common, %{
            event: "rejected",
            authority_status: "Valid",
            reason: answer[:reason] || "the buyer requested rejection"
          })
        )

        action(scope, company_id, "finance.einvoice.rejected", base, answer)
        {"rejected", if(document.status == "valid", do: nil, else: :post)}

      answer.status == :valid and document.status not in ["valid", "rejected", "cancelled"] ->
        record_valid_if_new(scope, company_id, document, answer, common, base)
        {"valid", :post}

      answer.status == :invalid and document.status != "invalid" ->
        record(
          scope,
          company_id,
          document.id,
          Map.merge(common, %{
            event: "invalid",
            authority_status: "Invalid",
            reason: invalid_reason(answer)
          })
        )

        action(scope, company_id, "finance.einvoice.invalid", base, answer)
        {"invalid", nil}

      answer.status == :cancelled and document.status != "cancelled" ->
        record(
          scope,
          company_id,
          document.id,
          Map.merge(common, %{
            event: "cancelled",
            authority_status: "Cancelled",
            reason: answer[:reason]
          })
        )

        action(scope, company_id, "finance.einvoice.cancelled", base, answer)
        {"cancelled", :reverse}

      answer.status == :submitted ->
        {"submitted", nil}

      true ->
        record(
          scope,
          company_id,
          document.id,
          Map.merge(common, %{
            event: "status_checked",
            authority_status: authority_status(answer.status),
            reason: answer[:reason]
          })
        )

        {document.status, nil}
    end
  end

  defp record_valid_if_new(scope, company_id, document, answer, common, base) do
    unless document.status in ["valid", "rejected", "cancelled"] do
      record(
        scope,
        company_id,
        document.id,
        Map.merge(common, %{event: "valid", authority_status: "Valid"})
      )

      action(scope, company_id, "finance.einvoice.validated", base, answer)
    end

    :ok
  end

  # The ledger work a status change leaves, run once the status is
  # committed and outside any transaction of ours: the ledger rolls back
  # its own on a refusal, which would take ours with it.
  defp settle(scope, company_id, document_id, :post, _now) do
    Posting.post(scope, company_id, fresh_view(scope, company_id, document_id))
    :ok
  end

  defp settle(scope, company_id, document_id, :reverse, now) do
    Posting.reverse(scope, company_id, fresh_view(scope, company_id, document_id), now)
    :ok
  end

  defp settle(_scope, _company_id, _document_id, nil, _now), do: :ok

  defp fresh_view(scope, company_id, document_id),
    do: Documents.document_view(Documents.fetch(scope, company_id, document_id))

  ## Ledger follow-up

  @type retry_result ::
          {:ok, map()}
          | {:error,
             :document_not_found
             | :company_archived
             | :company_not_found
             | :not_postable
             | :not_reversible}
          | {:error, {:failed, String.t()}}

  @doc """
  Posts the entry of a validated document whose posting failed or was
  never attempted. A document that already has its entry is returned
  unchanged. A posting that fails again is recorded by `Posting` and is
  `{:error, {:failed, reason}}`; either way an audit action names the try.
  """
  @spec retry_posting(Scope.t(), pos_integer(), term()) :: retry_result()
  def retry_posting(%Scope{} = scope, company_id, document_id) do
    retry(
      scope,
      company_id,
      document_id,
      "posting",
      fn document ->
        cond do
          not is_nil(document.ledger_entry_id) -> :noop
          document.status in Documents.valid_statuses() -> :run
          true -> {:error, :not_postable}
        end
      end,
      &Posting.post(scope, company_id, &1)
    )
  end

  @doc """
  Reverses the entry of a cancelled document whose reversal failed or was
  never attempted. A document without an entry, or already reversed, is
  returned unchanged.
  """
  @spec retry_reversal(Scope.t(), pos_integer(), term(), DateTime.t()) :: retry_result()
  def retry_reversal(%Scope{} = scope, company_id, document_id, %DateTime{} = now) do
    retry(
      scope,
      company_id,
      document_id,
      "reversal",
      fn document ->
        cond do
          is_nil(document.ledger_entry_id) -> :noop
          not is_nil(document.reversal_entry_id) -> :noop
          document.status == "cancelled" -> :run
          true -> {:error, :not_reversible}
        end
      end,
      &Posting.reverse(scope, company_id, &1, now)
    )
  end

  # The ledger call runs outside any transaction of ours. A failed try
  # still records its event and the audit action.
  defp retry(scope, company_id, document_id, operation, decide, run) do
    with :ok <- Documents.ensure_writable(scope, company_id) do
      case Documents.fetch(scope, company_id, document_id) do
        nil ->
          {:error, :document_not_found}

        fetched ->
          document = Documents.document_view(fetched)

          case decide.(document) do
            :noop -> {:ok, document}
            {:error, reason} -> {:error, reason}
            :run -> retried(scope, company_id, document, operation, run.(document))
          end
      end
    end
  end

  defp retried(scope, company_id, document, operation, result) do
    {outcome, reason} =
      case result do
        {:ok, _entry} -> {"succeeded", nil}
        {:error, message} -> {"failed", message}
        :noop -> {"unchanged", nil}
      end

    payload =
      Map.reject(
        %{
          "document_id" => document.id,
          "code_number" => document.code_number,
          "environment" => document.environment,
          "operation" => operation,
          "outcome" => outcome,
          "reason" => reason
        },
        fn {_key, value} -> is_nil(value) end
      )

    write!(scope, company_id, fn ->
      Documents.record_action!(scope, company_id, "finance.einvoice.posting.retried", payload)
    end)

    case result do
      {:error, message} ->
        {:error, {:failed, message}}

      _done ->
        {:ok, Documents.document_view(Documents.fetch(scope, company_id, document.id))}
    end
  end

  ## Cancelling

  @doc """
  Cancels a validated document with `reason`, after the local guards and
  the authority both agree. Records `cancelled` and reverses its posting,
  or `cancellation_refused` with the authority's reason.
  """
  @spec cancel(Scope.t(), pos_integer(), pos_integer(), String.t(), DateTime.t()) ::
          {:ok, map()}
          | {:error,
             :document_not_found
             | :company_archived
             | :company_not_found
             | :not_cancellable
             | :cancellation_period_over
             | :active_referencing_documents
             | :invalid_reason
             | {:refused, atom(), String.t() | nil}
             | :authority_unavailable
             | :rate_limited}
  def cancel(%Scope{} = scope, company_id, document_id, reason, %DateTime{} = now) do
    with {:ok, document} <- cancellable_document(scope, company_id, document_id, now),
         :ok <- valid_reason(reason),
         :ok <- Documents.ensure_writable(scope, company_id) do
      credentials = Configuration.credentials(scope, company_id, document.environment)

      base = %{
        "document_id" => document.id,
        "code_number" => document.code_number,
        "environment" => document.environment,
        "document_uuid" => document.document_uuid
      }

      case authority().cancel(scope, company_id, credentials, document.document_uuid, reason) do
        {:ok, answer} ->
          recorded? =
            while_cancellable(scope, company_id, document.id, fn ->
              record(scope, company_id, document.id, %{
                event: "cancelled",
                authority_status: "Cancelled",
                document_uuid: document.document_uuid,
                reason: reason,
                http_status: answer[:http_status],
                response: answer[:response]
              })

              action(scope, company_id, "finance.einvoice.cancelled", base, answer)
            end)

          if recorded?, do: settle(scope, company_id, document.id, :reverse, now)

          {:ok, Documents.document_view(Documents.fetch(scope, company_id, document_id))}

        {:refused, answer} ->
          while_cancellable(scope, company_id, document.id, fn ->
            record(scope, company_id, document.id, %{
              event: "cancellation_refused",
              document_uuid: document.document_uuid,
              reason: answer[:reason] || to_string(answer[:reason_code]),
              http_status: answer[:http_status],
              response: answer[:response]
            })

            action(scope, company_id, "finance.einvoice.cancellation.refused", base, answer)
          end)

          {:error, {:refused, answer[:reason_code], answer[:reason]}}

        {:rate_limited, _answer} ->
          {:error, :rate_limited}

        {:unavailable, _answer} ->
          {:error, :authority_unavailable}
      end
    end
  end

  # Records only if the document, read again under the company lock, is
  # still one the supplier may cancel: a refresh or the portal may have
  # moved it while the authority was asked.
  defp while_cancellable(scope, company_id, document_id, record_fun) do
    write!(scope, company_id, fn ->
      if fresh_view(scope, company_id, document_id).status in @cancellable do
        record_fun.()
        true
      else
        false
      end
    end)
  end

  defp cancellable_document(scope, company_id, document_id, now) do
    case Documents.fetch(scope, company_id, document_id) do
      nil ->
        {:error, :document_not_found}

      fetched ->
        document = Documents.document_view(fetched)

        cond do
          document.status not in @cancellable or is_nil(document.document_uuid) ->
            {:error, :not_cancellable}

          document.cancellable_until && DateTime.compare(now, document.cancellable_until) == :gt ->
            {:error, :cancellation_period_over}

          active_notes?(scope, company_id, document.id) ->
            {:error, :active_referencing_documents}

          true ->
            {:ok, document}
        end
    end
  end

  # A note the authority holds (submitted, valid, or under rejection) keeps
  # its original from being cancelled; the authority refuses that too.
  defp active_notes?(scope, company_id, document_id) do
    note_ids =
      from(d in Tenancy.scope_query(Document, scope),
        where: d.company_id == ^company_id and d.original_document_id == ^document_id,
        select: d.id
      )
      |> Repo.all()

    scope
    |> Documents.statuses(company_id, note_ids)
    |> Enum.any?(fn {_id, status} -> status in @active_note_statuses end)
  end

  defp valid_reason(reason) when is_binary(reason) do
    if String.trim(reason) != "" and String.length(reason) <= 300,
      do: :ok,
      else: {:error, :invalid_reason}
  end

  defp valid_reason(_reason), do: {:error, :invalid_reason}

  ## Helpers

  defp authority, do: Configuration.authority()

  # Tests set it to 0; the SDK asks for 3 to 5 seconds between reads.
  defp poll_interval_ms,
    do: Application.get_env(:bilimbi_finance_einvoice, :poll_interval_ms, 4_000)

  defp record(scope, company_id, document_id, attributes),
    do: Documents.record_event!(scope, company_id, document_id, attributes)

  defp action(scope, company_id, event, base, answer) do
    payload =
      base
      |> Map.put("http_status", answer[:http_status])
      |> Map.put("submission_uid", answer[:submission_uid])
      |> Map.put("document_uuid", answer[:document_uuid] || base["document_uuid"])
      |> Map.put("reason", answer[:reason])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Documents.record_action!(scope, company_id, event, payload)
  end

  defp retry_after_reason(%{retry_after: seconds}) when is_integer(seconds),
    do: "rate limited; retry after #{seconds} seconds"

  defp retry_after_reason(_answer), do: "rate limited"

  # The authority's validation steps, each with an error whose text and
  # code sit under `error`/`message` and `errorCode`/`code`, and whose
  # `innerError` list carries the specific rules broken; the summary keeps
  # the failed steps' codes and texts, in the first 300 characters.
  defp invalid_reason(%{response: %{"validationResults" => %{"validationSteps" => steps}}})
       when is_list(steps) do
    steps
    |> Enum.reject(&(&1["status"] in ["Valid", "valid"]))
    |> Enum.map(fn step ->
      error = step["error"] || %{}
      inner = error |> Map.get("innerError") |> List.wrap() |> Enum.map(&error_text/1)
      texts = Enum.reject([error_text(error) | inner], &(&1 in [nil, ""]))
      Enum.join([step["name"] | texts], ": ")
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("; ")
    |> String.slice(0, 300)
    |> case do
      "" -> nil
      reason -> reason
    end
  end

  defp invalid_reason(answer), do: answer[:reason]

  defp error_text(%{} = error) do
    code = error["errorCode"] || error["code"]
    text = error["error"] || error["message"]

    [code, text]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.replace(~r/\s*Please refer to \S+/, "")
  end

  defp error_text(_error), do: nil

  defp authority_status(:valid), do: "Valid"
  defp authority_status(:invalid), do: "Invalid"
  defp authority_status(:cancelled), do: "Cancelled"

  defp actor_columns(scope) do
    case Scope.actor(scope) do
      %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} ->
        %{actor_type: "user", actor_user_id: user_id, actor_impersonator_id: impersonator_id}

      %Actor{type: :system, system_principal: name} when is_binary(name) ->
        %{actor_type: "system", system_principal: name}
    end
  end

  # Every write holds the company's writable lock, as the facade does.
  defp write!(scope, company_id, fun), do: Documents.write!(scope, company_id, fun)
end
