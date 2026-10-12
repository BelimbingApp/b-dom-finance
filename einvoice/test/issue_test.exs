defmodule Bilimbi.Finance.Einvoice.IssueTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.TestFixtures
  alias Ecto.Adapters.SQL

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  setup do
    context = TestFixtures.setup_einvoice!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, TestFixtures.capabilities())
    :ok = TestFixtures.put_supplier_profile!(context.first_scope, 73)
    Map.put(context, :operator, operator)
  end

  describe "issuing" do
    test "records the document, its lines, its parties, and an issued event", %{operator: op} do
      assert {:ok, document} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())

      assert %{
               authority: "myinvois",
               environment: "sandbox",
               document_type: "01",
               code_number: "JSON-INV12345",
               issued_at: ~U[2026-10-01 00:30:00Z],
               currency_code: "MYR",
               status: "issued",
               issued_by_user_id: 91,
               issued_by_impersonator_id: nil
             } = document

      assert Decimal.equal?(document.line_extension_amount, "170.00")
      assert Decimal.equal?(document.tax_amount, "10.20")
      assert Decimal.equal?(document.payable_amount, "180.20")

      assert [%{line_number: 1, subtotal: subtotal, tax_amount: tax}] = document.lines
      assert Decimal.equal?(subtotal, "170.00") and Decimal.equal?(tax, "10.20")

      assert %{"name" => "Supplier's Name", "tax_id" => "C29702635060"} = document.supplier
      assert %{"address" => %{"lines" => ["Lot 66" | _]}} = document.supplier
      assert %{"tax_id" => "EI00000000010", "registration_type" => "BRN"} = document.buyer

      assert [%{sequence: 1, event: "issued", actor_type: "user", actor_user_id: 91}] =
               document.events

      assert {:ok, ^document} = Einvoice.get_document(op, 73, document.id)
    end

    test "derives discounts, charges, and per-line rounding", %{operator: op} do
      attributes =
        TestFixtures.invoice_attributes(%{
          lines: [
            %{
              description: "Item",
              classification_code: "022",
              quantity: "3",
              unit_price: "3.335",
              discount_amount: "0.50",
              charge_amount: "1.25",
              tax_type: "02",
              tax_rate: "8"
            },
            %{
              description: "Exempt item",
              classification_code: "022",
              quantity: "1",
              unit_price: "5",
              tax_type: "E",
              tax_rate: "0",
              tax_exemption_reason: "Exempt under the schedule"
            }
          ]
        })

      assert {:ok, document} = Einvoice.issue_document(op, 73, attributes)
      assert [first, second] = document.lines
      # 3 x 3.335 = 10.005 -> 10.01; 10.01 - 0.50 + 1.25 = 10.76; 8% = 0.8608 -> 0.86
      assert Decimal.equal?(first.subtotal, "10.01")
      assert Decimal.equal?(first.line_extension_amount, "10.76")
      assert Decimal.equal?(first.tax_amount, "0.86")
      assert Decimal.equal?(second.tax_amount, "0")
      assert Decimal.equal?(document.line_extension_amount, "15.76")
      assert Decimal.equal?(document.tax_inclusive_amount, "16.62")
    end

    test "accepts string keys, as a form or an import sends them", %{operator: op} do
      attributes =
        TestFixtures.invoice_attributes()
        |> Jason.encode!()
        |> Jason.decode!()

      assert {:ok, %{code_number: "JSON-INV12345"}} = Einvoice.issue_document(op, 73, attributes)
    end

    test "refuses codes outside the company's code lists", %{operator: op} do
      attributes =
        TestFixtures.invoice_attributes(%{
          currency_code: "XTS",
          lines: [
            %{
              description: "Item",
              classification_code: "999",
              quantity: "1",
              unit_price: "1",
              unit_code: "ZZZ",
              tax_type: "09",
              tax_rate: "6"
            }
          ]
        })

      assert {:error, changeset} = Einvoice.issue_document(op, 73, attributes)
      assert %{currency_code: [_, "is not a known code"]} = errors_on(changeset)

      assert %{lines: [line]} = errors_on(changeset)

      assert %{
               classification_code: ["is not a known code"],
               unit_code: ["is not a known code"],
               tax_type: ["is not a known code"]
             } = line
    end

    test "requires the authority's rules", %{operator: op} do
      attributes =
        TestFixtures.invoice_attributes(%{
          document_type: "02",
          currency_code: "USD",
          lines: [
            %{
              description: "Exempt item",
              classification_code: "022",
              quantity: "1",
              unit_price: "1",
              tax_type: "E",
              tax_rate: "0"
            }
          ]
        })
        |> put_in([:buyer, :tax_id], "not a tin")

      assert {:error, changeset} = Einvoice.issue_document(op, 73, attributes)
      errors = errors_on(changeset)
      assert %{document_type: ["is not a document type this release issues"]} = errors
      assert %{currency_code: ["must be MYR in this release"]} = errors

      assert %{buyer: %{tax_id: ["must be one or two capital letters and 8 to 12 digits"]}} =
               errors

      assert %{lines: [%{tax_exemption_reason: ["is required for an exempt line"]}]} = errors
    end

    test "treats a blank or nil discount or charge as none", %{operator: op} do
      for {blank, n} <- Enum.with_index([nil, "", "  "], 1) do
        attributes =
          TestFixtures.invoice_attributes(%{
            code_number: "BLANK-#{n}",
            lines: [
              line(%{discount_amount: blank, charge_amount: blank, tax_type: "01", tax_rate: "6"})
            ]
          })

        assert {:ok, %{lines: [line]}} = Einvoice.issue_document(op, 73, attributes)
        assert Decimal.equal?(line.discount_amount, "0")
        assert Decimal.equal?(line.charge_amount, "0")
        assert Decimal.equal?(line.line_extension_amount, "10.00")
      end
    end

    test "refuses a missing, blank, or nil tax rate instead of recording zero tax",
         %{operator: op} do
      for rate <- [:missing, nil, "", "  "] do
        attributes =
          TestFixtures.invoice_attributes(%{
            lines: [line(if(rate == :missing, do: %{}, else: %{tax_rate: rate}))]
          })

        assert {:error, changeset} = Einvoice.issue_document(op, 73, attributes)
        assert %{lines: [%{tax_rate: ["can't be blank"]}]} = errors_on(changeset)
      end

      assert {:ok, []} = Einvoice.list_documents(op, 73)
    end

    test "ties the tax rate to the tax type", %{operator: op} do
      refuse = fn tax_type, rate ->
        attributes =
          TestFixtures.invoice_attributes(%{
            lines: [
              line(%{tax_type: tax_type, tax_rate: rate, tax_exemption_reason: "Exempt"})
            ]
          })

        assert {:error, changeset} = Einvoice.issue_document(op, 73, attributes)
        assert %{lines: [%{tax_rate: [message]}]} = errors_on(changeset)
        message
      end

      for type <- ~w(01 02 03 04 05) do
        assert refuse.(type, "0") == "must be above 0 for this tax type"
      end

      for type <- ~w(06 E) do
        assert refuse.(type, "6") == "must be 0 for this tax type"
      end

      for {type, rate, number} <- [
            {"01", "10", 1},
            {"02", "8", 2},
            {"03", "10", 3},
            {"04", "5", 4},
            {"05", "5", 5},
            {"06", "0", 6},
            {"E", "0", 7}
          ] do
        attributes =
          TestFixtures.invoice_attributes(%{
            code_number: "RATE-#{number}",
            lines: [line(%{tax_type: type, tax_rate: rate, tax_exemption_reason: "Exempt"})]
          })

        assert {:ok, _} = Einvoice.issue_document(op, 73, attributes), "#{type} at #{rate}"
      end
    end

    test "checks the buyer's TIN and phone as it checks the supplier's", %{operator: op} do
      refuse = fn field, value ->
        attributes =
          TestFixtures.invoice_attributes() |> put_in([:buyer, field], value)

        assert {:error, changeset} = Einvoice.issue_document(op, 73, attributes)
        assert %{buyer: %{^field => [_message]}} = errors_on(changeset)
      end

      refuse.(:phone, "60123456789")
      refuse.(:phone, "+6012345")
      refuse.(:phone, "+" <> String.duplicate("1", 20))
      refuse.(:tax_id, "123")

      attributes =
        TestFixtures.invoice_attributes()
        |> put_in([:buyer, :phone], "+" <> String.duplicate("1", 19))

      assert {:ok, _} = Einvoice.issue_document(op, 73, attributes)
    end

    test "refuses amounts finer than their columns and future issue times", %{operator: op} do
      attributes =
        TestFixtures.invoice_attributes(%{
          issued_at: DateTime.add(DateTime.utc_now(), 3600),
          lines: [
            %{
              description: "Item",
              classification_code: "022",
              quantity: "1",
              unit_price: "1",
              discount_amount: "0.001",
              tax_type: "06",
              tax_rate: "0"
            }
          ]
        })

      assert {:error, changeset} = Einvoice.issue_document(op, 73, attributes)
      assert %{issued_at: ["cannot be in the future"]} = errors_on(changeset)

      assert %{lines: [%{discount_amount: ["has more than 2 decimal places"]}]} =
               errors_on(changeset)
    end

    test "names what the supplier profile lacks", %{first_scope: scope, operator: op} do
      :ok =
        Bilimbi.Base.Settings.delete(
          "finance.einvoice.supplier.industry_code",
          TestFixtures.settings_scope(scope, 73)
        )

      assert {:error, changeset} =
               Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())

      assert %{supplier: [message]} = errors_on(changeset)
      assert message =~ "industry classification code"
    end

    test "refuses a code number already issued in the environment", %{operator: op} do
      assert {:ok, _} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())

      assert {:error, :code_number_taken} =
               Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())
    end

    test "records an audit action naming the document", %{operator: op} do
      assert {:ok, document} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())

      assert [[%{"document_id" => id, "code_number" => "JSON-INV12345"}]] =
               Bilimbi.Base.Audit.TestFixtures.action_payloads("finance.einvoice.document.issued")

      assert id == document.id
    end
  end

  defp line(overrides) do
    Map.merge(
      %{
        description: "Item",
        classification_code: "022",
        quantity: "1",
        unit_code: "C62",
        unit_price: "10.00"
      },
      overrides
    )
  end

  describe "authorization" do
    test "needs the issue capability, and view to read", %{first_scope: scope} do
      viewer = TestFixtures.sign_in!(scope, 73, 92, ["finance.einvoice.view"])

      assert {:error, :unauthorized} =
               Einvoice.issue_document(viewer, 73, TestFixtures.invoice_attributes())

      assert {:ok, []} = Einvoice.list_documents(viewer, 73)

      stranger = TestFixtures.sign_in!(scope, 73, 93, [])
      assert {:error, :unauthorized} = Einvoice.list_documents(stranger, 73)
    end

    test "refuses a system scope and another tenant's company", context do
      assert {:error, :unauthorized} =
               Einvoice.issue_document(context.first_scope, 73, TestFixtures.invoice_attributes())

      assert {:error, :company_not_found} = Einvoice.list_documents(context.operator, 75)
    end

    test "keeps a sibling company's documents to that company", %{operator: op} do
      assert {:ok, document} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())
      assert {:error, _} = Einvoice.get_document(op, 74, document.id)
    end
  end

  describe "reading" do
    test "lists newest first and pages with before", %{operator: op} do
      for n <- 1..3 do
        {:ok, _} =
          Einvoice.issue_document(
            op,
            73,
            TestFixtures.invoice_attributes(%{code_number: "INV-#{n}"})
          )
      end

      assert {:ok,
              [%{code_number: "INV-3", status: "issued", buyer_name: "Buyer's Name"}, second]} =
               Einvoice.list_documents(op, 73, limit: 2)

      assert {:ok, [%{code_number: "INV-1"}]} =
               Einvoice.list_documents(op, 73, limit: 2, before: second.id)

      assert {:error, :invalid_option} = Einvoice.list_documents(op, 73, limit: 0)
      assert {:error, :document_not_found} = Einvoice.get_document(op, 73, 999_999)
    end
  end

  describe "immutability" do
    test "the database refuses editing or deleting a recorded document", %{operator: op} do
      assert {:ok, document} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())

      for sql <- [
            "UPDATE finance_einvoice_documents SET code_number = 'x'",
            "DELETE FROM finance_einvoice_documents",
            "UPDATE finance_einvoice_document_lines SET description = 'x'",
            "DELETE FROM finance_einvoice_document_lines",
            "UPDATE finance_einvoice_status_events SET event = 'valid'",
            "DELETE FROM finance_einvoice_status_events"
          ] do
        assert_raise Postgrex.Error, ~r/finance e-invoicing keeps/, fn ->
          Repo.transaction(fn -> SQL.query!(Repo, sql, []) end)
        end
      end

      assert {:ok, ^document} = Einvoice.get_document(op, 73, document.id)
    end

    test "a status change is a new, numbered event", %{operator: op} do
      assert {:ok, document} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())

      SQL.query!(
        Repo,
        """
        INSERT INTO finance_einvoice_status_events
          (tenant_id, company_id, document_id, sequence, event, reason, actor_type, actor_user_id, recorded_at)
        VALUES (41, 73, $1, 99, 'cancelled', 'Wrong buyer', 'user', 91, '2000-01-01')
        """,
        [document.id]
      )

      assert {:ok, %{status: "cancelled", events: [_, cancelled]}} =
               Einvoice.get_document(op, 73, document.id)

      assert %{sequence: 2, reason: "Wrong buyer"} = cancelled
      assert DateTime.compare(cancelled.recorded_at, ~U[2020-01-01 00:00:00Z]) == :gt
    end
  end
end
