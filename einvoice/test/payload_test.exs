defmodule Bilimbi.Finance.Einvoice.MyInvois.PayloadTest do
  # The contribution registry snapshot is process-global.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.{Certificate, MyInvois, TestFixtures}
  alias Bilimbi.Finance.Einvoice.MyInvois.{Json, Signer}

  setup do
    context = TestFixtures.setup_einvoice!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, TestFixtures.capabilities())
    :ok = TestFixtures.put_supplier_profile!(context.first_scope, 73)
    Map.put(context, :operator, operator)
  end

  test "an issued document becomes a signed payload that verifies", %{operator: op} do
    attributes =
      TestFixtures.invoice_attributes(%{
        payment_means_code: "03",
        billing_period_start: "2026-09-01",
        billing_period_end: "2026-09-30",
        billing_period_description: "Monthly"
      })

    {:ok, document} = Einvoice.issue_document(op, 73, attributes)
    generated = TestFixtures.test_certificate!()
    {:ok, certificate} = Certificate.parse(generated.certificate_pem)

    assert %{format: "JSON", version: "1.1", bytes: bytes} =
             MyInvois.payload(
               document,
               %{certificate: certificate, key: generated.key},
               ~U[2026-10-01 00:31:00Z]
             )

    assert :ok = Signer.verify(bytes)

    for fragment <- [
          ~s("ID":[{"_":"JSON-INV12345"}]),
          ~s("IssueDate":[{"_":"2026-10-01"}],"IssueTime":[{"_":"00:30:00Z"}]),
          ~s("DocumentCurrencyCode":[{"_":"MYR"}],"TaxCurrencyCode":[{"_":"MYR"}]),
          ~s("InvoicePeriod":[{"StartDate":[{"_":"2026-09-01"}],"EndDate":[{"_":"2026-09-30"}]),
          ~s("PartyIdentification":[{"ID":[{"_":"C29702635060","schemeID":"TIN"}]}),
          ~s({"ID":[{"_":"NA","schemeID":"SST"}]}),
          ~s("PaymentMeansCode":[{"_":"03"}]),
          ~s("TaxAmount":[{"_":10.20,"currencyID":"MYR"}]),
          ~s("PayableAmount":[{"_":180.20,"currencyID":"MYR"}]),
          ~s("InvoicedQuantity":[{"_":10.000000,"unitCode":"C62"}])
        ] do
      assert bytes =~ fragment
    end

    refute bytes =~ "TaxExchangeRate"
    assert %Jason.OrderedObject{} = Json.decode!(bytes)
  end
end
