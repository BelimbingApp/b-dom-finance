defmodule Bilimbi.Finance.Sst.SstCase do
  @moduledoc """
  A company with an open ledger book, a chart, receivables and payables set
  up with tax codes, and an SST registration on a two-month cycle from
  1 January 2026, for the module's suites. Tax codes start unmapped; a
  test maps the ones it reports.

  The contribution registry snapshot is process-global, so suites using this
  case do not run alongside other suites.
  """

  use ExUnit.CaseTemplate

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Payables
  alias Bilimbi.Finance.Receivables
  alias Bilimbi.Finance.Sst
  alias Bilimbi.Finance.Sst.TestFixtures

  using do
    quote do
      use Bilimbi.Base.Database.DataCase, async: false

      import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]
      import Bilimbi.Finance.Sst.SstCase

      alias Bilimbi.Finance.Ledger
      alias Bilimbi.Finance.Payables
      alias Bilimbi.Finance.Receivables
      alias Bilimbi.Finance.Sst
      alias Bilimbi.Finance.Sst.TestFixtures

      # After DataCase's setup, which checks out the sandbox connection.
      setup :setup_company
    end
  end

  @ledger ~w(finance.ledger.view finance.ledger.accounts.manage finance.ledger.entries.post)
  @receivables ~w(
    finance.receivables.view
    finance.receivables.setup.manage
    finance.receivables.customers.manage
    finance.receivables.documents.manage
    finance.receivables.documents.issue
    finance.receivables.payments.post
  )
  @payables ~w(
    finance.payables.view
    finance.payables.settings.manage
    finance.payables.documents.create
    finance.payables.documents.approve
    finance.payables.documents.post
  )
  @sst ~w(
    finance.sst.view
    finance.sst.settings.manage
    finance.sst.returns.sst-prepare
    finance.sst.returns.sst-finalise
    finance.sst.returns.sst-amend
  )

  @doc "Every capability the case grants its operator."
  def all_capabilities, do: @ledger ++ @receivables ++ @payables ++ @sst

  @doc "The SST capabilities alone."
  def sst_capabilities, do: @sst

  @doc "What reading a return's figures needs besides an SST capability."
  def reading_capabilities,
    do: ~w(finance.ledger.view finance.receivables.view finance.payables.view)

  @doc "The case's company: see the moduledoc."
  def setup_company(_context) do
    context = TestFixtures.setup_sst!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    Map.merge(context, build_company!(context.first_scope, 91))
  end

  @doc "Builds the company as `user_id`, who holds every capability; see the moduledoc."
  def build_company!(scope, user_id) do
    operator = TestFixtures.sign_in!(scope, 73, user_id, all_capabilities())
    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})

    accounts =
      for {key, code, type} <- [
            {:cash, "1000", "asset"},
            {:receivable, "1100", "asset"},
            {:input_tax, "1300", "asset"},
            {:payable, "2000", "liability"},
            {:sales_tax, "2100", "liability"},
            {:service_tax, "2200", "liability"},
            {:equity, "3000", "equity"},
            {:income, "4000", "income"},
            {:expense, "5000", "expense"}
          ],
          into: %{} do
        {:ok, account} =
          Ledger.create_account(operator, 73, %{
            code: code,
            name: "Account #{code}",
            account_type: type
          })

        {key, account}
      end

    {:ok, _setup} =
      Receivables.configure(operator, 73, %{
        receivable_account_id: accounts.receivable.id,
        income_account_id: accounts.income.id
      })

    series =
      for {key, code, kind, prefix} <- [
            {:invoice_series, "INV", "invoice", "INV-"},
            {:credit_series, "CN", "credit_note", "CN-"},
            {:payment_series, "RCP", "payment", "RCP-"}
          ],
          into: %{} do
        {:ok, series} =
          Receivables.create_series(operator, 73, %{
            code: code,
            name: "#{kind} series",
            kind: kind,
            prefix: prefix,
            number_width: 4
          })

        {key, series}
      end

    {:ok, customer} =
      Receivables.create_customer(operator, 73, %{code: "C001", name: "Example Customer"})

    receivable_codes =
      for {key, code, rate, account} <- [
            {:goods10, "G10", "10", :sales_tax},
            {:goods5, "G5", "5", :sales_tax},
            {:services8, "S8", "8", :service_tax},
            {:services6, "S6", "6", :service_tax},
            {:export, "EXP", "0", :sales_tax}
          ],
          into: %{} do
        {:ok, tax_code} =
          Receivables.create_tax_code(operator, 73, %{
            code: code,
            name: "Code #{code}",
            rate: rate,
            account_id: Map.fetch!(accounts, account).id
          })

        {key, tax_code}
      end

    {:ok, _settings} =
      Payables.put_settings(operator, 73, %{payable_account_id: accounts.payable.id})

    payable_codes =
      for {key, code, rate, account} <- [
            {:imported8, "IMP8", "8", :service_tax},
            {:schedule_c, "SCC1", "0", :input_tax}
          ],
          into: %{} do
        {:ok, tax_code} =
          Payables.create_tax_code(operator, 73, %{
            code: code,
            name: "Code #{code}",
            rate: rate,
            account_id: Map.fetch!(accounts, account).id
          })

        {key, tax_code}
      end

    {:ok, registration} =
      Sst.register(operator, 73, %{
        sales_tax_number: TestFixtures.sales_tax_number(),
        service_tax_number: TestFixtures.service_tax_number(),
        period_months: 2,
        period_start: ~D[2026-01-01]
      })

    series
    |> Map.merge(%{
      operator: operator,
      accounts: accounts,
      customer: customer,
      codes: receivable_codes,
      payable_codes: payable_codes,
      registration: registration
    })
  end

  @doc "Maps each `{source, code key, box}`."
  def map!(context, mappings) do
    for {source, key, box} <- mappings do
      codes = if source == "receivables", do: context.codes, else: context.payable_codes

      {:ok, _mapping} =
        Sst.map_tax_code(context.operator, 73, %{
          source: source,
          tax_code_id: Map.fetch!(codes, key).id,
          box: box
        })
    end

    context
  end

  @doc "Maps every tax code of the case to its natural box."
  def map_all!(context) do
    map!(context, [
      {"receivables", :goods10, "11b"},
      {"receivables", :goods5, "11a"},
      {"receivables", :services8, "11d"},
      {"receivables", :services6, "11c"},
      {"receivables", :export, "18a"},
      {"payables", :imported8, "11d"},
      {"payables", :schedule_c, "19"}
    ])
  end

  @doc "A line of `price` under the tax code `key` (none for nil)."
  def line(context, price, key \\ nil) do
    base = %{description: "Line", quantity: "1", unit_price: price}
    if key, do: Map.put(base, :tax_code_id, Map.fetch!(context.codes, key).id), else: base
  end

  @doc "Issues an invoice on `date` with `lines`."
  def invoice!(context, date, lines) do
    {:ok, draft} =
      Receivables.create_draft(context.operator, 73, %{
        kind: "invoice",
        series_id: context.invoice_series.id,
        customer_id: context.customer.id,
        issue_date: date,
        lines: lines
      })

    {:ok, invoice} = Receivables.issue_document(context.operator, 73, draft.id)
    invoice
  end

  @doc "Issues a credit note on `date` against `invoice` with `lines`."
  def credit_note!(context, invoice, date, lines) do
    {:ok, draft} =
      Receivables.create_draft(context.operator, 73, %{
        kind: "credit_note",
        series_id: context.credit_series.id,
        customer_id: context.customer.id,
        credited_document_id: invoice.id,
        issue_date: date,
        lines: lines
      })

    {:ok, note} = Receivables.issue_document(context.operator, 73, draft.id)
    note
  end

  @doc "Records a payment of `amount` on `date` against `invoice`."
  def pay!(context, invoice, amount, date) do
    {:ok, payment} =
      Receivables.record_payment(context.operator, 73, %{
        series_id: context.payment_series.id,
        customer_id: context.customer.id,
        payment_date: date,
        amount: amount,
        deposit_account_id: context.accounts.cash.id,
        allocations: [%{document_id: invoice.id, amount: amount}]
      })

    payment
  end

  @doc "Records, approves, and posts a bill of `amount` under the payables tax code `key`."
  def bill!(context, number, date, amount, key) do
    {:ok, bill} =
      Payables.create_bill(context.operator, 73, %{
        party_key: "P-1",
        party_name: "Example Supplier",
        party_document_number: number,
        document_date: date,
        lines: [
          %{
            description: "Line",
            account_id: context.accounts.expense.id,
            amount: amount,
            tax_code_id: Map.fetch!(context.payable_codes, key).id
          }
        ]
      })

    {:ok, _approved} = Payables.approve_document(context.operator, 73, bill.id)
    {:ok, posted} = Payables.post_document(context.operator, 73, bill.id)
    posted
  end

  @doc "Opens the `tax_type` return for the period starting `start`."
  def open!(context, tax_type, start) do
    {:ok, tax_return} =
      Sst.open_return(context.operator, 73, %{tax_type: tax_type, period_start: start})

    tax_return
  end

  @doc "The box `key` of a figures map as `{value, tax}` strings, nil for an absent column."
  def box(figures, key) do
    box = Enum.find(figures.boxes, &(&1.key == key)) || raise "no box #{key}"
    {money(box.taxable_amount), money(box.tax_amount)}
  end

  def money(nil), do: nil
  def money(amount), do: amount |> Decimal.round(2) |> Decimal.to_string()
end
