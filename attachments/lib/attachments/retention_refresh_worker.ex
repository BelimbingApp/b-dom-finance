defmodule Bilimbi.Finance.Attachments.RetentionRefreshWorker do
  @moduledoc """
  Extends the retention of a record's source documents once the record is
  final, as the system principal `finance.attachments.retention_refresh`.

  Queued by `Bilimbi.Finance.Attachments.refresh_retention/4` with
  `Bilimbi.Base.Queue.enqueue_as_system/4`, after the caller's own scope has
  confirmed that the record is readable and final and has computed the
  retain-until its final date gives. The arguments are the tenant, the
  company, the source module's name, the record's ID, and that retain-until:
  no file name, label, or actor. The job extends each standing attachment of
  the record that is kept for less, through Base Artifacts (which only ever
  lengthens), and records `retention_extended` as the principal. A failure
  retries under the queue's backoff; the job can be queued again.

  Finance code that must change retention without a user's grant queues this
  worker through `refresh_retention/4`; it does not call Base Artifacts or
  the authentication edge itself.
  """

  use Bilimbi.Base.Queue.Worker,
    id: "finance/attachments-retention-refresh",
    max_attempts: 10,
    system_principal: "finance.attachments.retention_refresh"

  alias Bilimbi.Base.Queue.Execution
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Attachments
  alias Bilimbi.Finance.Attachments.Source

  @keys ~w(tenant_id company_id source document_id retain_until)

  @impl true
  # An exact allowlist of identifiers and the one computed date.
  def validate_args(%{
        "tenant_id" => tenant_id,
        "company_id" => company_id,
        "source" => source,
        "document_id" => document_id,
        "retain_until" => retain_until
      } = args)
      when map_size(args) == 5 and is_integer(tenant_id) and tenant_id > 0 and
             is_integer(company_id) and company_id > 0 and is_binary(source) and
             is_integer(document_id) and document_id > 0 and is_binary(retain_until) do
    with source when not is_nil(source) <- Source.from_name(source),
         {:ok, until, 0} <- DateTime.from_iso8601(retain_until) do
      {:ok,
       Map.new(@keys, &{&1, Map.fetch!(args, &1)})
       |> Map.put("source", Atom.to_string(source))
       |> Map.put("retain_until", DateTime.to_iso8601(until))}
    else
      _invalid -> {:error, :invalid_refresh}
    end
  end

  def validate_args(_args), do: {:error, :invalid_refresh}

  @impl true
  def handle_job(args, %Execution{scope: %Scope{} = scope}) do
    {:ok, until, 0} = DateTime.from_iso8601(args["retain_until"])

    arguments = %{
      tenant_id: args["tenant_id"],
      company_id: args["company_id"],
      source: args["source"],
      document_id: args["document_id"],
      retain_until: until
    }

    case Attachments.run_retention_refresh(scope, arguments) do
      :ok -> :ok
      {:error, reason} when reason in [:company_not_found, :company_archived] -> {:cancel, reason}
      {:error, reason} when reason in [:tenant_mismatch, :source_unavailable] -> {:cancel, reason}
      {:error, _reason} -> {:retry, :retention_refresh_failed}
    end
  end

  def handle_job(_args, _execution), do: {:cancel, :actor_unavailable}
end
