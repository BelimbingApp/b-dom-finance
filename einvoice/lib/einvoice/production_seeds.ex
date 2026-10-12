defmodule Bilimbi.Finance.Einvoice.ProductionSeeds do
  @moduledoc """
  Loads the authority's shipped code lists. A seed runs once per ID, so a
  refreshed list file ships with a new seed ID naming its date.
  """

  @behaviour Bilimbi.Base.Database.ProductionSeedProvider

  alias Bilimbi.Base.Database
  alias Bilimbi.Finance.Einvoice.CodeLists

  @impl true
  def production_seeds do
    [
      Database.production_seed!(
        :bilimbi_finance_einvoice,
        "myinvois-code-lists-2026-10-12",
        fn repo -> CodeLists.seed!("myinvois", repo) end
      )
    ]
  end
end
