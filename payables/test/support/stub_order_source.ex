defmodule Bilimbi.Finance.Payables.StubOrderSource do
  @moduledoc """
  An order source for module tests, which run without Supply Chain: it
  answers from the lines a test `put!/1`s, in the shape the real facades
  answer, so the match is proved on what it is given. Installed with
  `install!/0` through the `:order_source` application environment that
  `Bilimbi.Finance.Payables.OrderSource` reads; `uninstall!/0` removes it.
  """
  @behaviour Bilimbi.Finance.Payables.OrderSource

  alias Bilimbi.Base.Tenancy.Scope

  @env :bilimbi_finance_payables
  @lines :stub_order_lines

  @doc "Routes `OrderSource` here for the rest of the test; the test's `on_exit` uninstalls it."
  def install!, do: Application.put_env(@env, :order_source, __MODULE__)

  def uninstall! do
    Application.delete_env(@env, :order_source)
    Application.delete_env(@env, @lines)
    Application.delete_env(@env, :stub_refused_user)
  end

  @doc """
  Puts one order line: `id`, `company_id`, `quantity`, `unit_price`, and
  optionally `received_quantity` (default 0), `currency_code` (default
  "XTS"), `order_status` (default "sent"), `order_number`, `order_id`, and
  `superseded_by_amendment_id`. A later call for the same ID replaces it.
  """
  def put!(line) when is_map(line) do
    line =
      Map.merge(
        %{
          received_quantity: Decimal.new(0),
          currency_code: "XTS",
          order_status: "sent",
          order_number: 1,
          order_id: 1,
          superseded_by_amendment_id: nil,
          company_id: 73
        },
        line
      )
      |> Map.update!(:quantity, &Decimal.new/1)
      |> Map.update!(:unit_price, &Decimal.new/1)
      |> Map.update!(:received_quantity, &Decimal.new/1)

    Application.put_env(@env, @lines, Map.put(lines(), line.id, line))
    line
  end

  @doc "The actor refused by name: every read for this scope's user is `{:error, :unauthorized}`."
  def refuse!(user_id), do: Application.put_env(@env, :stub_refused_user, user_id)

  defp lines, do: Application.get_env(@env, @lines, %{})

  @impl true
  def order_line(%Scope{} = scope, company_id, line_id) do
    with :ok <- allowed(scope) do
      case Map.get(lines(), line_id) do
        %{company_id: ^company_id} = line ->
          {:ok,
           Map.take(line, [
             :id,
             :quantity,
             :unit_price,
             :currency_code,
             :order_status,
             :order_number,
             :order_id,
             :superseded_by_amendment_id
           ])}

        _other ->
          {:error, :line_not_found}
      end
    end
  end

  @impl true
  def line_receipts(%Scope{} = scope, company_id, line_id) do
    with :ok <- allowed(scope) do
      case Map.get(lines(), line_id) do
        %{company_id: ^company_id} = line ->
          {:ok, %{order_line_id: line_id, received_quantity: line.received_quantity}}

        _other ->
          {:ok, %{order_line_id: line_id, received_quantity: Decimal.new(0)}}
      end
    end
  end

  defp allowed(scope) do
    if Scope.actor(scope).user_id == Application.get_env(@env, :stub_refused_user),
      do: {:error, :unauthorized},
      else: :ok
  end
end
