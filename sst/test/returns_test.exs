defmodule Bilimbi.Finance.Sst.ReturnsTest do
  use Bilimbi.Finance.Sst.SstCase

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  @january ~D[2026-01-01]

  describe "figures" do
    test "a sales tax return counts posted documents by rate, nets credit notes, and deducts earlier ones",
         context do
      context = map_all!(context)

      december = invoice!(context, ~D[2025-12-15], [line(context, "500", :goods10)])

      january =
        invoice!(context, ~D[2026-01-10], [
          line(context, "1000", :goods10),
          line(context, "200", :goods5),
          line(context, "300", :export),
          line(context, "70")
        ])

      _same_period =
        credit_note!(context, january, ~D[2026-02-01], [line(context, "100", :goods10)])

      _earlier = credit_note!(context, december, ~D[2026-02-02], [line(context, "50", :goods10)])
      _service = invoice!(context, ~D[2026-01-11], [line(context, "400", :services8)])
      _schedule_c = bill!(context, "B-1", ~D[2026-01-20], "400", :schedule_c)
      _march = invoice!(context, ~D[2026-03-01], [line(context, "999", :goods10)])

      assert {:ok, figures} =
               Sst.preview_return(context.operator, 73, %{
                 tax_type: "sales_tax",
                 period_start: @january
               })

      assert %{period_start: @january, period_end: ~D[2026-02-28], currency_code: "XTS"} =
               figures

      assert box(figures, "11a") == {"200.00", "10.00"}
      assert box(figures, "11b") == {"900.00", "90.00"}
      assert box(figures, "12") == {nil, "100.00"}
      assert box(figures, "13a") == {nil, "5.00"}
      assert box(figures, "14") == {nil, "95.00"}
      assert box(figures, "18a") == {"300.00", nil}
      assert box(figures, "19") == {"400.00", nil}
      assert money(figures.tax_payable) == "95.00"
      assert figures.unmapped == [] and figures.rate_mismatches == []

      # Every row read says where it went and what it added.
      assert %{box: "13a", document_kind: "credit_note", prior_period: true} =
               Enum.find(figures.sources, &(&1.box == "13a"))

      refute Enum.any?(figures.sources, &(&1.tax_code == "S8"))

      # The documents' tax agrees with the sales tax account's postings.
      assert [%{account_code: "1300"} = input, %{account_code: "2100"} = sales] =
               figures.accounts

      assert {money(sales.document_credits), money(sales.document_debits)} == {"110.00", "15.00"}
      assert {money(sales.ledger_credits), money(sales.ledger_debits)} == {"110.00", "15.00"}
      assert money(sales.difference) == "0.00"
      assert money(input.difference) == "0.00"
    end

    test "a ledger posting to a tax account no document explains shows as a difference",
         context do
      context = map_all!(context)
      _invoice = invoice!(context, ~D[2026-01-10], [line(context, "1000", :goods10)])

      {:ok, _entry} =
        Ledger.post_entry(context.operator, 73, %{
          entry_date: ~D[2026-02-15],
          description: "Sales tax paid",
          lines: [
            %{account_id: context.accounts.sales_tax.id, debit: "60"},
            %{account_id: context.accounts.cash.id, credit: "60"}
          ]
        })

      assert {:ok, figures} =
               Sst.preview_return(context.operator, 73, %{
                 tax_type: "sales_tax",
                 period_start: @january
               })

      sales = Enum.find(figures.accounts, &(&1.account_code == "2100"))
      assert {money(sales.ledger_debits), money(sales.difference)} == {"60.00", "-60.00"}
      assert box(figures, "14") == {nil, "100.00"}
    end

    test "service tax counts what was received, or what was invoiced on the invoice basis",
         context do
      context = map_all!(context)

      invoice =
        invoice!(context, ~D[2026-01-05], [
          line(context, "1000", :services8),
          line(context, "500", :services6)
        ])

      # Total 1,610.00; half is paid in the period.
      _payment = pay!(context, invoice, "805", ~D[2026-02-10])
      _imported = bill!(context, "B-1", ~D[2026-01-20], "200", :imported8)

      attributes = %{tax_type: "service_tax", period_start: @january}
      assert {:ok, received} = Sst.preview_return(context.operator, 73, attributes)

      assert received.service_tax_basis == "payment"
      assert box(received, "11c") == {"250.00", "15.00"}
      assert box(received, "11d") == {"700.00", "56.00"}
      assert box(received, "14") == {nil, "71.00"}

      assert Enum.any?(received.sources, &(&1.measure == "received" and &1.box == "11d"))

      # The ledger reconciliation still compares documents with postings.
      service = Enum.find(received.accounts, &(&1.account_code == "2200"))
      assert money(service.document_credits) == "110.00"
      assert money(service.document_debits) == "16.00"
      assert money(service.difference) == "0.00"

      {:ok, _version} = Sst.register(context.operator, 73, %{service_tax_basis: "invoice"})
      assert {:ok, invoiced} = Sst.preview_return(context.operator, 73, attributes)

      assert invoiced.service_tax_basis == "invoice"
      assert box(invoiced, "11c") == {"500.00", "30.00"}
      assert box(invoiced, "11d") == {"1200.00", "96.00"}
    end

    test "a reading pins to ledger entry and mapping numbers", context do
      context = map_all!(context)
      _first = invoice!(context, ~D[2026-01-10], [line(context, "1000", :goods10)])

      attributes = %{tax_type: "sales_tax", period_start: @january}
      {:ok, before} = Sst.preview_return(context.operator, 73, attributes)

      _later = invoice!(context, ~D[2026-01-11], [line(context, "500", :goods10)])
      map!(context, [{"receivables", :goods10, "11a"}])

      assert {:ok, pinned} =
               Sst.preview_return(context.operator, 73, attributes,
                 through_entry_number: before.through_entry_number,
                 through_mapping_number: before.through_mapping_number
               )

      assert pinned.boxes == before.boxes
      assert {:ok, now} = Sst.preview_return(context.operator, 73, attributes)
      assert box(now, "11a") == {"1500.00", "150.00"}

      assert {:error, :invalid_option} =
               Sst.preview_return(context.operator, 73, attributes, at: 1)
    end
  end

  describe "opening" do
    test "a return opens for a taxable period of a registered tax, one at a time", context do
      %{operator: operator} = context

      assert %{
               return_number: 1,
               status: "open",
               tax_type: "sales_tax",
               period_start: @january,
               period_end: ~D[2026-02-28],
               due_date: ~D[2026-03-31],
               version: nil,
               events: [%{action: "opened", recorded_by_user_id: 91}]
             } = open!(context, "sales_tax", @january)

      assert {:error, :return_open} =
               Sst.open_return(operator, 73, %{tax_type: "sales_tax", period_start: @january})

      # The other tax's return of the same period is its own.
      assert %{return_number: 2} = open!(context, "service_tax", "2026-01-01")

      assert {:error, :not_a_taxable_period} =
               Sst.open_return(operator, 73, %{
                 tax_type: "sales_tax",
                 period_start: ~D[2026-02-01]
               })

      assert {:error, :not_registered} =
               Sst.open_return(operator, 73, %{
                 tax_type: "sales_tax",
                 period_start: ~D[2025-11-01]
               })

      assert {:error, :invalid_tax_type} =
               Sst.open_return(operator, 73, %{tax_type: "vat", period_start: @january})

      {:ok, _} = Sst.register(operator, 73, %{service_tax_number: ""})

      assert {:error, :not_registered_for_tax} =
               Sst.open_return(operator, 73, %{
                 tax_type: "service_tax",
                 period_start: ~D[2026-03-01]
               })
    end

    test "needs the prepare capability", context do
      viewer =
        TestFixtures.sign_in!(
          context.first_scope,
          73,
          93,
          ["finance.sst.view" | reading_capabilities()]
        )

      assert {:error, :unauthorized} =
               Sst.open_return(viewer, 73, %{tax_type: "sales_tax", period_start: @january})
    end
  end

  describe "adjustments" do
    test "add to an open return's box and are withdrawn on record, never deleted", context do
      context = map_all!(context)
      %{operator: operator} = context
      _invoice = invoice!(context, ~D[2026-01-10], [line(context, "1000", :goods10)])
      tax_return = open!(context, "sales_tax", @january)

      assert {:ok, relief} =
               Sst.add_adjustment(operator, 73, tax_return.id, %{
                 box: "13d",
                 tax_amount: "7.00",
                 description: "Bad debt relief approved",
                 reference: "INV-0001"
               })

      assert %{adjustment_number: 1, action: "added", taxable_amount: zero} = relief
      assert Decimal.equal?(zero, 0)

      {:ok, own_use} =
        Sst.add_adjustment(operator, 73, tax_return.id, %{
          box: "11b",
          taxable_amount: "50",
          tax_amount: "5",
          description: "Goods taken for own use"
        })

      assert {:ok, report} = Sst.get_return(operator, 73, tax_return.id)
      assert box(report.figures, "11b") == {"1050.00", "105.00"}
      assert box(report.figures, "14") == {nil, "98.00"}

      assert {:error, changeset} =
               Sst.add_adjustment(operator, 73, tax_return.id, %{
                 box: "12",
                 tax_amount: "1",
                 description: "Totals are computed"
               })

      assert %{box: ["is not a box of this return a preparer adjusts"]} = errors_on(changeset)

      assert {:error, changeset} =
               Sst.add_adjustment(operator, 73, tax_return.id, %{
                 box: "13d",
                 taxable_amount: "10",
                 tax_amount: "1.005",
                 description: ""
               })

      assert %{taxable_amount: [_], tax_amount: [_], description: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               Sst.withdraw_adjustment(operator, 73, own_use.id, %{reason: ""})

      assert %{description: [_]} = errors_on(changeset)

      assert {:ok, %{action: "withdrawn", withdraws_adjustment_id: withdrawn}} =
               Sst.withdraw_adjustment(operator, 73, own_use.id, %{reason: "Counted twice"})

      assert withdrawn == own_use.id

      assert {:error, :adjustment_withdrawn} =
               Sst.withdraw_adjustment(operator, 73, own_use.id, %{reason: "Again"})

      assert {:ok, report} = Sst.get_return(operator, 73, tax_return.id)
      assert box(report.figures, "11b") == {"1000.00", "100.00"}

      assert [%{standing: true}, %{standing: false, withdrawal: %{description: "Counted twice"}}] =
               report.adjustments
    end
  end

  describe "finalising" do
    test "freezes the figures read now with the numbers that reproduce them", context do
      context = map_all!(context)
      %{operator: operator} = context
      _invoice = invoice!(context, ~D[2026-01-10], [line(context, "1000", :goods10)])
      tax_return = open!(context, "sales_tax", @january)

      {:ok, _relief} =
        Sst.add_adjustment(operator, 73, tax_return.id, %{
          box: "13d",
          tax_amount: "7",
          description: "Bad debt relief approved"
        })

      assert {:ok, %{status: "finalised", version: 1, tax_payable: payable}} =
               Sst.finalise_return(operator, 73, tax_return.id)

      assert money(payable) == "93.00"

      assert {:ok, report} = Sst.get_return(operator, 73, tax_return.id)

      assert [%{action: "opened"}, %{action: "finalised", recorded_by_user_id: 91} = event] =
               report.events

      assert event.through_entry_number == report.figures.through_entry_number
      assert box(report.figures, "11b") == {"1000.00", "100.00"}
      assert report.posted_since == %{through_entry_number: event.through_entry_number, boxes: []}

      # A document posted later into the period, and a later mapping,
      # change nothing finalised; the return says what they would change.
      _late = invoice!(context, ~D[2026-02-20], [line(context, "200", :goods10)])
      map!(context, [{"receivables", :goods10, "11a"}])

      assert {:ok, again} = Sst.get_return(operator, 73, tax_return.id)
      assert again.figures == report.figures

      assert [%{key: "11b", taxable_change: taxable, tax_change: tax} | _] =
               again.posted_since.boxes

      assert {money(taxable), money(tax)} == {"200.00", "20.00"}

      assert {:ok, %{reproduced: true}} = Sst.reproduce_return(operator, 73, tax_return.id)

      # The snapshot reads with the SST grant alone; what posted since needs
      # the documents' grants.
      viewer = TestFixtures.sign_in!(context.first_scope, 73, 93, ["finance.sst.view"])

      assert {:ok, %{figures: figures, posted_since: nil}} =
               Sst.get_return(viewer, 73, tax_return.id)

      assert figures == report.figures

      assert {:error, :return_finalised} =
               Sst.add_adjustment(operator, 73, tax_return.id, %{
                 box: "13d",
                 tax_amount: "1",
                 description: "Late"
               })

      assert {:error, :return_finalised} = Sst.finalise_return(operator, 73, tax_return.id)

      assert {:error, :return_finalised} =
               Sst.discard_return(operator, 73, tax_return.id, %{reason: "No"})

      assert {:error, :return_finalised} =
               Sst.open_return(operator, 73, %{tax_type: "sales_tax", period_start: @january})
    end

    test "is refused while a tax code is unmapped or mapped to a box of another rate", context do
      %{operator: operator} = context
      _invoice = invoice!(context, ~D[2026-01-10], [line(context, "1000", :goods10)])
      tax_return = open!(context, "sales_tax", @january)

      assert {:error, {:unmapped_tax_codes, [%{source: "receivables", tax_code: "G10"}]}} =
               Sst.finalise_return(operator, 73, tax_return.id)

      map!(context, [{"receivables", :goods10, "11a"}])

      assert {:error, {:rate_mismatch, [%{tax_code: "G10", box: "11a"}]}} =
               Sst.finalise_return(operator, 73, tax_return.id)

      map!(context, [{"receivables", :goods10, nil}])
      assert {:ok, %{status: "finalised"}} = Sst.finalise_return(operator, 73, tax_return.id)

      assert {:ok, report} = Sst.get_return(operator, 73, tax_return.id)
      assert box(report.figures, "14") == {nil, "0.00"}
      assert [%{box: nil, tax_code: "G10"}] = report.figures.sources
    end

    test "waits for the period to end", context do
      tax_return = open!(context, "sales_tax", ~D[2099-01-01])

      assert {:error, :period_not_ended} =
               Sst.finalise_return(context.operator, 73, tax_return.id)
    end

    test "needs the finalise capability and the sources' view grants", context do
      tax_return = open!(context, "sales_tax", @january)

      preparer =
        TestFixtures.sign_in!(
          context.first_scope,
          73,
          93,
          ["finance.sst.returns.sst-prepare" | reading_capabilities()]
        )

      assert {:error, :unauthorized} = Sst.finalise_return(preparer, 73, tax_return.id)

      finaliser =
        TestFixtures.sign_in!(context.first_scope, 73, 94, [
          "finance.sst.returns.sst-finalise",
          "finance.ledger.view"
        ])

      assert {:error, :unauthorized} = Sst.finalise_return(finaliser, 73, tax_return.id)
    end

    test "the database keeps finalised returns and their rows as they are", context do
      context = map_all!(context)
      _invoice = invoice!(context, ~D[2026-01-10], [line(context, "1000", :goods10)])
      tax_return = open!(context, "sales_tax", @january)
      {:ok, _} = Sst.finalise_return(context.operator, 73, tax_return.id)

      for sql <- [
            "UPDATE finance_sst_return_boxes SET tax_amount = 0",
            "DELETE FROM finance_sst_return_events",
            "UPDATE finance_sst_returns SET period_end = '2026-03-31'",
            "DELETE FROM finance_sst_registrations"
          ] do
        assert_raise Postgrex.Error, ~r/finance sst keeps/, fn ->
          Repo.transaction(fn -> SQL.query!(Repo, sql, []) end)
        end
      end
    end
  end

  describe "amending" do
    test "a finalised return is amended by a new version that names it", context do
      context = map_all!(context)
      %{operator: operator} = context
      _invoice = invoice!(context, ~D[2026-01-10], [line(context, "1000", :goods10)])
      original = open!(context, "sales_tax", @january)

      {:ok, _relief} =
        Sst.add_adjustment(operator, 73, original.id, %{
          box: "13d",
          tax_amount: "7",
          description: "Bad debt relief approved"
        })

      {:ok, _} = Sst.finalise_return(operator, 73, original.id)
      _late = invoice!(context, ~D[2026-02-20], [line(context, "200", :goods10)])

      assert {:error, changeset} = Sst.amend_return(operator, 73, original.id, %{reason: " "})
      assert %{reason: [_]} = errors_on(changeset)

      assert {:ok, amendment} =
               Sst.amend_return(operator, 73, original.id, %{reason: "Invoice found late"})

      assert %{status: "open", amends_return_id: amends, reason: "Invoice found late"} = amendment
      assert amends == original.id

      assert {:error, :return_open} =
               Sst.amend_return(operator, 73, original.id, %{reason: "Twice"})

      assert {:ok, report} = Sst.get_return(operator, 73, amendment.id)

      assert [%{description: "Bad debt relief approved", copied_from_adjustment_id: copied}] =
               report.adjustments

      assert copied != nil
      assert box(report.figures, "11b") == {"1200.00", "120.00"}

      assert %{version: 1, boxes: changes} = report.amends
      assert %{taxable_change: taxable, tax_change: tax} = Enum.find(changes, &(&1.key == "11b"))
      assert {money(taxable), money(tax)} == {"200.00", "20.00"}

      assert {:ok, %{version: 2}} = Sst.finalise_return(operator, 73, amendment.id)

      assert {:ok, [%{superseded_by_return_id: superseded}, %{version: 2}]} =
               Sst.list_returns(operator, 73, tax_type: "sales_tax")

      assert superseded == amendment.id

      assert {:error, :return_superseded} =
               Sst.amend_return(operator, 73, original.id, %{reason: "Old version"})
    end

    test "needs the amend capability", context do
      tax_return = open!(context, "sales_tax", @january)
      {:ok, _} = Sst.finalise_return(context.operator, 73, tax_return.id)

      preparer =
        TestFixtures.sign_in!(
          context.first_scope,
          73,
          93,
          ["finance.sst.returns.sst-prepare" | reading_capabilities()]
        )

      assert {:error, :unauthorized} =
               Sst.amend_return(preparer, 73, tax_return.id, %{reason: "Mine"})

      assert {:error, :return_not_finalised} =
               Sst.amend_return(
                 context.operator,
                 73,
                 open!(context, "service_tax", @january).id,
                 %{reason: "Open"}
               )
    end
  end

  describe "discarding" do
    test "keeps the return on record with its reason, and frees the period", context do
      %{operator: operator} = context
      tax_return = open!(context, "sales_tax", @january)

      assert {:error, changeset} = Sst.discard_return(operator, 73, tax_return.id, %{})
      assert %{reason: [_]} = errors_on(changeset)

      assert {:ok, %{status: "discarded", events: [_, %{action: "discarded", reason: "Wrong"}]}} =
               Sst.discard_return(operator, 73, tax_return.id, %{reason: "Wrong"})

      assert {:ok, %{figures: nil}} = Sst.get_return(operator, 73, tax_return.id)
      assert %{return_number: 2} = open!(context, "sales_tax", @january)
      assert {:error, :return_not_found} = Sst.get_return(operator, 73, 999_999)
      assert {:error, :return_not_found} = Sst.get_return(operator, 73, "x")
    end
  end

  describe "export" do
    test "writes the return in the form's item order, and a printable page", context do
      context = map_all!(context)
      _invoice = invoice!(context, ~D[2026-01-10], [line(context, "1000", :goods10)])
      tax_return = open!(context, "sales_tax", @january)

      assert {:ok, %{filename: filename, content: csv, content_type: "text/csv"}} =
               Sst.export_return(context.operator, 73, tax_return.id)

      assert filename == "sst-02-sales-tax-2026-01-01-2026-02-28-return-1.csv"
      lines = String.split(csv, "\r\n", trim: true)
      assert hd(lines) == "part,item,description,value,tax"
      assert "A,,Status,\"Draft, not finalised\"," in lines
      assert "A,1,SST registration number,X00-2601-00000001," in lines
      assert "B2,11(b),Taxable goods at 10%,1000.00,100.00" in lines
      assert "B2,14,Tax payable before penalty,,100.00" in lines

      items = for line <- lines, [_, item | _] = String.split(line, ","), item != "", do: item
      assert Enum.take(Enum.drop_while(items, &(&1 != "11(a)")), 4) == ~w[11(a) 11(b) 12 13(a)]

      {:ok, _} = Sst.finalise_return(context.operator, 73, tax_return.id)

      assert {:ok, %{content: html, content_type: "text/html"}} =
               Sst.export_return(context.operator, 73, tax_return.id, format: :html)

      assert html =~ "Finalised, version 1"
      assert html =~ "X00-2601-00000001"
      refute html =~ "Draft: not finalised"
    end

    test "is refused for a discarded return", context do
      tax_return = open!(context, "sales_tax", @january)
      {:ok, _} = Sst.discard_return(context.operator, 73, tax_return.id, %{reason: "Wrong"})
      assert {:error, :return_discarded} = Sst.export_return(context.operator, 73, tax_return.id)
    end
  end
end
