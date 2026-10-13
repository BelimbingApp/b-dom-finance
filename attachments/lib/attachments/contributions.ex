defmodule Bilimbi.Finance.Attachments.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  # The "finance" domain is finance/ledger's; "view", "create", "delete", and
  # "manage" are Base Authz's verbs. This module declares no verb of its own,
  # so it cannot clash with a verb another Domain declares (Supply Chain's
  # "post" once refused to boot beside the ledger's). The capabilities are
  # this module's: attaching, removing, and downloading a source document
  # each re-asks its own.
  @view "finance.attachments.view"
  @create "finance.attachments.create"
  @delete "finance.attachments.delete"
  @manage_retention "finance.attachments.retention.manage"

  @capabilities [@view, @create, @delete, @manage_retention]

  @impl true
  def contributions do
    %{
      authz: %{
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      },
      menu: [
        %{
          id: "finance.attachments",
          label: "Source documents",
          icon: "shield-check",
          parent: "finance",
          route: "/finance/attachments",
          capability: @view,
          order: 18
        }
      ]
    }
  end
end
