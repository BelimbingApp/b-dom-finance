defmodule Bilimbi.Finance.Einvoice.SelfBilledTest do
  # The contribution registry snapshot is process-global.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.{MyInvois, Posting, TestFixtures}

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  setup do
    context = TestFixtures.setup_einvoice!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    operator =
      TestFixtures.sign_in!(
        context.first_scope,
        73,
        91,
        TestFixtures.capabilities() ++ TestFixtures.ledger_capabilities()
      )

    :ok = TestFixtures.put_supplier_profile!(context.first_scope, 73)
    Map.put(context, :operator, operator)
  end

  defp issued!(op, overrides \\ %{}) do
    {:ok, document} =
      Einvoice.issue_document(op, 73, TestFixtures.self_billed_attributes(overrides))

    document
  end

  defp money(value), do: value |> Decimal.round(2) |> Decimal.to_string(:normal)

  test "the company issues it as the buyer, with the supplier as the counterparty", %{
    operator: op
  } do
    document = issued!(op)

    assert %{
             document_type: "11",
             status: "issued",
             self_billed?: true,
             consolidated?: false,
             counterparty_name: "Foreign Supplier's Name",
             buyer_name: "Supplier's Name"
           } = document

    assert %{
             "tax_id" => "EI00000000030",
             "industry_code" => "00000",
             "business_activity" => "NOT APPLICABLE",
             "address" => %{"country_code" => "USA", "state_code" => "17"}
           } = document.supplier

    # The company's own profile, as it stood, is the buyer.
    assert %{"tax_id" => "C29702635060", "registration_number" => "D12345678"} = document.buyer
    assert money(document.payable_amount) == "100.00"

    # A list searches the counterparty, never the company's own name.
    {:ok, _sale} = Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes())

    assert {:ok, %{entries: [%{counterparty_name: "Foreign Supplier's Name"}]}} =
             Einvoice.page_documents(op, 73, search: "supplier's name")

    assert {:ok, %{entries: [%{counterparty_name: "Buyer's Name"}]}} =
             Einvoice.page_documents(op, 73, search: "buyer")
  end

  test "names the supplier, never the buyer, and checks it like a supplier", %{operator: op} do
    buyer = TestFixtures.invoice_attributes().buyer

    assert {:error, changeset} =
             Einvoice.issue_document(
               op,
               73,
               TestFixtures.self_billed_attributes()
               |> Map.delete(:supplier)
               |> Map.put(:buyer, buyer)
             )

    assert %{
             supplier: ["can't be blank"],
             buyer: ["is the company on a self-billed document" <> _]
           } =
             errors_on(changeset)

    assert {:error, changeset} =
             Einvoice.issue_document(
               op,
               73,
               TestFixtures.self_billed_attributes()
               |> update_in([:supplier], &Map.drop(&1, [:industry_code, :business_activity]))
             )

    assert %{
             supplier: %{industry_code: ["can't be blank"], business_activity: ["can't be blank"]}
           } =
             errors_on(changeset)

    # The foreign-supplier TIN is for a supplier outside Malaysia.
    assert {:error, changeset} =
             Einvoice.issue_document(
               op,
               73,
               TestFixtures.self_billed_attributes()
               |> put_in([:supplier, :address, :country_code], "MYS")
             )

    assert %{supplier: %{tax_id: ["is the general TIN for a supplier outside Malaysia"]}} =
             errors_on(changeset)

    # A sale names its buyer; the company is its supplier.
    assert {:error, changeset} =
             Einvoice.issue_document(
               op,
               73,
               TestFixtures.invoice_attributes(%{
                 supplier: TestFixtures.self_billed_attributes().supplier
               })
             )

    assert %{supplier: ["is the company; give the buyer"]} = errors_on(changeset)
  end

  test "an incomplete company profile is refused as the buyer", context do
    # Company 74 has no e-invoicing profile at all.
    op = TestFixtures.sign_in!(context.first_scope, 74, 93, TestFixtures.capabilities())

    assert {:error, changeset} =
             Einvoice.issue_document(op, 74, TestFixtures.self_billed_attributes())

    assert %{buyer: ["is incomplete: set supplier TIN, " <> _]} = errors_on(changeset)
  end

  test "a self-billed note corrects a self-billed invoice, and a note a sale", %{operator: op} do
    invoice = issued!(op)
    :ok = TestFixtures.validate!(op, 73, invoice.id)

    {:ok, sale} =
      Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes(%{code_number: "INV-1"}))

    :ok = TestFixtures.validate!(op, 73, sale.id, uuid: "SALEUUID")

    assert {:ok, note} =
             Einvoice.issue_document(
               op,
               73,
               TestFixtures.self_billed_attributes(%{
                 document_type: "12",
                 code_number: "SB-CN-1",
                 original_document_id: invoice.id
               })
             )

    assert %{"original_code_number" => "SB-0001", "original_document_uuid" => "F9D425P6DS7D8IU"} =
             note.details

    assert {:error, changeset} =
             Einvoice.issue_document(
               op,
               73,
               TestFixtures.self_billed_attributes(%{
                 document_type: "12",
                 code_number: "SB-CN-2",
                 original_document_id: sale.id
               })
             )

    assert %{original_document_id: ["must be the self-billed invoice it corrects"]} =
             errors_on(changeset)

    assert {:error, changeset} =
             Einvoice.issue_document(
               op,
               73,
               TestFixtures.invoice_attributes(%{
                 document_type: "02",
                 code_number: "CN-1",
                 original_document_id: invoice.id
               })
             )

    assert %{original_document_id: ["must be the invoice it corrects"]} = errors_on(changeset)
  end

  test "builds the payload with the supplier and the company as the buyer", %{operator: op} do
    document = issued!(op)
    ubl = MyInvois.ubl(document, "1.0")

    assert ubl.type_code == "11"
    assert ubl.supplier.name == "Foreign Supplier's Name"
    assert ubl.supplier.industry_code == %{code: "00000", name: "NOT APPLICABLE"}
    assert {"TIN", "EI00000000030"} in ubl.supplier.identifications
    assert ubl.buyer.name == "Supplier's Name"
    assert {"TIN", "C29702635060"} in ubl.buyer.identifications
    # A business's registration type may be blank in the settings: BRN.
    assert {"BRN", "D12345678"} in ubl.buyer.identifications

    assert {:ok, %{bytes: bytes}} =
             MyInvois.payload(document, %{version: "1.0", signing_key: nil}, DateTime.utc_now())

    assert bytes =~ ~s("InvoiceTypeCode":[{"_":"11")
  end

  test "posts a purchase: payable against expense and purchase tax, and a refund in cash",
       %{operator: op} do
    sales = TestFixtures.open_posting_book!(op, 73)
    purchases = TestFixtures.add_purchase_accounts!(op, 73)
    by_id = Map.new(Map.merge(sales, purchases), fn {role, account} -> {account.id, role} end)

    amounts = fn entry ->
      Enum.map(entry.lines, &{by_id[&1.account_id], money(&1.debit), money(&1.credit)})
    end

    invoice =
      issued!(op, %{
        lines: [
          %{
            description: "Consulting",
            classification_code: "022",
            quantity: "1",
            unit_price: "200.00",
            tax_type: "02",
            tax_rate: "8"
          }
        ]
      })

    :ok = TestFixtures.validate!(op, 73, invoice.id)
    {:ok, invoice} = Einvoice.get_document(op, 73, invoice.id)
    assert {:ok, entry} = Posting.post(op, 73, invoice)

    assert amounts.(entry) == [
             {:payable_account, "0.00", "216.00"},
             {:expense_account, "200.00", "0.00"},
             {:purchase_tax_account, "16.00", "0.00"}
           ]

    assert entry.description == "E-invoice SB-0001 (self-billed invoice)"

    {:ok, refund} =
      Einvoice.issue_document(
        op,
        73,
        TestFixtures.self_billed_attributes(%{
          document_type: "14",
          code_number: "SB-RN-1",
          original_document_id: invoice.id
        })
      )

    :ok = TestFixtures.validate!(op, 73, refund.id, uuid: "REFUNDUUID")
    {:ok, refund} = Einvoice.get_document(op, 73, refund.id)
    assert {:ok, entry} = Posting.post(op, 73, refund)

    assert amounts.(entry) == [
             {:settlement_account, "100.00", "0.00"},
             {:expense_account, "0.00", "100.00"}
           ]
  end

  test "a purchase without its accounts set is recorded as a posting failure", %{operator: op} do
    TestFixtures.open_posting_book!(op, 73)
    document = issued!(op)
    :ok = TestFixtures.validate!(op, 73, document.id)
    {:ok, document} = Einvoice.get_document(op, 73, document.id)

    assert {:error, reason} = Posting.post(op, 73, document)

    assert reason ==
             "posting accounts not set: payable_account, expense_account, purchase_tax_account"
  end
end
