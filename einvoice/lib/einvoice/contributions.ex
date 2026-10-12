defmodule Bilimbi.Finance.Einvoice.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  alias Bilimbi.Finance.Einvoice.Configuration
  alias Bilimbi.Finance.Einvoice.MyInvois
  alias Bilimbi.Finance.Einvoice.MyInvois.Client

  @view "finance.einvoice.view"
  @issue "finance.einvoice.documents.issue"
  @submit "finance.einvoice.documents.submit"
  @cancel "finance.einvoice.documents.cancel"
  @settings "finance.einvoice.settings.manage"
  @capabilities [@view, @issue, @submit, @cancel, @settings]

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"finance" => "Finance domain modules"},
        capabilities: @capabilities,
        roles: %{
          "tenant_owner" => %{capabilities: @capabilities}
        }
      },
      settings: %{
        definitions:
          Configuration.definitions()
          |> Map.merge(Client.settings_definitions())
          |> Map.merge(MyInvois.portal_settings_definitions()),
        runtime_claims: []
      },
      menu: [
        %{
          id: "finance.einvoice.documents",
          label: "E-invoices",
          icon: "circle-stack",
          parent: "finance",
          route: "/finance/einvoice/documents",
          capability: @view,
          order: 8
        },
        %{
          id: "finance.einvoice.consolidation",
          label: "E-invoice Consolidation",
          icon: "squares-2x2",
          parent: "finance",
          route: "/finance/einvoice/consolidation",
          capability: @view,
          order: 9
        },
        %{
          id: "finance.einvoice.reconciliation",
          label: "E-invoice Reconciliation",
          icon: "chart-bar",
          parent: "finance",
          route: "/finance/einvoice/reconciliation",
          capability: @view,
          order: 10
        },
        %{
          id: "finance.einvoice.setup",
          label: "E-invoice Setup",
          icon: "clipboard-document-list",
          parent: "finance",
          route: "/finance/einvoice/setup",
          capability: @settings,
          order: 11
        }
      ]
    }
  end
end
