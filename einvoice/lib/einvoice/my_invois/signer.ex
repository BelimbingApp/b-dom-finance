defmodule Bilimbi.Finance.Einvoice.MyInvois.Signer do
  @moduledoc """
  Enveloped XAdES signatures on UBL JSON documents, as the MyInvois SDK's
  "Signing a JSON document" page describes them, in plain Erlang crypto.

  1. Remove `UBLExtensions` and `Signature` from the invoice and minify the
     document; these bytes are what the authority hashes.
  2. The document digest is their SHA-256, base64-encoded.
  3. The signature is RSA PKCS#1 v1.5 with SHA-256 over those bytes.
  4. The certificate digest is the SHA-256 of the certificate's DER bytes.
  5. `SignedProperties` carry the UTC signing time, the certificate digest,
     and the issuer name and serial number.
  6. Their digest is the SHA-256 of the minified
     `{"Target": "signature", "SignedProperties": [...]}` object.
  7. `UBLExtensions` and `Signature` are appended to the invoice, and the
     whole document is minified again.

  JSON needs no XML canonicalisation; the bytes are the canonical form, which
  is why the order-preserving `MyInvois.Json` writes them.
  `test/signer_test.exs` verifies the SDK's signed samples with this module
  and signs with a generated certificate.
  """

  alias Bilimbi.Finance.Einvoice.MyInvois.Json

  @sha256 "http://www.w3.org/2001/04/xmlenc#sha256"
  @rsa_sha256 "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
  @xades "urn:oasis:names:specification:ubl:dsig:enveloped:xades"
  @signature_id "urn:oasis:names:specification:ubl:signature:Invoice"
  @signed_properties_type "http://uri.etsi.org/01903/v1.3.2#SignedProperties"

  @type signing_key :: %{certificate: Bilimbi.Finance.Einvoice.Certificate.t(), key: term()}

  @doc """
  The signed document's minified bytes. `document` is a UBL JSON term from
  `MyInvois.Builder` or `MyInvois.Json.decode!/1`; any signature it already
  carries is replaced. `signing_time` is truncated to the second.
  """
  @spec sign(Jason.OrderedObject.t(), signing_key(), DateTime.t()) :: binary()
  def sign(document, %{certificate: certificate, key: key}, %DateTime{} = signing_time) do
    unsigned = unsigned(document)
    bytes = Json.encode!(unsigned)
    signature = :public_key.sign(bytes, :sha256, key)
    properties = signed_properties(certificate, signing_time)

    extensions = [
      Json.object([
        {"UBLExtension",
         [
           Json.object([
             {"ExtensionURI", Json.value(@xades)},
             {"ExtensionContent",
              [
                Json.object([
                  {"UBLDocumentSignatures",
                   [
                     Json.object([
                       {"SignatureInformation",
                        [
                          Json.object([
                            {"ID", Json.value("urn:oasis:names:specification:ubl:signature:1")},
                            {"ReferencedSignatureID", Json.value(@signature_id)},
                            {"Signature",
                             [signature_block(certificate, properties, signature, bytes)]}
                          ])
                        ]}
                     ])
                   ]}
                ])
              ]}
           ])
         ]}
      ])
    ]

    reference = [
      Json.object([
        {"ID", Json.value(@signature_id)},
        {"SignatureMethod", Json.value(@xades)}
      ])
    ]

    unsigned
    |> update_invoice(&Json.append(&1, [{"UBLExtensions", extensions}, {"Signature", reference}]))
    |> Json.encode!()
  end

  @doc "The document's bytes as the authority hashes them: unsigned and minified."
  @spec document_bytes(Jason.OrderedObject.t()) :: binary()
  def document_bytes(document), do: document |> unsigned() |> Json.encode!()

  @doc "The base64 SHA-256 the authority calls the document digest."
  @spec document_digest(Jason.OrderedObject.t()) :: String.t()
  def document_digest(document), do: document |> document_bytes() |> digest()

  @doc """
  The `QualifyingProperties` object a signature carries for a certificate and
  signing time. Its minified form is what the signed-properties digest hashes.
  """
  @spec qualifying_properties(map(), DateTime.t()) :: Jason.OrderedObject.t()
  def qualifying_properties(certificate, %DateTime{} = signing_time),
    do: signed_properties(certificate, signing_time)

  @doc """
  Checks a signed document's signature against the certificate it embeds:
  the document digest, the signed-properties digest, the certificate digest,
  the issuer and serial number, and the RSA signature over the document.
  """
  @spec verify(binary()) :: :ok | {:error, atom()}
  def verify(signed) when is_binary(signed) do
    document = Json.decode!(signed)

    with {:ok, signature} <- signature_block(document),
         {:ok, der} <- embedded_certificate(signature),
         {:ok, certificate} <- certificate_from_der(der),
         properties = get_path(signature, ["Object", "QualifyingProperties"]),
         :ok <- check_digests(signature, document, properties),
         :ok <- check_certificate(properties, certificate),
         {:ok, value} <- decode64(get_value(signature, ["SignatureValue"])) do
      if :public_key.verify(document_bytes(document), :sha256, value, certificate.public_key),
        do: :ok,
        else: {:error, :bad_signature}
    end
  end

  ## Signing

  defp unsigned(document) do
    update_invoice(document, &Json.drop(&1, ["UBLExtensions", "Signature"]))
  end

  defp update_invoice(document, fun),
    do: Json.update!(document, "Invoice", fn [i] -> [fun.(i)] end)

  defp signed_properties(certificate, signing_time) do
    time = signing_time |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Json.object([
      {"Target", "signature"},
      {"SignedProperties",
       [
         Json.object([
           {"Id", "id-xades-signed-props"},
           {"SignedSignatureProperties",
            [
              Json.object([
                {"SigningTime", Json.value(time)},
                {"SigningCertificate",
                 [
                   Json.object([
                     {"Cert",
                      [
                        Json.object([
                          {"CertDigest",
                           [
                             Json.object([
                               {"DigestMethod", digest_method()},
                               {"DigestValue", Json.value(digest(certificate.der))}
                             ])
                           ]},
                          {"IssuerSerial", issuer_serial(certificate)}
                        ])
                      ]}
                   ])
                 ]}
              ])
            ]}
         ])
       ]}
    ])
  end

  defp signature_block(certificate, properties, signature, bytes) do
    Json.object([
      {"Id", "signature"},
      {"Object", [Json.object([{"QualifyingProperties", [properties]}])]},
      {"KeyInfo",
       [
         Json.object([
           {"X509Data",
            [
              Json.object([
                {"X509Certificate", Json.value(Base.encode64(certificate.der))},
                # The authority's samples carry the issuer name here too.
                {"X509SubjectName", Json.value(certificate.issuer_name)},
                {"X509IssuerSerial", issuer_serial(certificate)}
              ])
            ]}
         ])
       ]},
      {"SignatureValue", Json.value(Base.encode64(signature))},
      {"SignedInfo",
       [
         Json.object([
           {"SignatureMethod", [Json.object([{"_", ""}, {"Algorithm", @rsa_sha256}])]},
           {"Reference",
            [
              Json.object([
                {"Type", @signed_properties_type},
                {"URI", "#id-xades-signed-props"},
                {"DigestMethod", digest_method()},
                {"DigestValue", Json.value(digest(Json.encode!(properties)))}
              ]),
              Json.object([
                {"Type", ""},
                {"URI", ""},
                {"DigestMethod", digest_method()},
                {"DigestValue", Json.value(digest(bytes))}
              ])
            ]}
         ])
       ]}
    ])
  end

  defp issuer_serial(certificate) do
    [
      Json.object([
        {"X509IssuerName", Json.value(certificate.issuer_name)},
        {"X509SerialNumber", Json.value(certificate.serial_number)}
      ])
    ]
  end

  defp digest_method, do: [Json.object([{"_", ""}, {"Algorithm", @sha256}])]

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode64()

  ## Verifying

  defp signature_block(document) do
    case get_path(document, [
           "Invoice",
           "UBLExtensions",
           "UBLExtension",
           "ExtensionContent",
           "UBLDocumentSignatures",
           "SignatureInformation",
           "Signature"
         ]) do
      %Jason.OrderedObject{} = signature -> {:ok, signature}
      _missing -> {:error, :unsigned}
    end
  end

  defp embedded_certificate(signature) do
    decode64(get_value(signature, ["KeyInfo", "X509Data", "X509Certificate"]))
  end

  defp certificate_from_der(der) do
    pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

    case Bilimbi.Finance.Einvoice.Certificate.parse(pem) do
      {:ok, certificate} -> {:ok, certificate}
      {:error, _} -> {:error, :invalid_certificate}
    end
  end

  defp check_digests(signature, document, properties) do
    references = get_path(signature, ["SignedInfo"]) |> Json.get("Reference")
    by_uri = Map.new(references, &{Json.get(&1, "URI"), reference_digest(&1)})

    cond do
      Map.get(by_uri, "") != document_digest(document) ->
        {:error, :document_digest_mismatch}

      Map.get(by_uri, "#id-xades-signed-props") != digest(Json.encode!(properties)) ->
        {:error, :signed_properties_digest_mismatch}

      true ->
        :ok
    end
  end

  defp reference_digest(reference), do: get_value(reference, ["DigestValue"])

  defp check_certificate(properties, certificate) do
    cert = get_path(properties, ["SignedProperties", "SignedSignatureProperties"])
    cert = get_path(cert, ["SigningCertificate", "Cert"])

    cond do
      get_value(cert, ["CertDigest", "DigestValue"]) != digest(certificate.der) ->
        {:error, :certificate_digest_mismatch}

      get_value(cert, ["IssuerSerial", "X509IssuerName"]) != certificate.issuer_name or
          get_value(cert, ["IssuerSerial", "X509SerialNumber"]) != certificate.serial_number ->
        {:error, :issuer_serial_mismatch}

      true ->
        :ok
    end
  end

  # Every UBL JSON element is a one-item list; a path walks their first items.
  defp get_path(term, []), do: term
  defp get_path(nil, _path), do: nil

  defp get_path(%Jason.OrderedObject{} = object, [key | rest]) do
    case Json.get(object, key) do
      [first | _] -> get_path(first, rest)
      _other -> nil
    end
  end

  defp get_path(_term, _path), do: nil

  defp get_value(term, path) do
    case get_path(term, path) do
      %Jason.OrderedObject{} = value -> Json.get(value, "_")
      _other -> nil
    end
  end

  defp decode64(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64}
    end
  end

  defp decode64(_value), do: {:error, :unsigned}
end
