defmodule Bilimbi.Finance.Reports do
  @moduledoc """
  A company's financial statements, read live from its general ledger:
  profit and loss for date ranges, the balance sheet and the cash position
  as of dates, headline figures for a period against the one before it, and
  the entries behind any account's figure.

  Every figure comes from `Bilimbi.Finance.Ledger`'s facade; this module
  owns no table and reads none of the ledger's. Each function takes the
  validated `Bilimbi.Base.Tenancy.Scope` it was handed and an explicit
  company ID, and authorizes the ledger's view capability for the scope's
  signed-in actor and that company when it runs, through
  `Bilimbi.Core.Company.authorize_company_target/3`: a system scope or a
  missing grant is `{:error, :unauthorized}` and a company the scope cannot
  see is `{:error, :company_not_found}`.

  A report names `through_entry_number`, the last ledger entry it counts.
  Passing it back as the `through_entry_number` option reproduces the same
  figures exactly, whatever was posted since, because posted entries never
  change and are numbered in posting order. Every column of one report is
  read at the same entry number.

  Accounts are grouped by their type and, within a type, by the sections the
  company configures in the `finance.reports.sections` setting (see the
  module README). Section headings and account choices are the company's
  data; a report reads them as they are when it runs.
  """

  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Reports.{Layout, Statement}

  @sections_key "finance.reports.sections"
  @max_columns 4
  @default_entry_limit 100

  @type refusal :: :unauthorized | :company_not_found | :book_not_open | :invalid_option

  @doc "The setting that holds a company's report sections."
  def sections_key, do: @sections_key

  @doc "Whether a value is a valid report layout; Base Settings' validator."
  @spec valid_sections?(term()) :: boolean()
  def valid_sections?(value), do: Layout.valid?(value)

  @doc "The capability every report asks for: the ledger's view capability."
  def view_capability, do: Ledger.view_capability()

  @doc """
  The period of the same length that ends the day before `from`. A period of
  whole calendar months gives the same number of whole months before it, so
  a quarter compares with the previous quarter; any other period gives the
  same number of days.
  """
  @spec previous_period({Date.t(), Date.t()}) :: {Date.t(), Date.t()}
  def previous_period({%Date{} = from, %Date{} = to}) do
    if from.day == 1 and to == Date.end_of_month(to) do
      months = (to.year - from.year) * 12 + to.month - from.month + 1
      {Date.shift(from, month: -months), Date.add(from, -1)}
    else
      {Date.add(from, -(Date.diff(to, from) + 1)), Date.add(from, -1)}
    end
  end

  @doc """
  Profit and loss for each `{from, to}` period in `periods` (one to
  #{@max_columns}; the first is the reporting period, the rest its
  comparatives): income and expense groups, each split into sections with
  per-account rows, and `net_income` per column. Every amount is a list with
  one value per period. Options: `through_entry_number`.
  """
  @spec profit_and_loss(Scope.t(), term(), [{Date.t(), Date.t()}], keyword()) ::
          {:ok, map()} | {:error, refusal()}
  def profit_and_loss(%Scope{} = scope, company_id, periods, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id),
         {:ok, periods} <- periods(periods),
         {:ok, read} <- read(scope, company_id, Enum.map(periods, &window/1), options) do
      {sections, membership, unmatched} = arrange(read, scope, company_id, "profit_and_loss")

      {:ok,
       read
       |> header(Enum.map(periods, fn {from, to} -> %{from: from, to: to} end), unmatched)
       |> Map.merge(Statement.profit_and_loss(read.accounts, sections, membership, read.columns))}
    end
  end

  @doc """
  The balance sheet as of each date in `dates` (one to #{@max_columns}):
  asset, liability and equity groups with sections and rows, `earnings`
  (income less expense not yet closed into an equity account, counted in
  equity), `total_assets`, and `total_liabilities_and_equity`, which equal
  each other. Options: `through_entry_number`.
  """
  @spec balance_sheet(Scope.t(), term(), [Date.t()], keyword()) ::
          {:ok, map()} | {:error, refusal()}
  def balance_sheet(%Scope{} = scope, company_id, dates, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id),
         {:ok, dates} <- dates(dates),
         {:ok, read} <- read(scope, company_id, Enum.map(dates, &[to: &1]), options) do
      {sections, membership, unmatched} = arrange(read, scope, company_id, "balance_sheet")

      {:ok,
       read
       |> header(Enum.map(dates, &%{as_of: &1}), unmatched)
       |> Map.merge(Statement.balance_sheet(read.accounts, sections, membership, read.columns))}
    end
  end

  @doc """
  The cash position as of each date in `dates` (one to #{@max_columns}):
  every account the company's cash sections cover, with its balance as
  debits less credits, by section, and the total. Without configured cash
  sections it lists nothing. Options: `through_entry_number`.
  """
  @spec cash_position(Scope.t(), term(), [Date.t()], keyword()) ::
          {:ok, map()} | {:error, refusal()}
  def cash_position(%Scope{} = scope, company_id, dates, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id),
         {:ok, dates} <- dates(dates),
         {:ok, read} <- read(scope, company_id, Enum.map(dates, &[to: &1]), options) do
      {sections, membership, unmatched} = arrange(read, scope, company_id, "cash_position")

      {:ok,
       read
       |> header(Enum.map(dates, &%{as_of: &1}), unmatched)
       |> Map.merge(Statement.cash_position(read.accounts, sections, membership, read.columns))}
    end
  end

  @doc """
  Headline figures for the period `{from, to}` and the period before it
  (`previous_period/1`): `income`, `expense` and `net_income` over each
  period, and `assets`, `liabilities`, `equity` and `cash` as of each
  period's last day, each a two-value list. Options: `through_entry_number`.
  """
  @spec overview(Scope.t(), term(), {Date.t(), Date.t()}, keyword()) ::
          {:ok, map()} | {:error, refusal()}
  def overview(%Scope{} = scope, company_id, period, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id),
         {:ok, [current]} <- periods([period]) do
      previous = previous_period(current)

      windows =
        Enum.map([current, previous], &window/1) ++
          [[to: elem(current, 1)], [to: elem(previous, 1)]]

      with {:ok, read} <- read(scope, company_id, windows, options) do
        [current_flow, previous_flow, current_stock, previous_stock] = read.columns
        flows = [current_flow, previous_flow]
        stocks = [current_stock, previous_stock]

        {pl_sections, pl_membership, _} = arrange(read, scope, company_id, "profit_and_loss")
        {cash_sections, cash_membership, _} = arrange(read, scope, company_id, "cash_position")

        %{groups: [income, expense], net_income: net_income} =
          Statement.profit_and_loss(read.accounts, pl_sections, pl_membership, flows)

        %{groups: [assets, liabilities, equity]} =
          Statement.balance_sheet(read.accounts, [], %{}, stocks)

        cash = Statement.cash_position(read.accounts, cash_sections, cash_membership, stocks)

        {:ok,
         read
         |> header(Enum.map([current, previous], fn {from, to} -> %{from: from, to: to} end), [])
         |> Map.delete(:unmatched_codes)
         |> Map.merge(%{
           income: income.totals,
           expense: expense.totals,
           net_income: net_income,
           assets: assets.totals,
           liabilities: liabilities.totals,
           equity: equity.totals,
           cash: cash.totals
         })}
      end
    end
  end

  @doc """
  The entries behind one account's figure: the account, its `debits` and
  `credits` over the entries dated from `from` through `to` (both optional
  and inclusive), and those entries in date order with all their lines and
  the account's own `debit` and `credit` in each. Pass the report's
  `through_entry_number` to list exactly the entries its figure counted.
  Entries come `limit` at a time (1 to 500, default #{@default_entry_limit});
  `more?` is true when the page came back full, and the next page, which may
  be empty, is read by passing the last entry's `{entry_date, id}` as
  `after`. A malformed option is
  `{:error, :invalid_option}`.
  """
  @spec account_activity(Scope.t(), term(), term(), keyword()) ::
          {:ok, map()} | {:error, refusal() | :account_not_found}
  def account_activity(%Scope{} = scope, company_id, account_id, options \\ [])
      when is_list(options) do
    window = Keyword.take(options, [:from, :to])
    limit = Keyword.get(options, :limit, @default_entry_limit)

    with :ok <- authorize(scope, company_id),
         {:ok, accounts} <- Ledger.list_accounts(scope, company_id),
         {:ok, account} <- find_account(accounts, account_id),
         {:ok, totals} <-
           Ledger.account_totals(
             scope,
             company_id,
             window ++ Keyword.take(options, [:through_entry_number])
           ),
         {:ok, entries} <-
           Ledger.list_entries(
             scope,
             company_id,
             window ++
               [
                 account_id: account.id,
                 through_entry_number: totals.through_entry_number,
                 limit: limit,
                 after: Keyword.get(options, :after)
               ]
           ) do
      row =
        Enum.find(
          totals.rows,
          %{debits: Decimal.new(0), credits: Decimal.new(0)},
          &(&1.id == account.id)
        )

      {:ok,
       %{
         company_id: company_id,
         account: account,
         from: totals.from,
         to: totals.to,
         through_entry_number: totals.through_entry_number,
         currency_code: totals.currency_code,
         minor_units: totals.minor_units,
         debits: row.debits,
         credits: row.credits,
         entries: Enum.map(entries, &on_account(&1, account.id)),
         more?: length(entries) == limit
       }}
    end
  end

  @doc """
  Subscribes the calling process to the company's postings
  (`Bilimbi.Finance.Ledger.subscribe_postings/2`), so a live report reads
  again when the ledger changes.
  """
  @spec subscribe(Scope.t(), term()) :: :ok | {:error, :unauthorized | :company_not_found}
  def subscribe(%Scope{} = scope, company_id), do: Ledger.subscribe_postings(scope, company_id)

  ## Reading

  # Every window is read at the first one's entry number, so the columns
  # describe one state of the ledger. The ledger validates the number.
  defp read(scope, company_id, windows, options) do
    through = Keyword.get(options, :through_entry_number)

    with {:ok, [first | _] = results} <- totals(scope, company_id, windows, through),
         {:ok, accounts} <- Ledger.list_accounts(scope, company_id) do
      {:ok,
       %{
         company_id: company_id,
         currency_code: first.currency_code,
         minor_units: first.minor_units,
         through_entry_number: first.through_entry_number,
         accounts: accounts,
         columns:
           Enum.map(results, fn result ->
             Map.new(result.rows, &{&1.id, {&1.debits, &1.credits}})
           end)
       }}
    end
  end

  defp totals(scope, company_id, windows, through) do
    windows
    |> Enum.reduce_while({:ok, [], through}, fn window, {:ok, results, through} ->
      case Ledger.account_totals(scope, company_id, window ++ [through_entry_number: through]) do
        {:ok, result} -> {:cont, {:ok, [result | results], result.through_entry_number}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results, _through} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp arrange(read, scope, company_id, report) do
    sections =
      @sections_key
      |> Settings.get(Settings.Scope.company(company_id, Scope.tenant_id(scope)))
      |> Layout.sections(report)

    {membership, unmatched} = Layout.assign(read.accounts, sections)
    {sections, membership, unmatched}
  end

  defp header(read, columns, unmatched) do
    read
    |> Map.take([:company_id, :currency_code, :minor_units, :through_entry_number])
    |> Map.merge(%{columns: columns, unmatched_codes: unmatched})
  end

  defp on_account(entry, account_id) do
    lines = Enum.filter(entry.lines, &(&1.account_id == account_id))

    Map.merge(entry, %{
      debit: Enum.reduce(lines, Decimal.new(0), &Decimal.add(&1.debit, &2)),
      credit: Enum.reduce(lines, Decimal.new(0), &Decimal.add(&1.credit, &2))
    })
  end

  defp find_account(accounts, account_id) do
    case Enum.find(accounts, &(&1.id == account_id)) do
      nil -> {:error, :account_not_found}
      account -> {:ok, account}
    end
  end

  ## Options

  defp window({from, to}), do: [from: from, to: to]

  defp periods(periods) when is_list(periods) and length(periods) in 1..@max_columns do
    if Enum.all?(periods, &period?/1), do: {:ok, periods}, else: {:error, :invalid_option}
  end

  defp periods(_periods), do: {:error, :invalid_option}

  defp period?({%Date{} = from, %Date{} = to}), do: Date.compare(from, to) != :gt
  defp period?(_period), do: false

  defp dates(dates) when is_list(dates) and length(dates) in 1..@max_columns do
    if Enum.all?(dates, &match?(%Date{}, &1)), do: {:ok, dates}, else: {:error, :invalid_option}
  end

  defp dates(_dates), do: {:error, :invalid_option}

  ## Authorization

  defp authorize(scope, company_id) do
    case Company.authorize_company_target(scope, company_id, Ledger.view_capability()) do
      {:ok, _company} -> :ok
      {:error, :not_found} -> {:error, :company_not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end
end
