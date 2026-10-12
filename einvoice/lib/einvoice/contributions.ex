defmodule Bilimbi.Finance.Einvoice.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  alias Bilimbi.Finance.Einvoice.Configuration
  alias Bilimbi.Finance.Einvoice.MyInvois.Client

  @view "finance.einvoice.view"
  @issue "finance.einvoice.documents.issue"
  @settings "finance.einvoice.settings.manage"

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"finance" => "Finance domain modules"},
        capabilities: [@view, @issue, @settings],
        roles: %{
          "tenant_owner" => %{capabilities: [@view, @issue, @settings]}
        }
      },
      settings: %{
        definitions: Map.merge(Configuration.definitions(), Client.settings_definitions()),
        runtime_claims: []
      },
      menu: [
        %{
          id: "finance.einvoice.setup",
          label: "E-invoice Setup",
          icon: "document-check",
          parent: "finance",
          route: "/finance/einvoice/setup",
          capability: @settings,
          order: 10
        }
      ]
    }
  end
end
