defmodule Bilimbi.Finance.Payroll.PageFixtures do
  @moduledoc """
  A company with a ledger book, a chart, the posting accounts and mappings,
  and the stub source installed, for the payroll pages' tests in
  `web_test/`: user 92 holds every capability and sets the scene; the
  signed-in user 91 holds only what each test grants. Compiled with the
  module's test support so the web tests need no `Code.require_file`.
  """

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Payroll.PayrollCase
  alias Bilimbi.Finance.Payroll.StubPeopleSource
  alias Bilimbi.Finance.Payroll.TestFixtures

  @view "finance.payroll.view"
  @manage "finance.payroll.settings.manage"
  @post "finance.payroll.postings.post"
  @ledger ~w(finance.ledger.view finance.ledger.entries.post)

  def view_capability, do: @view
  def manage_capability, do: @manage
  def post_capability, do: @post
  def ledger_capabilities, do: @ledger

  @doc "The scene: see the moduledoc. `configured: false` leaves the accounts and mappings unset."
  def setup_scene!(options \\ []) do
    LedgerFixtures.create_ledger_tables!()
    TestFixtures.create_payroll_tables!()
    StubPeopleSource.install!()
    {:ok, scope} = Tenancy.scope(41)
    operator = TestFixtures.sign_in!(scope, 73, 92, PayrollCase.all_capabilities())
    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})
    Bilimbi.Finance.Ledger.TestFixtures.open_fiscal_years!(operator, 73)

    context =
      PayrollCase.setup_accounts!(%{first_scope: scope, operator: operator})

    context =
      if Keyword.get(options, :configured, true),
        do: PayrollCase.configure!(context),
        else: context

    Map.put(context, :scope, scope)
  end
end
