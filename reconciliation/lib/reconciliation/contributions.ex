defmodule Bilimbi.Finance.Reconciliation.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  # The "finance" domain and the "post" verb are finance/ledger's; "import"
  # and "finalise" are this module's.
  @view "finance.reconciliation.view"
  @manage_bank_accounts "finance.reconciliation.bank-accounts.manage"
  @import_statements "finance.reconciliation.statements.import"
  @manage_matches "finance.reconciliation.matches.manage"
  @manage_reconciliations "finance.reconciliation.reconciliations.manage"
  @finalise_reconciliations "finance.reconciliation.reconciliations.finalise"
  @post_statement_lines "finance.reconciliation.statement-lines.post"

  @capabilities [
    @view,
    @manage_bank_accounts,
    @import_statements,
    @manage_matches,
    @manage_reconciliations,
    @finalise_reconciliations,
    @post_statement_lines
  ]

  @impl true
  def contributions do
    %{
      authz: %{
        verbs: ["import", "finalise"],
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      },
      menu: [
        %{
          id: "finance.reconciliation",
          label: "Bank reconciliation",
          icon: "scale",
          parent: "finance",
          route: "/finance/reconciliation",
          capability: @view,
          order: 15
        }
      ]
    }
  end
end
