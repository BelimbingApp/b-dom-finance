defmodule Bilimbi.Finance.Receivables.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  # The "finance" domain is the ledger's, and the platform owns these verbs.
  @view "finance.receivables.view"
  @manage_setup "finance.receivables.setup.manage"
  @manage_customers "finance.receivables.customers.manage"
  @manage_documents "finance.receivables.documents.manage"
  @issue_documents "finance.receivables.documents.issue"
  @post_payments "finance.receivables.payments.post"

  @capabilities [
    @view,
    @manage_setup,
    @manage_customers,
    @manage_documents,
    @issue_documents,
    @post_payments
  ]

  @impl true
  def contributions do
    %{
      authz: %{
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      }
    }
  end
end
