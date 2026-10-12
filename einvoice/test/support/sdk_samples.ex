defmodule Bilimbi.Finance.Einvoice.SdkSamples do
  @moduledoc """
  The MyInvois SDK's four version 1.1 JSON invoice samples, as builder input
  and as the signed files the SDK publishes (`test/fixtures/sdk/`, from
  https://sdk.myinvois.hasil.gov.my/documents/invoice-v1-1/, read on
  12 October 2026). The values are the SDK's placeholders; its signing
  certificate is the SDK's dummy test certificate.

  Amounts keep the samples' written form (`1500.0` stays `1500.0`), and the
  samples' figures are the SDK's: they do not all add up, which is why the
  builder maps without computing.
  """

  @fixtures Path.expand("../fixtures/sdk", __DIR__)

  @doc "The published signed sample's bytes."
  def signed!("Invoice"), do: File.read!(Path.join(@fixtures, "1.1-Invoice-Sample.json"))
  def signed!(name), do: File.read!(Path.join(@fixtures, "1.1-Invoice-#{name}-Sample.json"))

  @doc "Every published sample's name."
  def names, do: ["Invoice", "MultiLineItem", "ForeignCurrency", "Consolidated"]

  defp d(text), do: Decimal.new(text)

  @address %{
    city: "Kuala Lumpur",
    postcode: "50480",
    state_code: "10",
    lines: ["Lot 66", "Bangunan Merdeka", "Persiaran Jaya"],
    country_code: "MYS"
  }

  defp supplier(additional_account?) do
    %{
      additional_account:
        if(additional_account?,
          do: %{id: "CPT-CCN-W-211111-KL-000002", scheme_agency_name: "CertEX"}
        ),
      industry_code: %{
        code: "46510",
        name: "Wholesale of computer hardware, software and peripherals"
      },
      identifications: [
        {"TIN", "Supplier's TIN"},
        {"BRN", "Supplier's BRN"},
        {"SST", "NA"},
        {"TTX", "NA"}
      ],
      address: @address,
      name: "Supplier's Name",
      phone: "+60123456789",
      email: "supplier@email.com"
    }
  end

  defp buyer do
    %{
      address: @address,
      name: "Buyer's Name",
      identifications: [
        {"TIN", "Buyer's TIN"},
        {"BRN", "Buyer's BRN"},
        {"SST", "NA"},
        {"TTX", "NA"}
      ],
      phone: "+60123456789",
      email: "buyer@email.com"
    }
  end

  @doc "Builder input that reproduces the named sample."
  def input("Invoice") do
    %{
      id: "JSON-INV12345",
      issue_date: "2024-07-23",
      issue_time: "00:30:00Z",
      type_code: "01",
      version: "1.1",
      currency_code: "MYR",
      tax_currency_code: "MYR",
      invoice_period: %{start_date: "2024-01-01", end_date: "2024-07-31", description: "Monthly"},
      billing_references: [%{id: "E12345678912"}],
      additional_document_references: [
        %{id: "E12345678912", document_type: "CustomsImportForm"},
        %{id: "sa313321312", document_type: "213312dddddd", description: "asddasdwqfd ddq"},
        %{id: "E12345678912", document_type: "K2"},
        %{id: "CIF"}
      ],
      supplier: supplier(true),
      buyer: buyer(),
      delivery: %{
        party: %{
          name: "Recipient's Name",
          address: @address,
          identifications: [{"TIN", "Recipient's TIN"}, {"BRN", "Recipient's BRN"}]
        },
        shipment: %{
          id: "1234",
          freight_allowance_charge: %{charge?: true, reason: "Service charge", amount: d("100")}
        }
      },
      payment_means: %{code: "03", payee_account: "1234567890123"},
      payment_terms: "Payment method is cash",
      prepaid_payment: %{
        id: "E12345678912",
        amount: d("1"),
        date: "2024-07-23",
        time: "00:30:00Z"
      },
      allowance_charges: [
        %{charge?: false, reason: "Sample Description", amount: d("100")},
        %{charge?: true, reason: "Service charge", amount: d("100")}
      ],
      tax_total: %{
        tax_amount: d("87.63"),
        subtotals: [%{taxable_amount: d("87.63"), tax_amount: d("87.63"), tax_type: "01"}]
      },
      totals: %{
        line_extension_amount: d("1436.5"),
        tax_exclusive_amount: d("1436.5"),
        tax_inclusive_amount: d("1436.5"),
        allowance_total_amount: d("1436.5"),
        charge_total_amount: d("1436.5"),
        payable_rounding_amount: d("0.3"),
        payable_amount: d("1436.5")
      },
      lines: [
        %{
          id: "1234",
          quantity: d("1"),
          unit_code: "C62",
          line_extension_amount: d("1436.5"),
          allowance_charges: [
            %{
              charge?: false,
              reason: "Sample Description",
              multiplier: d("0.15"),
              amount: d("100")
            },
            %{charge?: true, reason: "Sample Description", multiplier: d("0.1"), amount: d("100")}
          ],
          tax_total: %{
            tax_amount: d("1460.5"),
            subtotals: [
              %{
                taxable_amount: d("1460.5"),
                tax_amount: d("1460.5"),
                percent: d("6"),
                tax_type: "E",
                exemption_reason: "Exempt New Means of Transport"
              }
            ]
          },
          classifications: [{"PTC", "9800.00.0010"}, {"CLASS", "003"}],
          description: "Laptop Peripherals",
          origin_country: "MYS",
          unit_price: d("17"),
          subtotal: d("100")
        }
      ]
    }
  end

  def input("ForeignCurrency") do
    "Invoice"
    |> input()
    |> Map.merge(%{
      currency_code: "USD",
      tax_exchange_rate: %{source: "USD", target: "MYR", rate: d("4.72")}
    })
  end

  def input("MultiLineItem") do
    zero_allowances = [
      %{charge?: false, reason: "", multiplier: d("0.0"), amount: d("0.0")},
      %{charge?: true, reason: "", multiplier: d("0.0"), amount: d("0.0")}
    ]

    line = fn id, amount, tariff, description, subtotals, tax ->
      %{
        id: id,
        quantity: d("1"),
        unit_code: "C62",
        line_extension_amount: d(amount),
        allowance_charges: zero_allowances,
        tax_total: %{tax_amount: d(tax), subtotals: subtotals},
        classifications: [{"PTC", tariff}, {"CLASS", "003"}],
        description: description,
        origin_country: "MYS",
        unit_price: d(amount),
        subtotal: d(amount)
      }
    end

    "Invoice"
    |> input()
    |> Map.drop([:delivery, :payment_means, :payment_terms, :prepaid_payment])
    |> Map.merge(%{
      issue_date: "2025-02-06",
      invoice_period: %{start_date: "2025-01-01", end_date: "2025-01-31", description: "Monthly"},
      additional_document_references: [
        %{id: "E23456789123,E98765432123", document_type: "CustomsImportForm"},
        %{
          id: "FTA",
          document_type: "FreeTradeAgreement",
          description: "ASEAN-Australia-New Zealand FTA (AANZFTA)"
        },
        %{id: "E12345678912,E23456789123", document_type: "K2"},
        %{id: "CIF"}
      ],
      allowance_charges: [
        %{charge?: false, reason: "", amount: d("0.0")},
        %{charge?: true, reason: "", amount: d("0.0")}
      ],
      tax_total: %{
        tax_amount: d("85.0"),
        subtotals: [
          %{
            taxable_amount: d("2000.0"),
            tax_amount: d("100.0"),
            tax_type: "E",
            exemption_reason: "Special case"
          }
        ]
      },
      totals: %{
        line_extension_amount: d("4500.0"),
        tax_exclusive_amount: d("4500.0"),
        tax_inclusive_amount: d("4585.0"),
        allowance_total_amount: d("0.0"),
        charge_total_amount: d("0.0"),
        payable_rounding_amount: d("0.0"),
        payable_amount: d("4585.0")
      },
      lines: [
        line.(
          "001",
          "1000.0",
          "9800.00.0010",
          "Computer Monitor",
          [
            %{
              taxable_amount: d("1000.0"),
              tax_amount: d("10.0"),
              per_unit: %{quantity: d("1"), unit_code: "C62", amount: d("10.0")},
              tax_type: "01"
            }
          ],
          "10.0"
        ),
        line.(
          "002",
          "1500.0",
          "9800.00.0011",
          "Laptop Peripherals",
          [
            %{
              taxable_amount: d("1500.0"),
              tax_amount: d("75.0"),
              percent: d("5.0"),
              tax_type: "02"
            }
          ],
          "75.0"
        ),
        line.(
          "003",
          "2000.0",
          "9800.00.0012",
          "Wireless Mouse",
          [
            %{taxable_amount: d("0.0"), tax_amount: d("0.0"), percent: d("5.0"), tax_type: "01"},
            %{
              taxable_amount: d("2000.0"),
              tax_amount: d("100.0"),
              tax_type: "E",
              exemption_reason: "Special Case"
            }
          ],
          "0.0"
        )
      ]
    })
  end

  def input("Consolidated") do
    line = fn id, amount, tax, description ->
      %{
        id: id,
        quantity: d("1"),
        unit_code: "C62",
        line_extension_amount: d(amount),
        tax_total: %{
          tax_amount: d(tax),
          subtotals: [
            %{taxable_amount: d(amount), tax_amount: d(tax), percent: d("10"), tax_type: "01"}
          ]
        },
        classifications: [{"CLASS", "004"}],
        description: description,
        origin_country: "MYS",
        unit_price: d(amount),
        subtotal: d(amount)
      }
    end

    %{
      id: "JSON-INV12345",
      issue_date: "2024-07-23",
      issue_time: "00:30:00Z",
      type_code: "01",
      version: "1.1",
      currency_code: "MYR",
      tax_currency_code: "MYR",
      supplier: supplier(false),
      buyer: %{
        address: %{city: "", postcode: "", state_code: "", lines: ["NA", "", ""], country_code: ""},
        name: "Consolidated Buyer's",
        identifications: [
          {"TIN", "EI00000000010"},
          {"BRN", "NA"},
          {"SST", "NA"},
          {"TTX", "NA"}
        ],
        phone: "NA",
        email: "NA"
      },
      tax_total: %{
        tax_amount: d("3000"),
        subtotals: [%{taxable_amount: d("30000"), tax_amount: d("3000"), tax_type: "01"}]
      },
      totals: %{
        line_extension_amount: d("30000"),
        tax_exclusive_amount: d("30000"),
        tax_inclusive_amount: d("33000"),
        payable_amount: d("33000")
      },
      lines: [
        line.("1", "10000", "1000", "Receipt 001 - 100"),
        line.("2", "20000", "2000", "Receipt 101 - 200")
      ]
    }
  end
end
