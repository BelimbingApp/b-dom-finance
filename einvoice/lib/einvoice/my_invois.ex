defmodule Bilimbi.Finance.Einvoice.MyInvois do
  @moduledoc """
  The MyInvois clearance authority: its rules for a document, the mapping
  from a recorded document to its UBL 2.1 JSON (`MyInvois.Builder`), the
  JSON XAdES signature (`MyInvois.Signer`), and its API
  (`MyInvois.Client`).

  Rules follow the authority's e-Invoice Guideline v4.8 (30 August 2026) and
  its SDK as read on 12 October 2026, document format version 1.1, which
  turns on signature validation. Only individual invoices (type `01`) in
  ringgit are issued in this release; notes, foreign currencies,
  consolidated, and self-billed documents come later. The builder already
  writes every element the SDK's samples use, foreign currency included.
  """

  @behaviour Bilimbi.Finance.Einvoice.Authority

  import Ecto.Changeset

  alias Bilimbi.Finance.Einvoice.MyInvois.{Builder, Client, Signer}

  @version "1.1"
  # The authority reports tax in ringgit, whatever the document currency.
  @tax_currency "MYR"
  @registration_types ["BRN", "NRIC", "PASSPORT", "ARMY"]
  @exempt "E"
  # Tax types that charge tax, so a rate above zero; and those that take none.
  @taxed ["01", "02", "03", "04", "05"]
  @untaxed ["06", @exempt]

  @supplier_required [
    tax_id: "supplier TIN",
    registration_number: "supplier registration number",
    industry_code: "industry classification code",
    business_activity: "business activity",
    phone: "supplier phone",
    address_line1: "address line 1",
    city: "city",
    state_code: "state code",
    country_code: "country code"
  ]

  @impl true
  def id, do: "myinvois"

  @impl true
  def issuable_document_types, do: ["01"]

  @doc "The UBL format version documents are built in."
  def version, do: @version

  @impl true
  def valid_format?(kind, value), do: is_binary(value) and value =~ format(kind).pattern

  @impl true
  def format_message(kind), do: format(kind).message

  # Supplier settings and buyer details alike are checked against these.
  defp format(:tax_id),
    do: %{
      pattern: ~r/\A[A-Z]{1,2}[0-9]{8,12}\z/,
      message: "must be one or two capital letters and 8 to 12 digits"
    }

  defp format(:phone),
    do: %{
      pattern: ~r/\A\+[0-9]{8,19}\z/,
      message: "must be a plus sign and 8 to 20 digits, 20 characters at most"
    }

  defp format(:industry_code), do: %{pattern: ~r/\A[0-9]{5}\z/, message: "must be five digits"}
  defp format(:state_code), do: %{pattern: ~r/\A[0-9]{2}\z/, message: "must be two digits"}

  defp format(:country_code),
    do: %{pattern: ~r/\A[A-Z]{3}\z/, message: "must be three capital letters"}

  @impl true
  def supplier_missing(supplier),
    do: for({field, _label} <- @supplier_required, is_nil(supplier[field]), do: field)

  @impl true
  def certificate_identity(subject),
    do: %{
      tax_id: subject["organization_identifier"],
      registration_number: subject["serial_number"]
    }

  @impl true
  def login(scope, company_id, credentials) do
    case Client.login(scope, company_id, credentials) do
      {:ok, _token} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def validate(changeset, supplier, codes) do
    changeset
    |> validate_inclusion(:document_type, issuable_document_types(),
      message: "is not a document type this release issues"
    )
    |> validate_code(:document_type, codes.("document_type"))
    |> validate_code(:currency_code, codes.("currency"))
    |> validate_code(:payment_means_code, codes.("payment_means"))
    |> validate_tax_currency()
    |> validate_supplier(supplier, codes)
    |> update_embed(:buyer, &validate_buyer(&1, codes))
    |> update_embeds(:lines, &validate_line(&1, codes))
  end

  # The SDK's foreign-currency sample writes tax amounts in ringgit beside
  # document-currency totals without saying how they convert; until the
  # sandbox confirms the rule, only ringgit documents are issued.
  defp validate_tax_currency(changeset) do
    validate_change(changeset, :currency_code, fn :currency_code, currency ->
      if currency == @tax_currency,
        do: [],
        else: [currency_code: "must be #{@tax_currency} in this release"]
    end)
  end

  defp validate_supplier(changeset, supplier, codes) do
    missing = for field <- supplier_missing(supplier), do: @supplier_required[field]

    cond do
      missing != [] ->
        add_error(
          changeset,
          :supplier,
          "is incomplete: set #{Enum.join(missing, ", ")} in the e-invoice settings"
        )

      not Map.has_key?(codes.("industry"), supplier.industry_code) ->
        add_error(changeset, :supplier, "industry classification code is not a known code")

      not Map.has_key?(codes.("state"), supplier.state_code) ->
        add_error(changeset, :supplier, "state code is not a known code")

      not Map.has_key?(codes.("country"), supplier.country_code) ->
        add_error(changeset, :supplier, "country code is not a known code")

      true ->
        changeset
    end
  end

  defp validate_buyer(party, codes) do
    party
    |> validate_shape(:tax_id, :tax_id)
    |> validate_inclusion(:registration_type, @registration_types)
    |> validate_required([:phone])
    |> validate_shape(:phone, :phone)
    |> update_embed(:address, fn address ->
      address
      |> validate_code(:state_code, codes.("state"))
      |> validate_code(:country_code, codes.("country"))
    end)
  end

  defp validate_shape(changeset, field, kind) do
    validate_change(changeset, field, fn ^field, value ->
      if valid_format?(kind, value), do: [], else: [{field, format_message(kind)}]
    end)
  end

  defp validate_line(line, codes) do
    line
    |> validate_rate()
    |> validate_code(:classification_code, codes.("classification"))
    |> validate_code(:tax_type, codes.("tax_type"))
    |> validate_code(:unit_code, codes.("unit"))
    |> validate_code(:origin_country_code, codes.("country"))
    |> then(fn line ->
      if get_field(line, :tax_type) == @exempt and is_nil(get_field(line, :tax_exemption_reason)),
        do: add_error(line, :tax_exemption_reason, "is required for an exempt line"),
        else: line
    end)
  end

  defp validate_rate(line) do
    tax_type = get_field(line, :tax_type)
    rate = get_field(line, :tax_rate)

    cond do
      tax_type in @taxed and not Decimal.gt?(rate, 0) ->
        add_error(line, :tax_rate, "must be above 0 for this tax type")

      tax_type in @untaxed and not Decimal.eq?(rate, 0) ->
        add_error(line, :tax_rate, "must be 0 for this tax type")

      true ->
        line
    end
  end

  defp validate_code(changeset, field, codes) do
    validate_change(changeset, field, fn ^field, code ->
      if Map.has_key?(codes, code), do: [], else: [{field, "is not a known code"}]
    end)
  end

  defp update_embed(changeset, field, fun) do
    case get_change(changeset, field) do
      %Ecto.Changeset{} = embedded ->
        checked = fun.(embedded)

        changeset
        |> put_embed_change(field, checked)
        |> Map.update!(:valid?, &(&1 and checked.valid?))

      _other ->
        changeset
    end
  end

  defp update_embeds(changeset, field, fun) do
    case get_change(changeset, field) do
      embeds when is_list(embeds) ->
        checked = Enum.map(embeds, fun)

        changeset
        |> put_embed_change(field, checked)
        |> Map.update!(:valid?, &(&1 and Enum.all?(checked, fn line -> line.valid? end)))

      _other ->
        changeset
    end
  end

  # Swaps the checked embedded changesets in without re-casting them.
  defp put_embed_change(changeset, field, value),
    do: Map.update!(changeset, :changes, &Map.put(&1, field, value))

  ## Payload

  @impl true
  def payload(document, signing_key, %DateTime{} = signing_time) do
    bytes = document |> ubl() |> Builder.build() |> Signer.sign(signing_key, signing_time)
    %{format: "JSON", version: @version, bytes: bytes}
  end

  @doc """
  The builder's input for a recorded document (`Einvoice.get_document/3`'s
  map): parties from their snapshots, per-tax-type subtotals from the lines.
  """
  @spec ubl(map()) :: map()
  def ubl(document) do
    issued_at = DateTime.truncate(document.issued_at, :second)
    details = document.details

    %{
      id: document.code_number,
      issue_date: issued_at |> DateTime.to_date() |> Date.to_iso8601(),
      issue_time: (issued_at |> DateTime.to_time() |> Time.to_iso8601()) <> "Z",
      type_code: document.document_type,
      version: @version,
      currency_code: document.currency_code,
      tax_currency_code: @tax_currency,
      tax_exchange_rate:
        if(document.currency_code != @tax_currency,
          do: %{
            source: document.currency_code,
            target: @tax_currency,
            rate: document.exchange_rate
          }
        ),
      invoice_period: invoice_period(details),
      payment_means:
        if(details["payment_means_code"], do: %{code: details["payment_means_code"]}),
      payment_terms: details["payment_terms"],
      supplier: supplier(document.supplier),
      buyer: buyer(document.buyer),
      tax_total: %{
        tax_amount: document.tax_amount,
        subtotals: tax_subtotals(document.lines)
      },
      totals: %{
        line_extension_amount: document.line_extension_amount,
        tax_exclusive_amount: document.tax_exclusive_amount,
        tax_inclusive_amount: document.tax_inclusive_amount,
        payable_amount: document.payable_amount
      },
      lines: Enum.map(document.lines, &line/1)
    }
  end

  defp invoice_period(%{"billing_period_start" => start} = details) when is_binary(start) do
    %{
      start_date: start,
      end_date: details["billing_period_end"],
      description: details["billing_period_description"]
    }
  end

  defp invoice_period(_details), do: nil

  defp supplier(supplier) do
    %{
      name: supplier["name"],
      industry_code: %{code: supplier["industry_code"], name: supplier["business_activity"]},
      identifications: [
        {"TIN", supplier["tax_id"]},
        {"BRN", supplier["registration_number"]},
        {"SST", supplier["sales_tax_registration"] || "NA"},
        {"TTX", supplier["tourism_tax_registration"] || "NA"}
      ],
      address: address(supplier["address"]),
      phone: supplier["phone"],
      email: supplier["email"]
    }
  end

  defp buyer(buyer) do
    %{
      name: buyer["name"],
      identifications: [
        {"TIN", buyer["tax_id"]},
        {buyer["registration_type"], buyer["registration_number"]},
        {"SST", buyer["sales_tax_registration"] || "NA"},
        {"TTX", "NA"}
      ],
      address: address(buyer["address"]),
      phone: buyer["phone"],
      email: buyer["email"]
    }
  end

  defp address(address) do
    %{
      lines: address["lines"],
      city: address["city"],
      postcode: address["postcode"],
      state_code: address["state_code"],
      country_code: address["country_code"]
    }
  end

  defp tax_subtotals(lines) do
    lines
    |> Enum.group_by(& &1.tax_type)
    |> Enum.sort_by(fn {tax_type, _lines} -> tax_type end)
    |> Enum.map(fn {tax_type, lines} ->
      %{
        taxable_amount: sum(lines, :line_extension_amount),
        tax_amount: sum(lines, :tax_amount),
        tax_type: tax_type,
        exemption_reason:
          if(tax_type == @exempt, do: Enum.find_value(lines, & &1.tax_exemption_reason))
      }
    end)
  end

  defp line(line) do
    discount = discount_or_charge(false, "Discount", line.discount_amount)
    charge = discount_or_charge(true, "Charge", line.charge_amount)

    %{
      id: Integer.to_string(line.line_number),
      quantity: line.quantity,
      unit_code: line.unit_code,
      line_extension_amount: line.line_extension_amount,
      allowance_charges: Enum.reject([discount, charge], &is_nil/1),
      tax_total: %{
        tax_amount: line.tax_amount,
        subtotals: [
          %{
            taxable_amount: line.line_extension_amount,
            tax_amount: line.tax_amount,
            percent: line.tax_rate,
            tax_type: line.tax_type,
            exemption_reason: line.tax_exemption_reason
          }
        ]
      },
      classifications:
        Enum.reject([{"PTC", line.tariff_code}, {"CLASS", line.classification_code}], fn {_, code} ->
          is_nil(code)
        end),
      description: line.description,
      origin_country: line.origin_country_code,
      unit_price: line.unit_price,
      subtotal: line.subtotal
    }
  end

  defp discount_or_charge(charge?, reason, amount) do
    if Decimal.gt?(amount, 0), do: %{charge?: charge?, reason: reason, amount: amount}
  end

  defp sum(lines, field),
    do: Enum.reduce(lines, Decimal.new("0.00"), &Decimal.add(Map.fetch!(&1, field), &2))
end
