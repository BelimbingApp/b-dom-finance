defmodule Bilimbi.Finance.Attachments.ArtifactOwner do
  @moduledoc """
  The module's adapter for Base Artifacts: who may store, read, delete, and
  retain a source document's bytes.

  Every operation re-asks the capability the facade asks for the same
  action, for the company, and that the company is live; a system scope is
  refused, but for the one exception below. Storing (`:create`) and retaining at capture (`:retain`) need
  `finance.attachments.create`; a later retention change needs
  `finance.attachments.retention.manage`, which also satisfies `:retain`;
  reading needs `finance.attachments.view`; deleting and purging need
  `finance.attachments.delete`, though a records-grade document is never
  deleted before its retain-until, and nothing here purges one.

  The one exception is the named system principal
  `finance.attachments.retention_refresh`, which `:retain` also accepts: the
  lengthening that follows a record's finalisation
  (`Bilimbi.Finance.Attachments.refresh_retention/4`) is a consequence of the
  owning module's own authorized write, so it runs as a Base Queue job
  (`Bilimbi.Finance.Attachments.RetentionRefreshWorker`, enqueued as that
  principal) and the person who finalised the record need hold no attachments
  grant.
  """

  @behaviour Bilimbi.Base.Artifacts.Owner

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company

  @view "finance.attachments.view"
  @create "finance.attachments.create"
  @delete "finance.attachments.delete"
  @manage_retention "finance.attachments.retention.manage"
  @refresh_principal "finance.attachments.retention_refresh"
  @kind "source-document"

  @impl Bilimbi.Base.Artifacts.Owner
  def artifact_owner_id, do: "finance/attachments"

  @doc "The system principal the finalisation refresh of a record's retention runs as."
  def refresh_principal, do: @refresh_principal

  @doc "The artifact reference of a source's documents."
  def reference(source_id) when is_binary(source_id), do: %{subject: source_id, kind: @kind}

  @impl Bilimbi.Base.Artifacts.Owner
  def authorize(%Scope{} = scope, company_id, operation, reference)
      when operation in [:create, :read, :delete, :retain, :purge] do
    with true <- operation == :purge or match?(%{kind: @kind}, reference),
         true <- Company.live_company?(scope, company_id),
         true <- permitted?(scope, company_id, operation) do
      :ok
    else
      _refused -> {:error, :forbidden}
    end
  end

  defp permitted?(scope, company_id, operation) do
    (operation == :retain and refresh_principal?(scope)) or
      Enum.any?(capabilities(operation), &granted?(scope, company_id, &1))
  end

  defp refresh_principal?(scope), do: Scope.actor(scope).system_principal == @refresh_principal

  defp capabilities(:create), do: [@create]
  defp capabilities(:read), do: [@view]
  defp capabilities(:retain), do: [@create, @manage_retention]
  defp capabilities(operation) when operation in [:delete, :purge], do: [@delete]

  defp granted?(scope, company_id, capability),
    do: match?({:ok, _company}, Company.authorize_company_target(scope, company_id, capability))
end
