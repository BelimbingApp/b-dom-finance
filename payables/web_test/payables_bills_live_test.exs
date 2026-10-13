defmodule BilimbiWeb.PayablesBillsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Payables
  alias Bilimbi.Finance.Payables.OrderSource
  alias Bilimbi.Finance.Payables.StubOrderSource
  alias Bilimbi.Finance.Payables.TestFixtures

  @view "finance.payables.view"
  @approve "finance.payables.documents.approve"
  @post "finance.payables.documents.post"
  @approve_exceptions "finance.payables.match.approve"
  @ledger ~w(finance.ledger.view finance.ledger.entries.post)

  setup do
    signed_in_identity!()
    Ledger.TestFixtures.create_ledger_tables!()
    TestFixtures.create_payables_tables!()
    StubOrderSource.install!()
    on_exit(&StubOrderSource.uninstall!/0)
    {:ok, scope} = Tenancy.scope(41)

    # Another user keeps the books, so the signed-in user 91 holds only what
    # each test grants.
    keeper =
      TestFixtures.sign_in!(
        scope,
        73,
        92,
        Bilimbi.Finance.Payables.PayablesCase.all_capabilities()
      )

    {:ok, _book} = Ledger.open_book(keeper, 73, %{currency_code: "XTS", minor_units: 2})
    Bilimbi.Finance.Ledger.TestFixtures.open_fiscal_years!(keeper, 73)

    accounts =
      for {key, code, type} <-
            [stock: {"1200", "asset"}, payable: {"2000", "liability"}]
            |> Enum.map(fn {key, {code, type}} -> {key, code, type} end),
          into: %{} do
        {:ok, account} =
          Ledger.create_account(keeper, 73, %{
            code: code,
            name: "Account #{code}",
            account_type: type
          })

        {key, account}
      end

    {:ok, _} = Payables.put_settings(keeper, 73, %{payable_account_id: accounts.payable.id})
    StubOrderSource.put!(%{id: 10, quantity: "10", unit_price: "2.50", received_quantity: "10"})
    StubOrderSource.put!(%{id: 11, quantity: "4", unit_price: "100", received_quantity: "3"})
    %{scope: scope, keeper: keeper, accounts: accounts}
  end

  defp bill!(keeper, number, lines) do
    {:ok, bill} =
      Payables.create_bill(keeper, 73, %{
        party_key: "P-1",
        party_name: "Party one",
        party_document_number: number,
        document_date: ~D[2026-10-01],
        lines: lines
      })

    bill
  end

  defp order_line(account, amount, order_line_id, quantity) do
    %{
      description: "Goods",
      account_id: account.id,
      amount: amount,
      order_line_id: order_line_id,
      quantity: quantity
    }
  end

  # Another keeper approves what the keeper records: the company separates
  # duties.
  defp checker! do
    {:ok, scope} = Tenancy.scope(41)
    TestFixtures.sign_in!(scope, 73, 93, Bilimbi.Finance.Payables.PayablesCase.all_capabilities())
  end

  # A bill of 4 units on order line 11, of which 3 were received: held.
  defp held_bill!(keeper, accounts) do
    bill = bill!(keeper, "INV-H", [order_line(accounts.stock, "400", 11, "4")])
    {:ok, _} = Payables.approve_document(checker!(), 73, bill.id)
    {:ok, %{status: "held"}} = Payables.post_document(keeper, 73, bill.id)
    bill
  end

  describe "the list" do
    test "needs the view capability", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               conn |> log_in_as() |> live(~p"/finance/payables/bills")
    end

    test "lists the company's documents with their match status and filters the held ones", %{
      conn: conn,
      keeper: keeper,
      accounts: accounts
    } do
      grant_capabilities!(@view)

      plain =
        bill!(keeper, "INV-1", [%{description: "Fee", account_id: accounts.stock.id, amount: "5"}])

      held = held_bill!(keeper, accounts)

      {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payables/bills")

      assert has_element?(view, "#payables-bill-#{plain.id}", "Party one")
      assert has_element?(view, "#payables-bill-#{plain.id}", "draft")
      assert has_element?(view, "#payables-bill-#{held.id}", "held")
      assert has_element?(view, "#payables-bills-pagination-summary")

      view |> element("#payables-bills-held") |> render_click()
      assert %{"status" => "held"} = patched_params(view)
      refute has_element?(view, "#payables-bill-#{plain.id}")
      assert has_element?(view, "#payables-bill-#{held.id}")

      view
      |> form("#payables-bills-filters", filters: %{status: "", search: "nothing"})
      |> render_change()

      assert has_element?(view, "#payables-bills-table", "No documents match")
    end
  end

  describe "the bill page" do
    test "shows the match exceptions and withholds the actions without the grants", %{
      conn: conn,
      keeper: keeper,
      accounts: accounts
    } do
      grant_capabilities!(@view)
      held = held_bill!(keeper, accounts)

      {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payables/bills/#{held.id}")

      assert has_element?(view, "#payables-bill-match-status", "held")
      assert has_element?(view, "#payables-bill-attention", "nobody has approved")

      assert has_element?(
               view,
               "#payables-exception-1-quantity_exceeds_received",
               "4 billed against 3 received and not yet billed"
             )

      assert has_element?(view, "#payables-line-1", "#11")
      assert has_element?(view, "#payables-match-line-1", "4 at 100")
      assert has_element?(view, "#payables-bill-match-events-table", "held")
      refute has_element?(view, "#payables-bill-post")
      refute has_element?(view, "#payables-bill-open-approve-exception")
      refute has_element?(view, "#payables-bill-open-void")

      {:ok, missing, _html} = conn |> log_in_as() |> live(~p"/finance/payables/bills/0")
      assert has_element?(missing, "#payables-bill-missing")
    end

    test "approves the exceptions with a reason as the signed-in user, then posts", %{
      conn: conn,
      keeper: keeper,
      accounts: accounts
    } do
      grant_capabilities!([@view, @post, @approve_exceptions | @ledger])
      held = held_bill!(keeper, accounts)

      {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payables/bills/#{held.id}")

      view |> element("#payables-bill-open-approve-exception") |> render_click()
      assert has_element?(view, "#payables-bill-approve-exception-modal")

      view
      |> form("#payables-bill-approve-exception-form", dialog: %{reason: "Short delivery agreed"})
      |> render_submit()

      assert has_element?(view, "#flash-success", "approved")
      assert has_element?(view, "#payables-bill-match-status", "exception approved")
      refute has_element?(view, "#payables-bill-open-approve-exception")
      assert has_element?(view, "#payables-bill-match-events-table", "Short delivery agreed")
      assert has_element?(view, "#payables-bill-match-events-table", "User #91")

      view |> element("#payables-bill-post") |> render_click()
      assert has_element?(view, "#flash-success", "Posted as number 1")
      assert has_element?(view, "#payables-bill-match-status", "posted with exceptions")
      refute has_element?(view, "#payables-bill-post")

      assert {:ok, %{status: "posted", match_events: [_, _, %{event: "posted"}]}} =
               Payables.get_document(keeper, 73, held.id)
    end

    test "refuses an approval of a hold recorded after the page loaded", %{
      conn: conn,
      keeper: keeper,
      accounts: accounts
    } do
      grant_capabilities!([@view, @post, @approve_exceptions | @ledger])
      held = held_bill!(keeper, accounts)

      {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payables/bills/#{held.id}")
      view |> element("#payables-bill-open-approve-exception") |> render_click()

      {:ok, %{status: "held"}} = Payables.post_document(keeper, 73, held.id)

      view
      |> form("#payables-bill-approve-exception-form", dialog: %{reason: "Short delivery agreed"})
      |> render_submit()

      assert has_element?(view, "#flash-error", "matched again")
      assert has_element?(view, "#payables-bill-match-status", "held")
      assert has_element?(view, "#payables-bill-open-approve-exception")

      view |> element("#payables-bill-open-approve-exception") |> render_click()

      view
      |> form("#payables-bill-approve-exception-form", dialog: %{reason: "Short delivery agreed"})
      |> render_submit()

      assert has_element?(view, "#flash-success", "approved")
    end

    test "approves a draft and voids a held bill with a reason", %{
      conn: conn,
      keeper: keeper,
      accounts: accounts
    } do
      grant_capabilities!([@view, @approve, "finance.ledger.view"])

      draft =
        bill!(keeper, "INV-1", [%{description: "Fee", account_id: accounts.stock.id, amount: "5"}])

      held = held_bill!(keeper, accounts)

      {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payables/bills/#{draft.id}")
      view |> element("#payables-bill-approve") |> render_click()
      assert has_element?(view, "#flash-success", "approved")
      refute has_element?(view, "#payables-bill-approve")
      assert has_element?(view, "#payables-bill-open-void")

      {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payables/bills/#{held.id}")
      view |> element("#payables-bill-open-void") |> render_click()

      view
      |> form("#payables-bill-void-form", dialog: %{reason: "Wrong order"})
      |> render_submit()

      assert has_element?(view, "#flash-success", "voided")
      assert has_element?(view, "#payables-bill-document-facts", "Wrong order")
      refute has_element?(view, "#payables-bill-match-status")
    end
  end

  describe "separation of duties" do
    test "refuses the exceptions to whoever posted the bill into its hold", %{
      conn: conn,
      keeper: keeper,
      accounts: accounts
    } do
      grant_capabilities!([@view, @post, @approve_exceptions | @ledger])
      held = held_bill!(keeper, accounts)

      {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payables/bills/#{held.id}")

      # Posting a held bill unapproved matches again and holds again.
      view |> element("#payables-bill-post") |> render_click()
      assert has_element?(view, "#flash-warning", "held")
      assert has_element?(view, "#payables-bill-match-status", "held")

      view |> element("#payables-bill-open-approve-exception") |> render_click()

      view
      |> form("#payables-bill-approve-exception-form", dialog: %{reason: "Short delivery agreed"})
      |> render_submit()

      assert has_element?(view, "#flash-error", "separates duties")
      assert has_element?(view, "#payables-bill-match-status", "held")
    end

    test "refuses to let whoever recorded a bill approve it", %{
      conn: conn,
      scope: scope,
      accounts: accounts
    } do
      grant_capabilities!([@view, @approve, "finance.ledger.view"])

      recorder =
        TestFixtures.sign_in!(scope, 73, 91, [
          "finance.payables.documents.create",
          "finance.ledger.view"
        ])

      own =
        bill!(recorder, "INV-O", [
          %{description: "Fee", account_id: accounts.stock.id, amount: "5"}
        ])

      {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payables/bills/#{own.id}")
      view |> element("#payables-bill-approve") |> render_click()

      assert has_element?(view, "#flash-error", "separates duties")
      assert has_element?(view, "#payables-bill-approve")
      assert {:ok, %{status: "draft"}} = Payables.get_document(recorder, 73, own.id)
    end
  end

  # With Supply Chain mounted the installed source answers from the real
  # purchasing and receiving facades; without it this suite proves nothing
  # more and says so.
  if OrderSource.installed() == :unavailable do
    describe "the installed order source" do
      test "is unavailable without Supply Chain, so a bill cannot name an order line", %{
        keeper: keeper,
        accounts: accounts
      } do
        StubOrderSource.uninstall!()

        assert {:error, changeset} =
                 Payables.create_bill(keeper, 73, %{
                   party_key: "P-1",
                   party_name: "Party one",
                   party_document_number: "INV-1",
                   document_date: ~D[2026-10-01],
                   lines: [order_line(accounts.stock, "25", 10, "10")]
                 })

        assert %{lines: [%{order_line_id: ["names no installed order source"]}]} =
                 Bilimbi.Base.Database.TestHelpers.errors_on(changeset)
      end
    end
  else
    describe "the installed order source" do
      test "matches a bill against a real order and its posted receipt", %{
        scope: scope,
        keeper: keeper,
        accounts: accounts
      } do
        StubOrderSource.uninstall!()
        {:ok, %{purchasing: purchasing, receiving: receiving}} = OrderSource.facades()
        purchasing_fixtures = Module.concat(purchasing, TestFixtures)
        receiving_fixtures = Module.concat(receiving, TestFixtures)
        apply(purchasing_fixtures, :create_purchasing_tables!, [])
        apply(receiving_fixtures, :create_receiving_tables!, [])

        purchasing_capabilities = apply(purchasing_fixtures, :all_capabilities, [])
        receiving_capabilities = apply(receiving_fixtures, :all_capabilities, [])
        buyer = TestFixtures.sign_in!(scope, 73, 93, purchasing_capabilities)
        approver = TestFixtures.sign_in!(scope, 73, 94, purchasing_capabilities)

        storekeeper =
          TestFixtures.sign_in!(scope, 73, 95, receiving_capabilities ++ purchasing_capabilities)

        # The bookkeeper reads orders and receipts through the source.
        {:ok, _} =
          Bilimbi.Base.Authz.put_principal_capability(
            scope,
            73,
            :user,
            92,
            apply(purchasing, :view_capability, []),
            true
          )

        {:ok, _} =
          Bilimbi.Base.Authz.put_principal_capability(
            scope,
            73,
            :user,
            92,
            apply(receiving, :view_capability, []),
            true
          )

        order =
          apply(receiving_fixtures, :sent_order!, [
            buyer,
            approver,
            73,
            [
              apply(purchasing_fixtures, :line, [
                %{description: "Bolts", quantity: "10", unit: "box", unit_price: "2.50"}
              ])
            ]
          ])

        [bolts] = order.lines

        {:ok, receipt} =
          apply(receiving, :create_receipt, [
            storekeeper,
            73,
            %{
              order_id: order.id,
              received_on: ~D[2026-10-01],
              lines: [%{order_line_id: bolts.id, received_quantity: "6"}]
            }
          ])

        {:ok, _} = apply(receiving, :post_receipt, [storekeeper, 73, receipt.id])

        # 8 billed against 6 received: held, with the real figures.
        bill = bill!(keeper, "INV-R", [order_line(accounts.stock, "20.00", bolts.id, "8")])
        {:ok, _} = Payables.approve_document(checker!(), 73, bill.id)
        assert {:ok, held} = Payables.post_document(keeper, 73, bill.id)
        assert %{status: "held", match_events: [%{lines: [match_line]}]} = held
        assert Decimal.equal?(match_line.ordered_quantity, 10)
        assert Decimal.equal?(match_line.received_quantity, 6)
        assert match_line.order_number == order.order_number
        assert [%{code: "quantity_exceeds_received"}] = match_line.exceptions

        {:ok, receipt} =
          apply(receiving, :create_receipt, [
            storekeeper,
            73,
            %{
              order_id: order.id,
              received_on: ~D[2026-10-02],
              lines: [%{order_line_id: bolts.id, received_quantity: "4"}]
            }
          ])

        {:ok, _} = apply(receiving, :post_receipt, [storekeeper, 73, receipt.id])

        assert {:ok, %{status: "posted", match_status: "matched"}} =
                 Payables.post_document(keeper, 73, bill.id)

        assert {:ok, %{^bolts_id => billed}} =
                 Payables.billed_quantities(keeper, 73, [bolts_id = bolts.id])

        assert Decimal.equal?(billed, 8)
      end
    end
  end
end
