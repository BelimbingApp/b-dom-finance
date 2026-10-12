defmodule Bilimbi.Finance.Einvoice.MyInvois.SignerTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Finance.Einvoice.Certificate
  alias Bilimbi.Finance.Einvoice.MyInvois.{Builder, Json, Signer}
  alias Bilimbi.Finance.Einvoice.{SdkSamples, TestFixtures}

  @signature_path [
    "Invoice",
    "UBLExtensions",
    "UBLExtension",
    "ExtensionContent",
    "UBLDocumentSignatures",
    "SignatureInformation",
    "Signature"
  ]

  describe "the SDK's signed samples" do
    for name <- SdkSamples.names() do
      test "#{name} verifies: digests, certificate, issuer, and RSA signature" do
        assert :ok = Signer.verify(SdkSamples.signed!(unquote(name)))
      end
    end

    test "signed properties built from the SDK certificate match the sample's" do
      signature = "Invoice" |> SdkSamples.signed!() |> Json.decode!() |> at(@signature_path)
      certificate = sdk_certificate(signature)

      properties = signature |> at(["Object"]) |> Json.get("QualifyingProperties") |> hd()

      assert Json.encode!(Signer.qualifying_properties(certificate, ~U[2025-04-15 02:01:36Z])) ==
               Json.encode!(properties)

      # .NET's form: the issuer's attributes in reverse DER order.
      assert certificate.issuer_name ==
               "C=MY, O=Raffcomm Technologies Sdn Bhd, OU=1000449-W, CN=CypherSign Pro Max"

      assert certificate.serial_number == "1308502606566147853"
    end

    test "a changed document or signature no longer verifies" do
      signed = SdkSamples.signed!("Invoice")

      assert {:error, :document_digest_mismatch} =
               signed
               |> String.replace("Laptop Peripherals", "Laptop Peripheralz")
               |> Signer.verify()

      document = Json.decode!(signed)
      value = document |> at(@signature_path) |> at(["SignatureValue"]) |> Json.get("_")
      forged = Base.encode64(:crypto.strong_rand_bytes(byte_size(Base.decode64!(value))))

      assert {:error, :bad_signature} = signed |> String.replace(value, forged) |> Signer.verify()
    end
  end

  describe "signing" do
    setup do
      generated = TestFixtures.test_certificate!()
      {:ok, certificate} = Certificate.parse(generated.certificate_pem)
      %{signing_key: %{certificate: certificate, key: generated.key}}
    end

    test "a signed document verifies and keeps the SDK sample's shape", %{signing_key: key} do
      signed =
        "Invoice"
        |> SdkSamples.input()
        |> Builder.build()
        |> Signer.sign(key, ~U[2026-10-12 08:00:00.123456Z])

      assert :ok = Signer.verify(signed)
      assert signed =~ ~s("SigningTime":[{"_":"2026-10-12T08:00:00Z"}])

      sample = "Invoice" |> SdkSamples.signed!() |> Json.decode!()
      assert shape(Json.decode!(signed)) == shape(sample)
      assert Signer.document_bytes(Json.decode!(signed)) == Signer.document_bytes(sample)
    end

    test "re-signing replaces an existing signature", %{signing_key: key} do
      signed =
        "Invoice"
        |> SdkSamples.signed!()
        |> Json.decode!()
        |> Signer.sign(key, ~U[2026-10-12 08:00:00Z])

      assert :ok = Signer.verify(signed)
      assert length(String.split(signed, "UBLExtensions")) == 2
    end

    test "a key that is not the certificate's fails verification", %{signing_key: key} do
      signed =
        "Invoice"
        |> SdkSamples.input()
        |> Builder.build()
        |> Signer.sign(%{key | key: TestFixtures.other_key!()}, ~U[2026-10-12 08:00:00Z])

      assert {:error, :bad_signature} = Signer.verify(signed)
    end
  end

  defp sdk_certificate(signature) do
    der =
      signature
      |> at(["KeyInfo", "X509Data", "X509Certificate"])
      |> Json.get("_")
      |> Base.decode64!()

    {:ok, certificate} =
      Certificate.parse(:public_key.pem_encode([{:Certificate, der, :not_encrypted}]))

    certificate
  end

  defp at(term, []), do: term
  defp at(object, [key | rest]), do: object |> Json.get(key) |> hd() |> at(rest)

  # The structure with every value blanked: keys, order, and nesting only.
  defp shape(%Jason.OrderedObject{values: values}),
    do: Enum.map(values, fn {key, value} -> {key, shape(value)} end)

  defp shape(list) when is_list(list), do: Enum.map(list, &shape/1)
  defp shape(_value), do: :value
end
