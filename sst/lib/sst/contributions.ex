defmodule Bilimbi.Finance.Sst.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  # The "finance" domain is finance/ledger's and "view" and "manage" are the
  # platform's. Authz verbs are owned once across every mounted Domain, so
  # this module's own verbs carry the `sst-` prefix no other Domain uses.
  @view "finance.sst.view"
  @manage_settings "finance.sst.settings.manage"
  @prepare_returns "finance.sst.returns.sst-prepare"
  @finalise_returns "finance.sst.returns.sst-finalise"
  @amend_returns "finance.sst.returns.sst-amend"

  @capabilities [@view, @manage_settings, @prepare_returns, @finalise_returns, @amend_returns]

  @impl true
  def contributions do
    %{
      authz: %{
        verbs: ["sst-prepare", "sst-finalise", "sst-amend"],
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      },
      menu: [
        %{
          id: "finance.sst",
          label: "SST returns",
          icon: "document-text",
          parent: "finance",
          route: "/finance/sst",
          capability: @view,
          order: 18
        },
        %{
          id: "finance.sst.setup",
          label: "SST setup",
          icon: "adjustments-horizontal",
          parent: "finance",
          route: "/finance/sst/setup",
          capability: @view,
          order: 19
        }
      ]
    }
  end
end
