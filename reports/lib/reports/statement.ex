defmodule Bilimbi.Finance.Reports.Statement do
  @moduledoc false

  # Builds a report's figures from the chart and the ledger's per-account
  # totals, one totals map (`account_id => {debits, credits}`) per column.
  # Nothing here reads data: the facade reads, this arranges and adds.
  #
  # Grouping is by the five account types, the one fixed classification, and
  # inside a type by the company's configured sections (see `Layout`); an
  # account no section covers is listed after them under no heading. Each
  # account reports its own postings, so a parent is never counted twice.

  @debit_normal ~w(asset expense)

  @doc """
  An account's balance on its type's natural side: assets and expenses as
  debits less credits, liabilities, equity and income as credits less debits.
  """
  def natural(type, {debits, credits}) when type in @debit_normal,
    do: Decimal.sub(debits, credits)

  def natural(_type, {debits, credits}), do: Decimal.sub(credits, debits)

  @doc "Income and expense for each column, and income less expense."
  def profit_and_loss(accounts, sections, membership, columns) do
    [income, expense] = groups(~w(income expense), accounts, sections, membership, columns)
    %{groups: [income, expense], net_income: subtract(income.totals, expense.totals)}
  end

  @doc """
  Assets, liabilities and equity as of each column's date. Income less
  expense not yet closed into an equity account (`earnings`) belongs to
  equity and is part of its totals, so assets equal liabilities and equity.
  """
  def balance_sheet(accounts, sections, membership, columns) do
    [assets, liabilities, equity] =
      groups(~w(asset liability equity), accounts, sections, membership, columns)

    earnings =
      Enum.map(columns, fn totals ->
        accounts
        |> Enum.filter(&(&1.account_type in ~w(income expense)))
        |> Enum.reduce(zero(), fn account, sum ->
          {debits, credits} = Map.get(totals, account.id, {zero(), zero()})
          sum |> Decimal.add(credits) |> Decimal.sub(debits)
        end)
      end)

    equity = %{equity | totals: add(equity.totals, earnings)}

    %{
      groups: [assets, liabilities, equity],
      earnings: earnings,
      total_assets: assets.totals,
      total_liabilities_and_equity: add(liabilities.totals, equity.totals)
    }
  end

  @doc """
  The balances of the accounts the cash sections cover, debits less credits
  whatever their type, so an overdrawn account counts against the total.
  Every covered account is listed, with or without postings.
  """
  def cash_position(accounts, sections, membership, columns) do
    covered =
      accounts
      |> Enum.filter(&Map.has_key?(membership, &1.id))
      |> Enum.sort_by(& &1.code)
      |> Enum.map(&row(&1, columns, fn _account, totals -> natural("asset", totals) end))

    by_section = Enum.group_by(covered, &Map.fetch!(membership, &1.account_id))

    sections =
      for {section, index} <- Enum.with_index(sections),
          rows = Map.get(by_section, index),
          rows != nil,
          do: section(section.name, rows, length(columns))

    %{sections: sections, totals: sum(Enum.map(sections, & &1.totals), length(columns))}
  end

  defp groups(types, accounts, sections, membership, columns) do
    width = length(columns)

    for type <- types do
      rows =
        accounts
        |> Enum.filter(&(&1.account_type == type and posted?(&1, columns)))
        |> Enum.sort_by(& &1.code)
        |> Enum.map(
          &row(&1, columns, fn account, totals -> natural(account.account_type, totals) end)
        )

      by_section = Enum.group_by(rows, &Map.get(membership, &1.account_id))

      named =
        for {section, index} <- Enum.with_index(sections),
            rows = Map.get(by_section, index),
            rows != nil,
            do: section(section.name, rows, width)

      unassigned =
        case Map.get(by_section, nil) do
          nil -> []
          rows -> [section(nil, rows, width)]
        end

      listed = named ++ unassigned
      %{account_type: type, sections: listed, totals: sum(Enum.map(listed, & &1.totals), width)}
    end
  end

  defp posted?(account, columns), do: Enum.any?(columns, &Map.has_key?(&1, account.id))

  defp row(account, columns, amount) do
    account
    |> Map.take([:code, :name, :account_type, :parent_id, :active])
    |> Map.put(:account_id, account.id)
    |> Map.put(
      :amounts,
      Enum.map(columns, &amount.(account, Map.get(&1, account.id, {zero(), zero()})))
    )
  end

  defp section(name, rows, width),
    do: %{name: name, rows: rows, totals: sum(Enum.map(rows, & &1.amounts), width)}

  defp sum(lists, width), do: Enum.reduce(lists, List.duplicate(zero(), width), &add(&2, &1))

  defp add(left, right), do: Enum.zip_with(left, right, &Decimal.add/2)
  defp subtract(left, right), do: Enum.zip_with(left, right, &Decimal.sub/2)

  defp zero, do: Decimal.new(0)
end
