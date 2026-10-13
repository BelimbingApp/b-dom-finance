defmodule Bilimbi.Finance.Reports.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  # Reports read ledger figures, so they stand on the ledger's capabilities:
  # viewing them is viewing the ledger, and arranging them is part of
  # keeping the chart of accounts.
  @view "finance.ledger.view"
  @manage_accounts "finance.ledger.accounts.manage"

  @impl true
  def contributions do
    %{
      authz: %{
        verbs: ["export"],
        capabilities: ["finance.reports.issue", "finance.reports.export"],
        roles: %{
          "tenant_owner" => %{capabilities: ["finance.reports.issue", "finance.reports.export"]}
        }
      },
      menu: [
        %{
          id: "finance.reports",
          label: "Reports",
          parent: "finance",
          route: "/finance/reports",
          capability: @view,
          order: 20
        }
      ],
      settings: %{
        definitions: %{
          "finance.reports.sections" => %{
            type: :array,
            scopes: [:tenant, :company],
            default: [],
            label: "Report sections",
            help:
              "Sections that group accounts in the reports, in order: a JSON list of " <>
                ~s({"report": "profit_and_loss", "balance_sheet" or "cash_position", ) <>
                ~s("name": heading, "accounts": [account codes]}. A listed account ) <>
                "brings its sub-accounts; the cash position lists only the accounts its sections name.",
            editable: "finance.reports",
            capability: @manage_accounts,
            validator:
              {Bilimbi.Finance.Reports, :valid_sections?,
               "must be a list of sections, each with only a report, a name and account codes"}
          }
        }
      }
    }
  end
end
