defmodule Bilimbi.Finance.Ledger.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @view "finance.ledger.view"
  @manage_accounts "finance.ledger.accounts.manage"
  @post_entries "finance.ledger.entries.post"

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"finance" => "Finance domain modules"},
        verbs: ["post"],
        capabilities: [@view, @manage_accounts, @post_entries],
        roles: %{
          "tenant_owner" => %{capabilities: [@view, @manage_accounts, @post_entries]}
        }
      }
    }
  end
end
