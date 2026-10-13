defmodule Bilimbi.Finance.Attachments.ArtifactOwner do
  @moduledoc """
  The module's adapter for Base Artifacts: who may store, read, delete, and
  retain a source document's bytes.

  Every operation re-asks the capability the facade asks for the same
  action, for the company, and that the company is live; a system scope is
  refused. Storing (`:create`) needs `finance.attachments.create`; reading
  needs `finance.attachments.view`; deleting and purging need
  `finance.attachments.delete`, though a records-grade document is never
  deleted before its retain-until, and nothing here purges one.

  `:retain` asks only for a signed-in user of a live company. Retention only
  ever lengthens, and the facade gates every discretionary extension and
  legal hold with `finance.attachments.retention.manage`; the lengthening
  that follows a record's finalisation
  (`Bilimbi.Finance.Attachments.refresh_retention/4`) is a consequence of the
  owning module's own authorized write, so the person who finalised the
  record need hold no attachments grant.
  """

  @behaviour Bilimbi.Base.Artifacts.Owner

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company

  @view "finance.attachments.view"
  @create "finance.attachments.create"
  @delete "finance.attachments.delete"
  @kind "source-document"

  @impl Bilimbi.Base.Artifacts.Owner
  def artifact_owner_id, do: "finance/attachments"

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

  defp permitted?(scope, _company_id, :retain),
    do: match?({:ok, _actor}, Authz.scope_actor(scope))

  defp permitted?(scope, company_id, operation),
    do: Enum.any?(capabilities(operation), &granted?(scope, company_id, &1))

  defp capabilities(:create), do: [@create]
  defp capabilities(:read), do: [@view]
  defp capabilities(operation) when operation in [:delete, :purge], do: [@delete]

  defp granted?(scope, company_id, capability),
    do: match?({:ok, _company}, Company.authorize_company_target(scope, company_id, capability))
end
