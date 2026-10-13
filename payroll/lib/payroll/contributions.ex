defmodule Bilimbi.Finance.Payroll.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  # The "finance" domain and the "post" verb are finance/ledger's; "view" and
  # "manage" are Base Authz's. This module declares no verb of its own, so it
  # cannot clash with a verb another Domain declares (Supply Chain's "post"
  # once refused to boot beside the ledger's).
  @view "finance.payroll.view"
  @manage_settings "finance.payroll.settings.manage"
  @post_postings "finance.payroll.postings.post"

  @capabilities [@view, @manage_settings, @post_postings]

  @impl true
  def contributions do
    %{
      authz: %{
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      },
      menu: [
        %{
          id: "finance.payroll",
          label: "Payroll and claims",
          icon: "users",
          parent: "finance",
          route: "/finance/payroll",
          capability: @view,
          order: 12
        }
      ]
    }
  end
end
