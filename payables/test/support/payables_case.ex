defmodule Bilimbi.Finance.Payables.PayablesCase do
  @moduledoc """
  A company with an open ledger book, the accounts a payables test posts to,
  payables settings, and one tax code, for the module's suites. The
  `operator` records and posts; the `approver`, another user with the same
  capabilities, approves, since the company requires separation of duties.

  The contribution registry snapshot is process-global, so suites using this
  case do not run alongside other suites.
  """

  use ExUnit.CaseTemplate

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Payables
  alias Bilimbi.Finance.Payables.TestFixtures

  using do
    quote do
      use Bilimbi.Base.Database.DataCase, async: false

      import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]
      import Bilimbi.Finance.Payables.PayablesCase

      alias Bilimbi.Finance.Ledger
      alias Bilimbi.Finance.Payables
      alias Bilimbi.Finance.Payables.TestFixtures

      # After DataCase's setup, which checks out the sandbox connection.
      setup :setup_company
    end
  end

  @ledger ~w(finance.ledger.view finance.ledger.accounts.manage finance.ledger.entries.post)
  @payables ~w(
    finance.payables.view
    finance.payables.settings.manage
    finance.payables.documents.create
    finance.payables.documents.approve
    finance.payables.documents.post
    finance.payables.payments.submit
    finance.payables.payments.post
    finance.payables.match.approve
  )

  @doc "Every ledger and payables capability."
  def all_capabilities, do: @ledger ++ @payables

  @doc "The case's company: see the moduledoc."
  def setup_company(_context) do
    context = TestFixtures.setup_payables!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, all_capabilities())
    approver = TestFixtures.sign_in!(context.first_scope, 73, 92, all_capabilities())
    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})
    Bilimbi.Finance.Ledger.TestFixtures.open_fiscal_years!(operator, 73)

    accounts =
      for {key, code, type} <-
            [
              bank: {"1000", "asset"},
              stock: {"1200", "asset"},
              tax: {"1300", "asset"},
              payable: {"2000", "liability"},
              other_payable: {"2100", "liability"},
              equity: {"3000", "equity"},
              expense: {"5000", "expense"}
            ]
            |> Enum.map(fn {key, {code, type}} -> {key, code, type} end),
          into: %{} do
        {:ok, account} =
          Ledger.create_account(operator, 73, %{
            code: code,
            name: "Account #{code}",
            account_type: type
          })

        {key, account}
      end

    {:ok, _settings} =
      Payables.put_settings(operator, 73, %{payable_account_id: accounts.payable.id})

    {:ok, tax_code} =
      Payables.create_tax_code(operator, 73, %{
        code: "T1",
        name: "Tax one",
        rate: "8",
        account_id: accounts.tax.id
      })

    Map.merge(context, %{
      operator: operator,
      approver: approver,
      accounts: accounts,
      tax_code: tax_code
    })
  end

  @doc "Bill attributes from the party `key` with `lines`."
  def bill(key, number, lines, extra \\ %{}) do
    Map.merge(
      %{
        party_key: key,
        party_name: "Party #{key}",
        party_document_number: number,
        document_date: ~D[2026-10-01],
        lines: lines
      },
      extra
    )
  end

  def line(account, amount, extra \\ %{}),
    do: Map.merge(%{description: "Line", account_id: account.id, amount: amount}, extra)

  @doc "Records, approves (as the approver), and posts a bill."
  def post_bill!(context, attributes) do
    {:ok, bill} = Payables.create_bill(context.operator, 73, attributes)
    {:ok, _approved} = Payables.approve_document(context.approver, 73, bill.id)
    {:ok, posted} = Payables.post_document(context.operator, 73, bill.id)
    posted
  end

  @doc """
  Submits a payment as the operator and approves it as the approver: the
  posted payment, or the first refusal.
  """
  def pay(context, attributes) do
    with {:ok, request} <- Payables.submit_payment(context.operator, 73, attributes) do
      Payables.approve_payment(context.approver, 73, request.id)
    end
  end

  def decimal?(value, expected), do: Decimal.equal?(value, expected)
end
