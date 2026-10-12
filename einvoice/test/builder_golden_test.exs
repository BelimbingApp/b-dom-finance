defmodule Bilimbi.Finance.Einvoice.MyInvois.BuilderGoldenTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Finance.Einvoice.MyInvois.{Builder, Json, Signer}
  alias Bilimbi.Finance.Einvoice.SdkSamples

  # Each published sample is signed, and its signature's document digest is
  # the SHA-256 of the unsigned, minified bytes. Rebuilding those bytes from
  # plain input proves the builder writes what the authority hashed.
  for name <- SdkSamples.names() do
    test "rebuilds the SDK's #{name} sample byte for byte" do
      name = unquote(name)
      sample = name |> SdkSamples.signed!() |> Json.decode!()
      built = name |> SdkSamples.input() |> Builder.build()

      assert Json.encode!(built) == Signer.document_bytes(sample)
      assert Signer.document_digest(built) == Signer.document_digest(sample)
    end
  end

  test "leaves out what the input does not have" do
    input = Map.drop(SdkSamples.input("Invoice"), [:delivery, :invoice_period, :payment_means])
    bytes = input |> Builder.build() |> Json.encode!()

    refute bytes =~ "Delivery"
    refute bytes =~ "InvoicePeriod"
    refute bytes =~ "PaymentMeans"
    assert bytes =~ ~s("InvoiceTypeCode":[{"_":"01","listVersionID":"1.1"}])
  end

  test "references the original document of a note by its ID and UUID" do
    input =
      Map.merge(SdkSamples.input("Invoice"), %{
        type_code: "02",
        billing_references: [%{id: "INV-1", uuid: "F9D425P6DS7D8IU"}]
      })

    assert input |> Builder.build() |> Json.encode!() =~
             ~s("BillingReference":[{"InvoiceDocumentReference":[{"ID":[{"_":"INV-1"}],"UUID":[{"_":"F9D425P6DS7D8IU"}]}]}])
  end
end
