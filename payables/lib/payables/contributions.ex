defmodule Bilimbi.Finance.Payables.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  # The "finance" domain and the "post" verb are finance/ledger's.
  @view "finance.payables.view"
  @manage_settings "finance.payables.settings.manage"
  @create_documents "finance.payables.documents.create"
  @approve_documents "finance.payables.documents.approve"
  @post_documents "finance.payables.documents.post"
  @post_payments "finance.payables.payments.post"

  @capabilities [
    @view,
    @manage_settings,
    @create_documents,
    @approve_documents,
    @post_documents,
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
