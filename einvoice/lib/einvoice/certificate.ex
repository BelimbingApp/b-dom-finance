defmodule Bilimbi.Finance.Einvoice.Certificate do
  @moduledoc """
  A company's signing certificate and private key, read from PEM text.

  Erlang's `:public_key` reads PEM but not PKCS#12, so a company exports its
  certificate and its unencrypted private key (`BEGIN PRIVATE KEY` or
  `BEGIN RSA PRIVATE KEY`) as PEM and stores both as encrypted settings.
  Only RSA keys are accepted: the authority's signature is RSA PKCS#1 v1.5
  with SHA-256.

  `parse/1` returns the facts a signature and the setup page need: the DER
  bytes, the issuer name in the form the authority compares, the serial
  number, the validity window, and the subject attributes that carry the
  company's tax and registration numbers.
  """

  @type t :: %{
          der: binary(),
          public_key: term(),
          issuer_name: String.t(),
          subject_name: String.t(),
          serial_number: String.t(),
          not_before: DateTime.t(),
          not_after: DateTime.t(),
          subject: %{optional(String.t()) => String.t()}
        }

  # Short names in the order-reversed, comma-joined form .NET's
  # X500DistinguishedName renders, which is what the authority's samples carry.
  @short_names %{
    {2, 5, 4, 3} => "CN",
    {2, 5, 4, 4} => "SN",
    {2, 5, 4, 5} => "SERIALNUMBER",
    {2, 5, 4, 6} => "C",
    {2, 5, 4, 7} => "L",
    {2, 5, 4, 8} => "S",
    {2, 5, 4, 9} => "STREET",
    {2, 5, 4, 10} => "O",
    {2, 5, 4, 11} => "OU",
    {2, 5, 4, 12} => "T",
    {2, 5, 4, 42} => "G",
    {1, 2, 840, 113_549, 1, 9, 1} => "E",
    {0, 9, 2342, 19_200_300, 100, 1, 25} => "DC"
  }

  @organization_identifier {2, 5, 4, 97}
  @serial_number {2, 5, 4, 5}

  @doc "Settings validator: true when `value` holds one readable X.509 certificate."
  @spec valid_certificate_pem?(term()) :: boolean()
  def valid_certificate_pem?(value), do: match?({:ok, _}, parse(value))

  @doc "Settings validator: true when `value` holds one unencrypted RSA private key."
  @spec valid_private_key_pem?(term()) :: boolean()
  def valid_private_key_pem?(value), do: match?({:ok, _}, private_key(value))

  @doc "Reads the first certificate in PEM text."
  @spec parse(term()) :: {:ok, t()} | {:error, :invalid_certificate}
  def parse(pem) when is_binary(pem) do
    with [{:Certificate, der, :not_encrypted} | _] <- decode_pem(pem),
         {:ok, certificate} <- decode_certificate(der) do
      {:ok, certificate}
    else
      _invalid -> {:error, :invalid_certificate}
    end
  end

  def parse(_pem), do: {:error, :invalid_certificate}

  @doc "Reads an unencrypted RSA private key from PEM text."
  @spec private_key(term()) :: {:ok, term()} | {:error, :invalid_private_key}
  def private_key(pem) when is_binary(pem) do
    case decode_pem(pem) do
      [{type, der, :not_encrypted}] when type in [:PrivateKeyInfo, :RSAPrivateKey] ->
        rsa_private_key(type, der)

      _other ->
        {:error, :invalid_private_key}
    end
  end

  def private_key(_pem), do: {:error, :invalid_private_key}

  @doc "True when the private key belongs to the certificate's public key."
  @spec key_matches?(t(), term()) :: boolean()
  def key_matches?(%{public_key: {:RSAPublicKey, modulus, exponent}}, key) do
    match?({:RSAPrivateKey, _, ^modulus, ^exponent, _, _, _, _, _, _, _}, key)
  end

  def key_matches?(_certificate, _key), do: false

  @doc "Whole days from `now` until the certificate stops being valid; negative once expired."
  @spec days_until_expiry(t(), DateTime.t()) :: integer()
  def days_until_expiry(%{not_after: not_after}, %DateTime{} = now) do
    not_after |> DateTime.diff(now, :second) |> Integer.floor_div(86_400)
  end

  defp decode_pem(pem) do
    :public_key.pem_decode(pem)
  rescue
    _error -> []
  end

  # Both PEM forms decode to the same RSA key record; any other algorithm is refused.
  defp rsa_private_key(type, der) do
    case :public_key.pem_entry_decode({type, der, :not_encrypted}) do
      {:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _} = key -> {:ok, key}
      _other -> {:error, :invalid_private_key}
    end
  rescue
    _error -> {:error, :invalid_private_key}
  end

  defp decode_certificate(der) do
    {:OTPCertificate, tbs, _algorithm, _signature} = :public_key.pkix_decode_cert(der, :otp)

    {:OTPTBSCertificate, _version, serial, _signature, issuer, validity, subject, key_info,
     _issuer_uid, _subject_uid, _extensions} = tbs

    {:OTPSubjectPublicKeyInfo, _algorithm, public_key} = key_info
    {:Validity, not_before, not_after} = validity

    {:ok,
     %{
       der: der,
       public_key: public_key,
       issuer_name: distinguished_name(issuer),
       subject_name: distinguished_name(subject),
       serial_number: Integer.to_string(serial),
       not_before: certificate_time(not_before),
       not_after: certificate_time(not_after),
       subject: subject_attributes(subject)
     }}
  rescue
    _error -> {:error, :invalid_certificate}
  end

  defp distinguished_name({:rdnSequence, rdns}) do
    rdns
    |> Enum.reverse()
    |> Enum.map_join(", ", fn attributes ->
      Enum.map_join(attributes, " + ", fn {:AttributeTypeAndValue, oid, value} ->
        "#{short_name(oid)}=#{quote_value(attribute_text(value))}"
      end)
    end)
  end

  defp short_name(oid) do
    Map.get_lazy(@short_names, oid, fn ->
      "OID." <> (oid |> Tuple.to_list() |> Enum.join("."))
    end)
  end

  defp quote_value(value) do
    if String.match?(value, ~r/[,+=\"\n<>#;]|^\s|\s$/),
      do: ~s("#{String.replace(value, "\"", "\"\"")}"),
      else: value
  end

  # The tax and registration numbers an authority-issued certificate carries.
  defp subject_attributes({:rdnSequence, rdns}) do
    for attributes <- rdns,
        {:AttributeTypeAndValue, oid, value} <- attributes,
        oid in [@organization_identifier, @serial_number],
        into: %{} do
      key =
        if oid == @organization_identifier, do: "organization_identifier", else: "serial_number"

      {key, attribute_text(value)}
    end
  end

  defp attribute_text({_string_type, value}), do: attribute_text(value)
  defp attribute_text(value) when is_list(value), do: List.to_string(value)

  # An attribute :public_key does not know arrives as its DER encoding.
  defp attribute_text(<<tag, rest::binary>>) when tag in [0x0C, 0x13, 0x16, 0x14, 0x1E] do
    {length, value} = der_length(rest)
    value = binary_part(value, 0, length)

    if tag == 0x1E,
      do: :unicode.characters_to_binary(value, {:utf16, :big}),
      else: value
  end

  defp attribute_text(value) when is_binary(value), do: value

  defp der_length(<<0::1, length::7, rest::binary>>), do: {length, rest}

  defp der_length(<<1::1, count::7, rest::binary>>) do
    <<length::unsigned-size(^count)-unit(8), value::binary>> = rest
    {length, value}
  end

  defp certificate_time({:utcTime, time}) do
    <<year::binary-size(2), rest::binary>> = List.to_string(time)
    year = String.to_integer(year)

    certificate_time(
      {:generalTime, ~c"#{if year >= 50, do: 1900 + year, else: 2000 + year}#{rest}"}
    )
  end

  defp certificate_time({:generalTime, time}) do
    <<year::binary-size(4), month::binary-size(2), day::binary-size(2), hour::binary-size(2),
      minute::binary-size(2), second::binary-size(2), "Z">> = List.to_string(time)

    {:ok, datetime, 0} =
      DateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}Z")

    datetime
  end
end
