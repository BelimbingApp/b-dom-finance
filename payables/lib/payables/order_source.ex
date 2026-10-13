defmodule Bilimbi.Finance.Payables.OrderSource do
  @moduledoc """
  The seam to the purchase orders and goods receipts a bill is matched
  against, in an optional Domain this module never names.

  Finance builds and runs without Supply Chain. A bill line's
  `order_line_id` is an order line of whichever source is installed;
  `installed/0` finds it among the module descriptors Base Module Registry
  recorded for the loaded applications, by the descriptor IDs
  `supply_chain/purchasing` and `supply_chain/receiving`, the stable
  logical IDs the composition model names modules by, and calls their
  facades by the namespace each descriptor declares. Nothing here
  aliases a `Bilimbi.SupplyChain` module: the descriptor is the contract,
  Bilimbi's `graph_edges` gate refuses an undeclared alias, and declaring
  the edge would make Finance fail to compose without Supply Chain. When
  neither module is loaded the source is `:unavailable`, and matching is
  simply unavailable.

  Both reads take the scope the payables call was handed, so the actor also
  holds the source's own view capabilities (for Supply Chain,
  `supply-chain.purchasing.view` and `supply-chain.receiving.view`); the
  source refuses otherwise, as any facade does.

  The behaviour is what the source answers. `order_line/3` is the line with
  `quantity`, `unit_price`, `currency_code`, `order_id`, `order_number`,
  `order_status`, and `superseded_by_amendment_id`, or `{:error,
  :line_not_found}`; `line_receipts/3` is the net `received_quantity` posted
  against it (zero when nothing was). A test substitutes a source through
  the `:order_source` key of this module's application environment.
  """

  alias Bilimbi.Base.Tenancy.Scope

  @purchasing_id "supply_chain/purchasing"
  @receiving_id "supply_chain/receiving"

  @callback order_line(Scope.t(), term(), term()) :: {:ok, map()} | {:error, term()}
  @callback line_receipts(Scope.t(), term(), term()) :: {:ok, map()} | {:error, term()}

  @doc "The source in use: the test substitute, else the installed one, else `:unavailable`."
  @spec source() :: module() | :unavailable
  def source do
    case Application.get_env(:bilimbi_finance_payables, :order_source) do
      nil -> installed()
      module when is_atom(module) -> module
    end
  end

  @doc "Whether a source is installed, so a bill line may name an order line."
  @spec available?() :: boolean()
  def available?, do: source() != :unavailable

  @doc "The order line, through the source in use."
  @spec order_line(Scope.t(), term(), term()) :: {:ok, map()} | {:error, term()}
  def order_line(%Scope{} = scope, company_id, line_id) do
    case source() do
      :unavailable -> {:error, :order_source_unavailable}
      module -> module.order_line(scope, company_id, line_id)
    end
  end

  @doc "What was received against the order line, through the source in use."
  @spec line_receipts(Scope.t(), term(), term()) :: {:ok, map()} | {:error, term()}
  def line_receipts(%Scope{} = scope, company_id, line_id) do
    case source() do
      :unavailable -> {:error, :order_source_unavailable}
      module -> module.line_receipts(scope, company_id, line_id)
    end
  end

  @doc """
  The installed source: this module's own implementation over the
  purchasing and receiving facades when both are loaded, else `:unavailable`.
  """
  @spec installed() :: module() | :unavailable
  def installed do
    case facades() do
      {:ok, _facades} -> __MODULE__.Installed
      :unavailable -> :unavailable
    end
  end

  @doc false
  # The two facades' modules, from the descriptors of the applications this
  # runtime loaded: Mix records each module's descriptor as the `:bilimbi_module`
  # key of its application environment (`module_discovery.exs`). The
  # registry's `installed_modules!/0` would validate the whole graph's order,
  # which a package-local Domain runtime cannot satisfy; the host validated
  # it at boot, and here only the two IDs and their namespaces are read.
  def facades do
    namespaces =
      for {app, _description, _version} <- Application.loaded_applications(),
          descriptor <- [Application.get_env(app, :bilimbi_module)],
          is_map(descriptor) and Map.get(descriptor, :id) in [@purchasing_id, @receiving_id],
          into: %{},
          do: {descriptor.id, descriptor.namespace}

    with %{@purchasing_id => purchasing, @receiving_id => receiving} <- namespaces,
         true <- Code.ensure_loaded?(purchasing) and Code.ensure_loaded?(receiving) do
      {:ok, %{purchasing: purchasing, receiving: receiving}}
    else
      _missing -> :unavailable
    end
  end
end
