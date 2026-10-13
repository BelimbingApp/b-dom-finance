defmodule Bilimbi.Finance.Payables.MatchingTest do
  use Bilimbi.Finance.Payables.PayablesCase

  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Finance.Payables.OrderSource
  alias Bilimbi.Finance.Payables.StubOrderSource
  alias Ecto.Adapters.SQL

  @approve_exceptions "finance.payables.match.approve"

  setup do
    StubOrderSource.install!()
    on_exit(&StubOrderSource.uninstall!/0)
    # Order line 10: 10 units at 2.50, all received. Line 11: 4 at 100, 3 received.
    StubOrderSource.put!(%{id: 10, quantity: "10", unit_price: "2.50", received_quantity: "10"})
    StubOrderSource.put!(%{id: 11, quantity: "4", unit_price: "100", received_quantity: "3"})
    :ok
  end

  defp order_line(account, amount, order_line_id, quantity, extra \\ %{}),
    do:
      line(account, amount, Map.merge(%{order_line_id: order_line_id, quantity: quantity}, extra))

  defp approved_bill!(context, number, lines) do
    {:ok, bill} = Payables.create_bill(context.operator, 73, bill("P-1", number, lines))
    {:ok, approved} = Payables.approve_document(context.operator, 73, bill.id)
    approved
  end

  defp approve(context, approver, bill, reason) do
    {:ok, %{match_events: events}} = Payables.get_document(context.operator, 73, bill.id)
    held = events |> Enum.filter(&(&1.event == "held")) |> List.last()

    Payables.approve_match_exception(approver, 73, bill.id, %{
      reason: reason,
      held_event_id: held.id
    })
  end

  defp tolerances!(context, attributes) do
    {:ok, settings} =
      Payables.put_settings(
        context.operator,
        73,
        Map.merge(%{payable_account_id: context.accounts.payable.id}, attributes)
      )

    settings
  end

  describe "recording a bill against order lines" do
    test "keeps each line's order line and quantity, checked with the source", context do
      %{operator: operator, accounts: accounts} = context

      assert {:ok, bill} =
               Payables.create_bill(
                 operator,
                 73,
                 bill("P-1", "INV-1", [
                   order_line(accounts.stock, "25.00", 10, "10"),
                   line(accounts.expense, "5")
                 ])
               )

      assert [%{order_line_id: 10, quantity: quantity}, %{order_line_id: nil, quantity: nil}] =
               bill.lines

      assert decimal?(quantity, 10)
      assert %{match_status: "pending", match_events: []} = bill
      assert {:ok, ^bill} = Payables.get_document(operator, 73, bill.id)

      assert {:ok, %{match_status: nil}} =
               Payables.create_bill(
                 operator,
                 73,
                 bill("P-1", "INV-2", [line(accounts.expense, "5")])
               )
    end

    test "refuses a quantity without an order line, an order line without a quantity, or an unknown line",
         context do
      %{operator: operator, accounts: accounts} = context

      for {bad, field, message} <- [
            {line(accounts.stock, "1", %{quantity: "1"}), :order_line_id,
             "is needed with a quantity"},
            {line(accounts.stock, "1", %{order_line_id: 10}), :quantity,
             "is needed with an order line"},
            {order_line(accounts.stock, "1", 10, "0"), :quantity, "must be greater than 0"},
            {order_line(accounts.stock, "1", 10, "1.00001"), :quantity,
             "has more than 4 decimal places"},
            {order_line(accounts.stock, "1", 999, "1"), :order_line_id,
             "is not an order line of this company in the order source"}
          ] do
        assert {:error, changeset} =
                 Payables.create_bill(operator, 73, bill("P-1", "INV-1", [bad]))

        assert %{lines: [%{^field => [^message]}]} = errors_on(changeset)
      end
    end

    test "refuses an order line when no source is installed", context do
      %{operator: operator, accounts: accounts} = context
      StubOrderSource.uninstall!()
      refute OrderSource.available?()

      assert {:error, changeset} =
               Payables.create_bill(
                 operator,
                 73,
                 bill("P-1", "INV-1", [order_line(accounts.stock, "1", 10, "1")])
               )

      assert %{lines: [%{order_line_id: ["names no installed order source"]}]} =
               errors_on(changeset)

      assert {:ok, _plain} =
               Payables.create_bill(
                 operator,
                 73,
                 bill("P-1", "INV-1", [line(accounts.stock, "1")])
               )
    end

    test "passes on the source refusing the actor", context do
      %{operator: operator, accounts: accounts} = context
      StubOrderSource.refuse!(91)

      assert {:error, {:order_source, :unauthorized}} =
               Payables.create_bill(
                 operator,
                 73,
                 bill("P-1", "INV-1", [order_line(accounts.stock, "1", 10, "1")])
               )
    end
  end

  describe "posting within tolerance" do
    test "posts a bill that matches exactly and records the figures compared", context do
      %{operator: operator, accounts: accounts} = context
      bill = approved_bill!(context, "INV-1", [order_line(accounts.stock, "25.00", 10, "10")])

      assert {:ok, posted} = Payables.post_document(operator, 73, bill.id)
      assert %{status: "posted", document_number: 1, match_status: "matched"} = posted

      assert [
               %{
                 event: "posted",
                 reason: nil,
                 actor_user_id: 91,
                 actor_impersonator_id: nil,
                 occurred_at: %DateTime{},
                 lines: [match_line]
               }
             ] = posted.match_events

      assert %{
               line_number: 1,
               order_line_id: 10,
               order_number: 1,
               exceptions: [],
               quantity_tolerance_kind: nil,
               price_tolerance_kind: nil
             } = match_line

      assert decimal?(match_line.billed_quantity, 10)
      assert decimal?(match_line.billed_unit_price, "2.5")
      assert decimal?(match_line.previously_billed_quantity, 0)
      assert decimal?(match_line.ordered_quantity, 10)
      assert decimal?(match_line.ordered_unit_price, "2.5")
      assert decimal?(match_line.received_quantity, 10)
      assert {:ok, %{10 => billed}} = Payables.billed_quantities(operator, 73, [10])
      assert decimal?(billed, 10)
    end

    test "allows a quantity and price within the company's tolerances", context do
      %{operator: operator, accounts: accounts} = context

      tolerances!(context, %{
        quantity_tolerance_kind: "percent",
        quantity_tolerance: "10",
        price_tolerance_kind: "amount",
        price_tolerance: "0.05"
      })

      StubOrderSource.put!(%{id: 10, quantity: "10", unit_price: "2.50", received_quantity: "11"})
      # 11 units at 2.55: one over on 10 ordered (10%), 0.05 over per unit.
      bill = approved_bill!(context, "INV-1", [order_line(accounts.stock, "28.05", 10, "11")])

      assert {:ok, %{status: "posted", match_status: "matched"} = posted} =
               Payables.post_document(operator, 73, bill.id)

      assert [%{lines: [%{quantity_tolerance_kind: "percent", exceptions: []} = line]}] =
               posted.match_events

      assert decimal?(line.quantity_tolerance, 10) and decimal?(line.price_tolerance, "0.05")
    end

    test "posts a bill without order lines as before, with no match", context do
      %{operator: operator, accounts: accounts} = context
      bill = approved_bill!(context, "INV-1", [line(accounts.expense, "7")])

      assert {:ok, %{status: "posted", match_status: nil, match_events: []}} =
               Payables.post_document(operator, 73, bill.id)
    end
  end

  describe "holding a bill outside tolerance" do
    test "holds the bill with each exception and its reason, and posts nothing", context do
      %{operator: operator, accounts: accounts} = context
      # 12 billed on 10 ordered and received, at 3.00 against 2.50.
      bill = approved_bill!(context, "INV-1", [order_line(accounts.stock, "36.00", 10, "12")])

      assert {:ok, held} = Payables.post_document(operator, 73, bill.id)
      assert %{status: "held", document_number: nil, match_status: "held", entry_id: nil} = held

      assert [%{event: "held", actor_user_id: 91, lines: [match_line]}] = held.match_events

      assert [
               %{code: "quantity_exceeds_ordered", detail: ordered_detail},
               %{code: "quantity_exceeds_received", detail: received_detail},
               %{code: "price_differs", detail: price_detail}
             ] = match_line.exceptions

      assert ordered_detail == "12 billed in all against 10 ordered"
      assert received_detail == "12 billed against 10 received and not yet billed"
      assert price_detail == "3 per unit billed against 2.5 ordered"

      assert {:ok, []} = Ledger.list_entries(operator, 73)
      assert {:ok, %{}} = Payables.billed_quantities(operator, 73, [10])
      assert {:ok, [%{id: id}]} = Payables.list_documents(operator, 73, status: "held")
      assert id == bill.id
    end

    test "names the tolerance a figure fell outside of", context do
      %{operator: operator, accounts: accounts} = context
      tolerances!(context, %{quantity_tolerance_kind: "amount", quantity_tolerance: "1"})
      bill = approved_bill!(context, "INV-1", [order_line(accounts.stock, "30.00", 10, "12")])

      assert {:ok, %{match_events: [%{lines: [%{exceptions: exceptions}]}]}} =
               Payables.post_document(operator, 73, bill.id)

      assert [
               %{
                 code: "quantity_exceeds_ordered",
                 detail: "12 billed in all against 10 ordered, within 1"
               },
               %{code: "quantity_exceeds_received"}
             ] = exceptions
    end

    test "counts what other posted bills billed on the same order line", context do
      %{operator: operator, accounts: accounts} = context
      first = approved_bill!(context, "INV-1", [order_line(accounts.stock, "15.00", 10, "6")])
      {:ok, %{status: "posted"}} = Payables.post_document(operator, 73, first.id)

      # 6 of the 10 received are billed; 5 more exceed what is left.
      second = approved_bill!(context, "INV-2", [order_line(accounts.stock, "12.50", 10, "5")])
      assert {:ok, held} = Payables.post_document(operator, 73, second.id)
      assert %{status: "held", match_events: [%{lines: [match_line]}]} = held
      assert decimal?(match_line.previously_billed_quantity, 6)

      assert [
               %{code: "quantity_exceeds_ordered"},
               %{
                 code: "quantity_exceeds_received",
                 detail: "5 billed against 4 received and not yet billed"
               }
             ] = match_line.exceptions

      third = approved_bill!(context, "INV-3", [order_line(accounts.stock, "10.00", 10, "4")])
      assert {:ok, %{status: "posted"}} = Payables.post_document(operator, 73, third.id)
      assert {:ok, %{10 => billed}} = Payables.billed_quantities(operator, 73, [10])
      assert decimal?(billed, 10)
    end

    test "counts the bill's own earlier lines naming the same order line", context do
      %{operator: operator, accounts: accounts} = context

      split =
        approved_bill!(context, "INV-1", [
          order_line(accounts.stock, "15.00", 10, "6"),
          order_line(accounts.stock, "15.00", 10, "6")
        ])

      assert {:ok, %{status: "held", match_events: [%{lines: [first, second]}]}} =
               Payables.post_document(operator, 73, split.id)

      assert first.exceptions == []
      assert decimal?(second.previously_billed_quantity, 6)

      assert [
               %{code: "quantity_exceeds_ordered", detail: "12 billed in all against 10 ordered"},
               %{
                 code: "quantity_exceeds_received",
                 detail: "6 billed against 4 received and not yet billed"
               }
             ] = second.exceptions

      fits =
        approved_bill!(context, "INV-2", [
          order_line(accounts.stock, "15.00", 10, "6"),
          order_line(accounts.stock, "10.00", 10, "4")
        ])

      assert {:ok, %{status: "posted", match_status: "matched"}} =
               Payables.post_document(operator, 73, fits.id)
    end

    test "holds on a received quantity short of the bill, a closed or replaced line, or another currency",
         context do
      %{operator: operator, accounts: accounts} = context

      StubOrderSource.put!(%{
        id: 12,
        quantity: "5",
        unit_price: "1",
        received_quantity: "5",
        order_status: "cancelled"
      })

      StubOrderSource.put!(%{
        id: 13,
        quantity: "5",
        unit_price: "1",
        received_quantity: "5",
        superseded_by_amendment_id: 3
      })

      StubOrderSource.put!(%{
        id: 14,
        quantity: "5",
        unit_price: "1",
        received_quantity: "5",
        currency_code: "XXX"
      })

      bill =
        approved_bill!(context, "INV-1", [
          order_line(accounts.stock, "400", 11, "4"),
          order_line(accounts.stock, "5", 12, "5"),
          order_line(accounts.stock, "5", 13, "5"),
          order_line(accounts.stock, "5", 14, "5")
        ])

      assert {:ok, %{status: "held", match_events: [%{lines: lines}]}} =
               Payables.post_document(operator, 73, bill.id)

      assert [
               [
                 %{
                   code: "quantity_exceeds_received",
                   detail: "4 billed against 3 received and not yet billed"
                 }
               ],
               [%{code: "order_not_open", detail: "order 1 is cancelled, not open to billing"}],
               [%{code: "order_line_superseded"}],
               [%{code: "currency_mismatch", detail: "the order is in XXX, the book in XTS"}]
             ] = Enum.map(lines, & &1.exceptions)
    end

    test "holds when the source no longer knows the line or is gone", context do
      %{operator: operator, accounts: accounts} = context

      bill =
        approved_bill!(context, "INV-1", [
          order_line(accounts.stock, "25.00", 10, "10"),
          order_line(accounts.stock, "300", 11, "3")
        ])

      StubOrderSource.put!(%{id: 10, company_id: 74, quantity: "10", unit_price: "2.50"})

      assert {:ok, %{status: "held", match_events: [%{lines: lines}]}} =
               Payables.post_document(operator, 73, bill.id)

      assert [
               %{ordered_quantity: nil, exceptions: [%{code: "order_line_not_found"}]},
               %{exceptions: []}
             ] = lines

      StubOrderSource.uninstall!()

      assert {:ok, %{status: "held", match_events: [_, %{lines: lines}]}} =
               Payables.post_document(operator, 73, bill.id)

      assert Enum.all?(lines, &match?([%{code: "order_source_unavailable"}], &1.exceptions))
    end

    test "passes on the source refusing the poster and posts nothing", context do
      %{operator: operator, accounts: accounts} = context
      bill = approved_bill!(context, "INV-1", [order_line(accounts.stock, "25.00", 10, "10")])
      StubOrderSource.refuse!(91)

      assert {:error, {:order_source, :unauthorized}} =
               Payables.post_document(operator, 73, bill.id)

      assert {:ok, %{status: "approved", match_events: []}} =
               Payables.get_document(operator, 73, bill.id)
    end

    test "posts a held bill once the goods arrive, without an approval", context do
      %{operator: operator, accounts: accounts} = context
      bill = approved_bill!(context, "INV-1", [order_line(accounts.stock, "400", 11, "4")])
      assert {:ok, %{status: "held"}} = Payables.post_document(operator, 73, bill.id)

      StubOrderSource.put!(%{id: 11, quantity: "4", unit_price: "100", received_quantity: "4"})

      assert {:ok, %{status: "posted", match_status: "matched"} = posted} =
               Payables.post_document(operator, 73, bill.id)

      assert [%{event: "held"}, %{event: "posted"}] = posted.match_events
    end

    test "can be voided with a reason", context do
      %{operator: operator, accounts: accounts} = context
      bill = approved_bill!(context, "INV-1", [order_line(accounts.stock, "400", 11, "4")])
      {:ok, %{status: "held"}} = Payables.post_document(operator, 73, bill.id)

      assert {:ok, %{status: "voided", match_status: nil}} =
               Payables.void_document(operator, 73, bill.id, %{void_reason: "Wrong order"})
    end
  end

  describe "approving match exceptions" do
    setup context do
      bill =
        approved_bill!(context, "INV-1", [
          order_line(context.accounts.stock, "400", 11, "4")
        ])

      {:ok, %{status: "held"}} = Payables.post_document(context.operator, 73, bill.id)
      %{bill: bill}
    end

    test "needs its own grant, a held bill, and a reason", context do
      %{first_scope: system, operator: operator, bill: bill, accounts: accounts} = context

      assert {:error, changeset} = Payables.approve_match_exception(operator, 73, bill.id, %{})
      assert %{reason: ["can't be blank"]} = errors_on(changeset)

      poster = TestFixtures.sign_in!(system, 73, 97, ["finance.payables.documents.post"])

      assert {:error, :unauthorized} =
               Payables.approve_match_exception(poster, 73, bill.id, %{reason: "Fine"})

      other = approved_bill!(context, "INV-2", [line(accounts.expense, "1")])

      assert {:error, :not_held} =
               Payables.approve_match_exception(operator, 73, other.id, %{reason: "Fine"})

      assert {:error, :document_not_found} =
               Payables.approve_match_exception(operator, 73, -1, %{reason: "Fine"})
    end

    test "names the hold approved, and refuses a hold it did not see", context do
      %{first_scope: system, operator: operator, bill: bill} = context
      approver = TestFixtures.sign_in!(system, 73, 98, [@approve_exceptions])
      {:ok, %{match_events: [%{id: seen}]}} = Payables.get_document(operator, 73, bill.id)

      assert {:ok, %{status: "held"}} = Payables.post_document(operator, 73, bill.id)

      assert {:error, :stale_hold} =
               Payables.approve_match_exception(approver, 73, bill.id, %{
                 reason: "Short",
                 held_event_id: seen
               })

      assert {:error, changeset} =
               Payables.approve_match_exception(approver, 73, bill.id, %{reason: "Short"})

      assert %{held_event_id: ["can't be blank"]} = errors_on(changeset)

      {:ok, %{match_events: [%{id: ^seen}, %{id: current, event: "held"}]}} =
        Payables.get_document(operator, 73, bill.id)

      assert {:ok, %{match_events: [_, _, approval]}} =
               Payables.approve_match_exception(approver, 73, bill.id, %{
                 reason: "Short",
                 held_event_id: current
               })

      assert %{event: "exception_approved", held_event_id: ^current} = approval
    end

    test "records the approver and reason, then posts over the approved exceptions", context do
      %{first_scope: system, operator: operator, bill: bill} = context
      TestFixtures.sign_in!(system, 73, 98, [@approve_exceptions])

      approver =
        Authentication.sign_in(system, 98, 73,
          impersonator_id: 91,
          impersonation_session_id: "borrowed-session"
        )

      assert {:ok, approved} =
               approve(context, approver, bill, " Short delivery agreed with the party ")

      assert %{status: "held", match_status: "exception_approved"} = approved

      assert [
               %{event: "held"},
               %{
                 event: "exception_approved",
                 reason: "Short delivery agreed with the party",
                 actor_user_id: 98,
                 actor_impersonator_id: 91,
                 occurred_at: %DateTime{},
                 lines: []
               }
             ] = approved.match_events

      assert {:error, :already_approved} =
               approve(context, approver, bill, "Again")

      assert {:ok, posted} = Payables.post_document(operator, 73, bill.id)

      assert %{status: "posted", document_number: 1, match_status: "posted_with_exceptions"} =
               posted

      assert [
               _,
               _,
               %{event: "posted", lines: [%{exceptions: [%{code: "quantity_exceeds_received"}]}]}
             ] =
               posted.match_events

      assert {:ok, [%{entry_id: entry_id}]} =
               Payables.list_documents(operator, 73, status: "posted")

      assert {:ok, %{entry_number: 1}} = Ledger.get_entry(operator, 73, entry_id)
      assert {:ok, %{11 => billed}} = Payables.billed_quantities(operator, 73, [11])
      assert decimal?(billed, 4)
    end

    test "holds again on an exception the approval does not cover", context do
      %{first_scope: system, operator: operator, bill: bill} = context
      approver = TestFixtures.sign_in!(system, 73, 98, [@approve_exceptions])

      {:ok, _} =
        approve(context, approver, bill, "Short delivery agreed")

      StubOrderSource.put!(%{
        id: 11,
        quantity: "4",
        unit_price: "100",
        received_quantity: "3",
        order_status: "cancelled"
      })

      assert {:ok, held} = Payables.post_document(operator, 73, bill.id)
      assert %{status: "held", match_status: "held"} = held
      assert [_, _, %{event: "held", lines: [%{exceptions: exceptions}]}] = held.match_events
      assert [%{code: "order_not_open"}, %{code: "quantity_exceeds_received"}] = exceptions

      assert {:ok, %{match_status: "exception_approved"}} =
               approve(context, approver, bill, "Still fine")

      assert {:ok, %{status: "posted", match_status: "posted_with_exceptions"}} =
               Payables.post_document(operator, 73, bill.id)
    end
  end

  describe "an approval covers the figures the approver saw" do
    setup context do
      bill =
        approved_bill!(context, "INV-A", [order_line(context.accounts.stock, "30.00", 10, "12")])

      {:ok, %{status: "held"}} = Payables.post_document(context.operator, 73, bill.id)
      approver = TestFixtures.sign_in!(context.first_scope, 73, 98, [@approve_exceptions])
      %{bill: bill, approver: approver}
    end

    test "holds again when another bill took more of the order line meanwhile", context do
      %{operator: operator, accounts: accounts, bill: bill, approver: approver} = context

      assert {:ok, %{match_status: "exception_approved"}} =
               approve(context, approver, bill, "Over-delivery")

      other = approved_bill!(context, "INV-B", [order_line(accounts.stock, "12.50", 10, "5")])
      assert {:ok, %{status: "posted"}} = Payables.post_document(operator, 73, other.id)

      assert {:ok, held} = Payables.post_document(operator, 73, bill.id)
      assert %{status: "held", match_status: "held"} = held
      assert [_, _, %{event: "held", lines: [match_line]}] = held.match_events
      assert decimal?(match_line.previously_billed_quantity, 5)

      assert [
               %{code: "quantity_exceeds_ordered", detail: ordered},
               %{code: "quantity_exceeds_received"}
             ] =
               match_line.exceptions

      assert ordered == "17 billed in all against 10 ordered"

      assert {:ok, %{match_status: "exception_approved"}} =
               approve(context, approver, bill, "Seen at 17")

      assert {:ok, %{status: "posted", match_status: "posted_with_exceptions"}} =
               Payables.post_document(operator, 73, bill.id)
    end

    test "posts over an approval when the exceptions are the same or smaller", context do
      %{operator: operator, bill: bill, approver: approver} = context

      {:ok, _} =
        approve(context, approver, bill, "Over-delivery")

      assert {:ok, %{status: "posted", match_status: "posted_with_exceptions"}} =
               Payables.post_document(operator, 73, bill.id)
    end

    test "holds again when the price gap widened", context do
      %{operator: operator, accounts: accounts, approver: approver} = context
      bill = approved_bill!(context, "INV-C", [order_line(accounts.stock, "350", 11, "3")])
      {:ok, %{status: "held"}} = Payables.post_document(operator, 73, bill.id)
      {:ok, _} = approve(context, approver, bill, "Dearer")

      StubOrderSource.put!(%{id: 11, quantity: "4", unit_price: "90", received_quantity: "3"})

      assert {:ok, %{status: "held", match_status: "held"}} =
               Payables.post_document(operator, 73, bill.id)
    end

    test "posts over an approval when a shortfall narrowed but remains", context do
      %{operator: operator, accounts: accounts, approver: approver} = context
      bill = approved_bill!(context, "INV-D", [order_line(accounts.stock, "400", 11, "4")])
      {:ok, %{status: "held"}} = Payables.post_document(operator, 73, bill.id)
      {:ok, _} = approve(context, approver, bill, "Short")

      StubOrderSource.put!(%{id: 11, quantity: "4", unit_price: "100", received_quantity: "3.5"})

      assert {:ok, %{status: "posted", match_status: "posted_with_exceptions"}} =
               Payables.post_document(operator, 73, bill.id)
    end
  end

  describe "debit notes against order lines" do
    setup context do
      bill =
        approved_bill!(context, "INV-1", [order_line(context.accounts.stock, "25.00", 10, "10")])

      {:ok, posted} = Payables.post_document(context.operator, 73, bill.id)
      %{bill: posted}
    end

    test "take the quantity back off what is billed, within what the bill billed", context do
      %{operator: operator, accounts: accounts, bill: bill} = context

      assert {:error, changeset} =
               Payables.create_debit_note(operator, 73, bill.id, %{
                 document_date: ~D[2026-10-05],
                 lines: [order_line(accounts.stock, "2.50", 11, "1")]
               })

      assert %{lines: [%{order_line_id: ["is not an order line of the corrected bill"]}]} =
               errors_on(changeset)

      assert {:error, changeset} =
               Payables.create_debit_note(operator, 73, bill.id, %{
                 document_date: ~D[2026-10-05],
                 lines: [order_line(accounts.stock, "25.00", 10, "11")]
               })

      assert %{lines: [%{quantity: ["exceeds the quantity billed on the corrected bill"]}]} =
               errors_on(changeset)

      {:ok, note} =
        Payables.create_debit_note(operator, 73, bill.id, %{
          document_date: ~D[2026-10-05],
          lines: [order_line(accounts.stock, "10.00", 10, "4")]
        })

      # Fits what is owed, but with the first note takes back 11 of the 10 billed.
      {:ok, later} =
        Payables.create_debit_note(operator, 73, bill.id, %{
          document_date: ~D[2026-10-05],
          lines: [order_line(accounts.stock, "14.00", 10, "7")]
        })

      {:ok, _} = Payables.approve_document(operator, 73, note.id)

      assert {:ok, %{status: "posted", match_status: nil}} =
               Payables.post_document(operator, 73, note.id)

      assert {:ok, %{10 => billed}} = Payables.billed_quantities(operator, 73, [10])
      assert decimal?(billed, 6)

      {:ok, _} = Payables.approve_document(operator, 73, later.id)
      assert {:error, :exceeds_billed_quantity} = Payables.post_document(operator, 73, later.id)

      # The quantity taken back is billable again.
      second = approved_bill!(context, "INV-2", [order_line(accounts.stock, "10.00", 10, "4")])
      assert {:ok, %{status: "posted"}} = Payables.post_document(operator, 73, second.id)
    end
  end

  describe "the database" do
    test "keeps match records append-only and whole", context do
      %{operator: operator, accounts: accounts} = context
      bill = approved_bill!(context, "INV-1", [order_line(accounts.stock, "400", 11, "4")])
      {:ok, %{status: "held"}} = Payables.post_document(operator, 73, bill.id)

      for sql <- [
            "UPDATE finance_payables_match_events SET reason = 'x'",
            "DELETE FROM finance_payables_match_events",
            "UPDATE finance_payables_match_lines SET billed_quantity = 1",
            "DELETE FROM finance_payables_match_lines",
            "UPDATE finance_payables_match_exceptions SET code = 'price_differs'",
            "DELETE FROM finance_payables_match_exceptions",
            "TRUNCATE finance_payables_match_exceptions"
          ] do
        assert_raise Postgrex.Error, ~r/finance payables keeps/, fn ->
          SQL.query!(Repo, sql, [])
        end
      end
    end

    test "refuses a hold or an approval out of turn, and a posting of a held bill unapproved",
         context do
      %{operator: operator, accounts: accounts} = context
      bill = approved_bill!(context, "INV-1", [order_line(accounts.stock, "400", 11, "4")])

      {:ok, draft} =
        Payables.create_bill(operator, 73, bill("P-1", "INV-2", [line(accounts.expense, "1")]))

      event = fn document_id, event, reason ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_payables_match_events (tenant_id, company_id, document_id, event, reason, actor_user_id) VALUES (41, 73, $1, $2, $3, 1)",
          [document_id, event, reason]
        )
      end

      assert_raise Postgrex.Error, ~r/no held match exception to approve/, fn ->
        event.(bill.id, "exception_approved", "x")
      end

      assert_raise Postgrex.Error, ~r/only an approved or held bill is matched/, fn ->
        event.(draft.id, "held", nil)
      end

      {:ok, %{status: "held"}} = Payables.post_document(operator, 73, bill.id)

      assert_raise Postgrex.Error, ~r/match exceptions are not approved/, fn ->
        Repo.transaction(fn ->
          event.(bill.id, "posted", nil)

          SQL.query!(
            Repo,
            "INSERT INTO finance_payables_match_lines (tenant_id, company_id, event_id, document_id, line_number, order_line_id, billed_quantity, billed_unit_price, previously_billed_quantity) SELECT 41, 73, max(id), $1, 1, 11, 4, 100, 0 FROM finance_payables_match_events",
            [bill.id]
          )

          SQL.query!(
            Repo,
            "INSERT INTO finance_payables_match_exceptions (tenant_id, company_id, match_line_id, code, detail) SELECT 41, 73, max(id), 'price_differs', 'x' FROM finance_payables_match_lines",
            []
          )

          SQL.query!(
            Repo,
            "UPDATE finance_payables_documents SET status = 'posted', posted_by_user_id = 1, payable_account_id = 1, entry_id = 1, entry_number = 1 WHERE id = $1",
            [bill.id]
          )
        end)
      end
    end

    test "refuses to post a bill naming order lines without its match record", context do
      %{operator: operator, accounts: accounts} = context
      bill = approved_bill!(context, "INV-1", [order_line(accounts.stock, "25.00", 10, "10")])

      assert_raise Postgrex.Error, ~r/posts with its match record/, fn ->
        SQL.query!(
          Repo,
          "UPDATE finance_payables_documents SET status = 'posted', posted_by_user_id = 1, payable_account_id = 1, entry_id = 1, entry_number = 1 WHERE id = $1",
          [bill.id]
        )
      end
    end

    test "keeps the exception codes the match applies" do
      assert Payables.match_exception_codes() ==
               apply(elem(List.last(TestFixtures.migrations()), 1), :exception_codes, [])
    end
  end
end
