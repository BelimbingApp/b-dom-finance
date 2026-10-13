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
  @approve_match_exceptions "finance.payables.match.approve"

  @capabilities [
    @view,
    @manage_settings,
    @create_documents,
    @approve_documents,
    @post_documents,
    @post_payments,
    @approve_match_exceptions
  ]

  @impl true
  def contributions do
    %{
      authz: %{
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      },
      menu: [
        %{
          id: "finance.payables.bills",
          label: "Bills",
          icon: "clipboard-document-list",
          parent: "finance",
          route: "/finance/payables/bills",
          capability: @view,
          order: 5
        }
      ]
    }
  end
end
