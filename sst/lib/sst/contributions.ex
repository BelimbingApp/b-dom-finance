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
      # Menu icons come from the Web host's safelist in apps/web/assets/css/app.css;
      # an icon outside it is not emitted and fails the host's safelist test.
      menu: [
        %{
          id: "finance.sst",
          label: "SST returns",
          icon: "shield-check",
          parent: "finance",
          route: "/finance/sst",
          capability: @view,
          order: 18
        },
        %{
          id: "finance.sst.setup",
          label: "SST setup",
          icon: "cog-6-tooth",
          parent: "finance",
          route: "/finance/sst/setup",
          capability: @view,
          order: 19
        }
      ]
    }
  end
end
