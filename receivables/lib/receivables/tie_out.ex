defmodule Bilimbi.Finance.Receivables.TieOut do
  @moduledoc false
  # The control-account tie-out: what this module's records say customers
  # still owe on each receivable account, against what the ledger holds
  # there, read at one ledger entry number. Every posting on a control
  # account that this module did not make is listed, never netted away,
  # so a divergence between the subledger and the ledger is shown, not
  # hidden. The facade authorizes the call.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Receivables.{Balances, Configuration, Document, Records}

  @doc """
  The tie-out as of `as_of`, through `through` (the ledger's last entry
  number when nil). Reads the ledger first, so the subledger counts
  exactly the postings the ledger's figures do.
  """
  def report(scope, company_id, as_of, through) do
    with {:ok, ledger} <-
           Ledger.account_totals_by_owner(scope, company_id,
             to: as_of,
             through_entry_number: through
           ),
         {:ok, chart} <- Ledger.list_accounts(scope, company_id) do
      through = ledger.through_entry_number
      subledger = owing_by_account(scope, company_id, as_of, through)
      postings = Enum.group_by(ledger.rows, & &1.id)
      accounts = Map.new(chart, &{&1.id, &1})

      rows =
        control_account_ids(scope, company_id, subledger)
        |> Enum.map(&row(&1, accounts, subledger, Map.get(postings, &1, [])))
        |> Enum.sort_by(& &1.code)

      {:ok,
       %{
         company_id: company_id,
         as_of: as_of,
         through_entry_number: through,
         currency_code: ledger.currency_code,
         minor_units: ledger.minor_units,
         owner_module: Records.module_id(),
         accounts: rows,
         total_difference: sum(rows, :difference),
         tied_out?: Enum.all?(rows, &Decimal.equal?(&1.difference, 0))
       }}
    end
  end

  # Each invoice's outstanding, summed on the receivable account it recorded.
  defp owing_by_account(scope, company_id, as_of, through) do
    scope
    |> Balances.owing(company_id, as_of, through)
    |> Enum.group_by(fn {invoice, _owed} -> invoice.receivable_account_id end, &elem(&1, 1))
    |> Map.new(fn {account_id, amounts} -> {account_id, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  # The receivable accounts the module ever recorded on an issued document
  # and the one its setup names now.
  defp control_account_ids(scope, company_id, subledger) do
    recorded =
      Records.query(Document, scope, company_id)
      |> where([d], d.status == "issued" and not is_nil(d.receivable_account_id))
      |> distinct(true)
      |> select([d], d.receivable_account_id)
      |> Repo.all()

    configured =
      case Configuration.context(scope, company_id) do
        {:ok, %{setup: %{receivable_account_id: id}}} when is_integer(id) -> [id]
        _not_configured -> []
      end

    Enum.uniq(recorded ++ configured ++ Map.keys(subledger))
  end

  # A receivable account is an asset: its balance is debits less credits.
  defp row(account_id, accounts, subledger, postings) do
    account = Map.fetch!(accounts, account_id)
    {own, others} = Enum.split_with(postings, &(&1.owner_module == Records.module_id()))
    subledger_balance = Map.get(subledger, account_id, Decimal.new(0))
    ledger_balance = balance(postings)

    %{
      account_id: account_id,
      code: account.code,
      name: account.name,
      subledger_balance: subledger_balance,
      ledger_balance: ledger_balance,
      owned_balance: balance(own),
      other_postings:
        others
        |> Enum.map(&%{owner_module: &1.owner_module, legacy: &1.legacy, balance: balance([&1])})
        |> Enum.sort_by(&{&1.owner_module || "", &1.legacy}),
      difference: Decimal.sub(subledger_balance, ledger_balance)
    }
  end

  defp balance(rows) do
    Enum.reduce(rows, Decimal.new(0), fn row, acc ->
      acc |> Decimal.add(row.debits) |> Decimal.sub(row.credits)
    end)
  end

  defp sum(rows, field),
    do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(Map.fetch!(&1, field), &2))
end
