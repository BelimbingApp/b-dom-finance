defmodule Bilimbi.Finance.Einvoice.SubmitWorker do
  @moduledoc """
  Submits one recorded document to the authority, as the user who asked.

  Queued with `Bilimbi.Base.Queue.enqueue_for/3` by
  `Bilimbi.Finance.Einvoice.submit_document/3`, so the job's scope is that
  user's, re-proven when it runs; a job without one is cancelled. The
  arguments are identifiers only. The outcome rules are
  `Bilimbi.Finance.Einvoice.Clearance`: an accepted or refused submission
  completes the job, a rate limit or outage retries it under the queue's
  backoff (twenty attempts span several days, which covers the authority's
  outage allowance), and a duplicate stops it for an operator.
  """

  use Bilimbi.Base.Queue.Worker, id: "finance/einvoice-submit", max_attempts: 20

  alias Bilimbi.Base.Queue.Execution
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Einvoice

  @impl true
  # An exact allowlist: the two identifiers and nothing else reach Oban.
  def validate_args(%{"company_id" => company_id, "document_id" => document_id} = args)
      when map_size(args) == 2 and is_integer(company_id) and company_id > 0 and
             is_integer(document_id) and document_id > 0,
      do: {:ok, %{"company_id" => company_id, "document_id" => document_id}}

  def validate_args(_args), do: {:error, :invalid_document}

  @impl true
  def handle_job(%{"company_id" => company_id, "document_id" => document_id}, %Execution{
        scope: %Scope{} = scope
      }) do
    case Einvoice.run_submission(scope, company_id, document_id) do
      {:error, :unauthorized} -> {:cancel, :unauthorized}
      {:error, :company_not_found} -> {:cancel, :company_not_found}
      {:error, :company_archived} -> {:cancel, :company_archived}
      result -> result
    end
  end

  def handle_job(_args, _execution), do: {:cancel, :actor_unavailable}
end
