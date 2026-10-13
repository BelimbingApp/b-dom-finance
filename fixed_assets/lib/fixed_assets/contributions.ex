defmodule Bilimbi.Finance.FixedAssets.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider
  @verbs ~w(finance-asset-configure finance-asset-acquire finance-asset-depreciate finance-asset-reverse finance-asset-dispose)
  @capabilities ["finance.fixed-assets.view" | Enum.map(@verbs, &"finance.fixed-assets.#{&1}")]
  def capabilities, do: @capabilities
  @impl true
  def contributions do
    %{
      authz: %{
        verbs: @verbs,
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      },
      menu:
        Enum.with_index(
          [
            {"register", "Fixed assets"},
            {"categories", "Asset categories"},
            {"runs", "Depreciation runs"}
          ],
          40
        )
        |> Enum.map(fn {{path, label}, order} ->
          %{
            id: "finance.fixed-assets.#{path}",
            label: label,
            icon: "clipboard-document-list",
            parent: "finance",
            route: "/finance/fixed-assets/#{path}",
            capability: "finance.fixed-assets.view",
            order: order
          }
        end)
    }
  end
end
