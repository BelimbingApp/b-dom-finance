defmodule Bilimbi.Finance.Einvoice.MyInvois.Builder do
  @moduledoc """
  UBL 2.1 JSON for the MyInvois authority, from a plain document map.

  The builder maps; it does not compute or judge. Every amount arrives
  already calculated and every code already checked (`Validation` does
  that), so the same input always yields the same bytes, in the element
  order of the authority's SDK samples. `test/builder_golden_test.exs`
  rebuilds those samples byte for byte.

  The input is a map with atom keys:

    * `:id` (the code number), `:issue_date` (`"YYYY-MM-DD"`), `:issue_time`
      (`"HH:MM:SSZ"`, UTC), `:type_code`, `:version` (`"1.1"`),
      `:currency_code`, and optionally `:tax_currency_code` and
      `:tax_exchange_rate` (`%{source, target, rate}`);
    * optional `:invoice_period` (`%{start_date, end_date, description}`),
      `:billing_references` (`%{id}` for an additional document, or
      `%{id, uuid}` for the original of a note), and
      `:additional_document_references` (`%{id, document_type, description}`);
    * `:supplier` and `:buyer` parties, and an optional `:delivery`
      (`%{party, shipment}`), where a party is `%{name, identifications:
      [{scheme, id}], address, phone, email}` plus, for the supplier,
      `:industry_code` (`%{code, name}`) and an optional `:additional_account`
      (`%{id, scheme_agency_name}`), and an address is `%{city, postcode,
      state_code, lines, country_code}`;
    * optional `:payment_means` (`%{code, payee_account}`), `:payment_terms`,
      `:prepaid_payment` (`%{id, amount, date, time}`) and document-level
      `:allowance_charges` (`%{charge?, reason, amount}`);
    * `:tax_total` (`%{tax_amount, subtotals}`), `:totals`, and `:lines`.

  A tax subtotal is `%{taxable_amount, tax_amount, tax_type}` with an
  optional `:percent`, `:exemption_reason`, or `:per_unit` (`%{quantity,
  unit_code, amount}`). Tax amounts are written in the tax currency, every
  other amount in the document currency.
  """

  import Bilimbi.Finance.Einvoice.MyInvois.Json, only: [object: 1, value: 1, value: 2]

  @namespaces [
    {"_D", "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"},
    {"_A", "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"},
    {"_B", "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"}
  ]

  @tax_scheme [
    {"ID", value("OTH", [{"schemeID", "UN/ECE 5153"}, {"schemeAgencyID", "6"}])}
  ]

  @doc "The UBL document as an ordered JSON term (see `MyInvois.Json`)."
  @spec build(map()) :: Jason.OrderedObject.t()
  def build(document) do
    currency = Map.fetch!(document, :currency_code)
    tax_currency = Map.get(document, :tax_currency_code) || currency
    money = fn amount -> value(amount, [{"currencyID", currency}]) end
    tax_money = fn amount -> value(amount, [{"currencyID", tax_currency}]) end

    invoice =
      object([
        {"ID", value(document.id)},
        {"IssueDate", value(document.issue_date)},
        {"IssueTime", value(document.issue_time)},
        {"InvoiceTypeCode", value(document.type_code, [{"listVersionID", document.version}])},
        {"DocumentCurrencyCode", value(currency)},
        {"TaxCurrencyCode", value(Map.get(document, :tax_currency_code))},
        {"InvoicePeriod", optional(document, :invoice_period, &invoice_period/1)},
        {"BillingReference", many(document, :billing_references, &billing_reference/1)},
        {"AdditionalDocumentReference",
         many(document, :additional_document_references, &additional_reference/1)},
        {"AccountingSupplierParty", [supplier(document.supplier)]},
        {"AccountingCustomerParty", [object([{"Party", [buyer(document.buyer)]}])]},
        {"Delivery", optional(document, :delivery, &delivery(&1, money))},
        {"PaymentMeans", optional(document, :payment_means, &payment_means/1)},
        {"PaymentTerms", optional(document, :payment_terms, &object([{"Note", value(&1)}]))},
        {"PrepaidPayment", optional(document, :prepaid_payment, &prepaid(&1, money))},
        {"AllowanceCharge", many(document, :allowance_charges, &allowance_charge(&1, money))},
        {"TaxExchangeRate", optional(document, :tax_exchange_rate, &exchange_rate/1)},
        {"TaxTotal", [tax_total(document.tax_total, money, tax_money)]},
        {"LegalMonetaryTotal", [totals(document.totals, money)]},
        {"InvoiceLine", Enum.map(document.lines, &line(&1, money, tax_money))}
      ])

    object(@namespaces ++ [{"Invoice", [invoice]}])
  end

  defp optional(document, key, fun) do
    case Map.get(document, key) do
      nil -> nil
      value -> [fun.(value)]
    end
  end

  defp many(document, key, fun), do: document |> Map.get(key, []) |> Enum.map(fun)

  defp invoice_period(period) do
    object([
      {"StartDate", value(period[:start_date])},
      {"EndDate", value(period[:end_date])},
      {"Description", value(period[:description])}
    ])
  end

  defp billing_reference(%{uuid: uuid} = reference) when is_binary(uuid) do
    object([
      {"InvoiceDocumentReference", [object([{"ID", value(reference.id)}, {"UUID", value(uuid)}])]}
    ])
  end

  defp billing_reference(reference) do
    object([{"AdditionalDocumentReference", [object([{"ID", value(reference.id)}])]}])
  end

  defp additional_reference(reference) do
    object([
      {"ID", value(reference.id)},
      {"DocumentType", value(reference[:document_type])},
      {"DocumentDescription", value(reference[:description])}
    ])
  end

  ## Parties. Each role keeps the element order of the authority's samples.

  defp supplier(party) do
    object([
      {"AdditionalAccountID",
       optional(party, :additional_account, fn account ->
         object([{"_", account.id}, {"schemeAgencyName", account.scheme_agency_name}])
       end)},
      {"Party",
       [
         object([
           {"IndustryClassificationCode",
            value(party.industry_code.code, [{"name", party.industry_code.name}])},
           {"PartyIdentification", identifications(party)},
           {"PostalAddress", [address(party.address)]},
           {"PartyLegalEntity", legal_entity(party)},
           {"Contact", contact(party)}
         ])
       ]}
    ])
  end

  defp buyer(party) do
    object([
      {"PostalAddress", [address(party.address)]},
      {"PartyLegalEntity", legal_entity(party)},
      {"PartyIdentification", identifications(party)},
      {"Contact", contact(party)}
    ])
  end

  defp delivery_party(party) do
    object([
      {"PartyLegalEntity", legal_entity(party)},
      {"PostalAddress", [address(party.address)]},
      {"PartyIdentification", identifications(party)}
    ])
  end

  defp identifications(party) do
    Enum.map(party.identifications, fn {scheme, id} ->
      object([{"ID", value(id, [{"schemeID", scheme}])}])
    end)
  end

  defp legal_entity(party), do: [object([{"RegistrationName", value(party.name)}])]

  defp contact(party) do
    case object([
           {"Telephone", value(party[:phone])},
           {"ElectronicMail", value(party[:email])}
         ]) do
      %{values: []} -> nil
      contact -> [contact]
    end
  end

  defp address(address) do
    object([
      {"CityName", value(address.city)},
      {"PostalZone", value(address[:postcode])},
      {"CountrySubentityCode", value(address.state_code)},
      {"AddressLine", Enum.map(address.lines, &object([{"Line", value(&1)}]))},
      {"Country",
       [
         object([
           {"IdentificationCode",
            value(address.country_code, [{"listID", "ISO3166-1"}, {"listAgencyID", "6"}])}
         ])
       ]}
    ])
  end

  defp delivery(delivery, money) do
    object([
      {"DeliveryParty", optional(delivery, :party, &delivery_party/1)},
      {"Shipment", optional(delivery, :shipment, &shipment(&1, money))}
    ])
  end

  defp shipment(shipment, money) do
    object([
      {"ID", value(shipment.id)},
      {"FreightAllowanceCharge",
       optional(shipment, :freight_allowance_charge, &allowance_charge(&1, money))}
    ])
  end

  ## Payment

  defp payment_means(means) do
    object([
      {"PaymentMeansCode", value(means.code)},
      {"PayeeFinancialAccount", optional(means, :payee_account, &object([{"ID", value(&1)}]))}
    ])
  end

  defp prepaid(payment, money) do
    object([
      {"ID", value(payment[:id])},
      {"PaidAmount", money.(payment.amount)},
      {"PaidDate", value(payment[:date])},
      {"PaidTime", value(payment[:time])}
    ])
  end

  defp allowance_charge(allowance, money) do
    object([
      {"ChargeIndicator", value(allowance.charge?)},
      {"AllowanceChargeReason", value(allowance[:reason])},
      {"MultiplierFactorNumeric", value(allowance[:multiplier])},
      {"Amount", money.(allowance.amount)}
    ])
  end

  defp exchange_rate(rate) do
    object([
      {"SourceCurrencyCode", value(rate.source)},
      {"TargetCurrencyCode", value(rate.target)},
      {"CalculationRate", value(rate.rate)}
    ])
  end

  ## Tax and totals

  defp tax_total(total, money, tax_money) do
    object([
      {"TaxAmount", tax_money.(total.tax_amount)},
      {"TaxSubtotal", Enum.map(total.subtotals, &tax_subtotal(&1, money, tax_money))}
    ])
  end

  defp tax_subtotal(subtotal, money, tax_money) do
    per_unit = subtotal[:per_unit]

    object([
      {"TaxableAmount", money.(subtotal.taxable_amount)},
      {"TaxAmount", tax_money.(subtotal.tax_amount)},
      {"Percent", value(subtotal[:percent])},
      {"BaseUnitMeasure",
       per_unit && value(per_unit.quantity, [{"unitCode", per_unit.unit_code}])},
      {"PerUnitAmount", per_unit && tax_money.(per_unit.amount)},
      {"TaxCategory",
       [
         object([
           {"ID", value(subtotal.tax_type)},
           {"TaxExemptionReason", value(subtotal[:exemption_reason])},
           {"TaxScheme", [object(@tax_scheme)]}
         ])
       ]}
    ])
  end

  defp totals(totals, money) do
    object([
      {"LineExtensionAmount", money.(totals.line_extension_amount)},
      {"TaxExclusiveAmount", money.(totals.tax_exclusive_amount)},
      {"TaxInclusiveAmount", money.(totals.tax_inclusive_amount)},
      {"AllowanceTotalAmount", money.(totals[:allowance_total_amount])},
      {"ChargeTotalAmount", money.(totals[:charge_total_amount])},
      {"PayableRoundingAmount", money.(totals[:payable_rounding_amount])},
      {"PayableAmount", money.(totals.payable_amount)}
    ])
  end

  ## Lines

  defp line(line, money, tax_money) do
    object([
      {"ID", value(line.id)},
      {"InvoicedQuantity", value(line.quantity, [{"unitCode", line[:unit_code]}])},
      {"LineExtensionAmount", money.(line.line_extension_amount)},
      {"AllowanceCharge", many(line, :allowance_charges, &allowance_charge(&1, money))},
      {"TaxTotal", [tax_total(line.tax_total, money, tax_money)]},
      {"Item",
       [
         object([
           {"CommodityClassification",
            Enum.map(line.classifications, fn {list_id, code} ->
              object([{"ItemClassificationCode", value(code, [{"listID", list_id}])}])
            end)},
           {"Description", value(line.description)},
           {"OriginCountry",
            optional(line, :origin_country, &object([{"IdentificationCode", value(&1)}]))}
         ])
       ]},
      {"Price", [object([{"PriceAmount", money.(line.unit_price)}])]},
      {"ItemPriceExtension", [object([{"Amount", money.(line.subtotal)}])]}
    ])
  end
end
