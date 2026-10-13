defmodule Bilimbi.Finance.Reports.ArtifactOwner do
  @moduledoc false
  @behaviour Bilimbi.Base.Artifacts.Owner
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Reports

  def artifact_owner_id, do: "finance/reports"

  # An auditor can generate/download an export with read-only source grants;
  # retention maintenance requires the separate report-issuing grant.
  def authorize(%Scope{} = scope, company_id, operation, reference) do
    capability =
      if operation in [:create, :read],
        do: Reports.export_capability(),
        else: Reports.issue_capability()

    with true <- operation == :purge or valid_reference?(reference),
         {:ok, _company} <- Company.authorize_company_target(scope, company_id, capability),
         true <- Company.live_company?(scope, company_id),
         true <- operation not in [:create, :read] or sources_readable?(scope, company_id),
         do: :ok,
         else: (_ -> {:error, :forbidden})
  end

  defp valid_reference?(%{subject: subject, kind: "auditor-pack"}),
    do: match?({:ok, _}, Ecto.UUID.cast(subject))

  defp valid_reference?(_reference), do: false

  defp sources_readable?(scope, company) do
    Enum.all?(
      [
        Bilimbi.Finance.Ledger,
        Bilimbi.Finance.Receivables,
        Bilimbi.Finance.Payables,
        Bilimbi.Finance.Reconciliation,
        Bilimbi.Finance.Einvoice
      ],
      fn owner ->
        match?(
          {:ok, _},
          Company.authorize_company_target(scope, company, owner.view_capability())
        )
      end
    )
  end
end
