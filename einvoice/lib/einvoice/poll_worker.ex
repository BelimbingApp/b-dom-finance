defmodule Bilimbi.Finance.Einvoice.PollWorker do
  @moduledoc """
  Reads a submitted document's progress at the authority until it is
  validated or found invalid, as the user who submitted it.

  Queued by the submit job once the authority accepted the document. Each
  run reads the submission's progress a bounded number of times, a few
  seconds apart, and retries later while the authority is still
  processing; the queue's backoff spaces those retries out. Once the
  authority has decided, the document's status is recorded and a valid
  document posts its ledger entry (`Bilimbi.Finance.Einvoice.Posting`).
  """

  use Bilimbi.Base.Queue.Worker, id: "finance/einvoice-poll", max_attempts: 20

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
    case Einvoice.run_poll(scope, company_id, document_id) do
      {:error, :unauthorized} -> {:cancel, :unauthorized}
      {:error, :company_not_found} -> {:cancel, :company_not_found}
      {:error, :company_archived} -> {:cancel, :company_archived}
      result -> result
    end
  end

  def handle_job(_args, _execution), do: {:cancel, :actor_unavailable}
end
