defmodule Bilimbi.Finance.Payables.OrderSource.Installed do
  @moduledoc false
  # The order source over the installed purchasing and receiving facades,
  # found by descriptor ID at run time. The calls are dynamic on purpose:
  # see `Bilimbi.Finance.Payables.OrderSource`.
  @behaviour Bilimbi.Finance.Payables.OrderSource

  alias Bilimbi.Finance.Payables.OrderSource

  @impl true
  def order_line(scope, company_id, line_id) do
    with {:ok, %{purchasing: purchasing}} <- facades() do
      apply(purchasing, :get_order_line, [scope, company_id, line_id])
    end
  end

  @impl true
  def line_receipts(scope, company_id, line_id) do
    with {:ok, %{receiving: receiving}} <- facades() do
      apply(receiving, :order_line_receipts, [scope, company_id, line_id])
    end
  end

  defp facades do
    case OrderSource.facades() do
      {:ok, facades} -> {:ok, facades}
      :unavailable -> {:error, :order_source_unavailable}
    end
  end
end
