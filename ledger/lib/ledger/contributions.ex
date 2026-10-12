defmodule Bilimbi.Finance.Ledger.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @view "finance.ledger.view"
  @manage_accounts "finance.ledger.accounts.manage"
  @post_entries "finance.ledger.entries.post"
  @manage_periods "finance.ledger.periods.manage"
  @reopen_periods "finance.ledger.periods.reopen"
  @lock_periods "finance.ledger.periods.lock"

  @capabilities [
    @view,
    @manage_accounts,
    @post_entries,
    @manage_periods,
    @reopen_periods,
    @lock_periods
  ]

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"finance" => "Finance domain modules"},
        verbs: ["post", "reopen", "lock"],
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      }
    }
  end
end
