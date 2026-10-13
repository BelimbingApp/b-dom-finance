defmodule Bilimbi.Finance.Sst.Export do
  @moduledoc false
  # A return as CSV in the SST-02 item order, and as a printable HTML page.
  # Both name the return's status, so a draft is never mistaken for what
  # was finalised; every text value is escaped for its format.

  alias Bilimbi.Finance.Sst.Form

  @tax_names %{"sales_tax" => "Sales tax", "service_tax" => "Service tax"}

  def render(%{status: "discarded"}, _company, _format), do: {:error, :return_discarded}

  def render(report, company, :csv) do
    {:ok,
     %{
       filename: filename(report, "csv"),
       content_type: "text/csv",
       content: csv(report, company)
     }}
  end

  def render(report, company, :html) do
    {:ok,
     %{
       filename: filename(report, "html"),
       content_type: "text/html",
       content: html(report, company)
     }}
  end

  def render(_report, _company, _format), do: {:error, :invalid_option}

  defp filename(report, extension) do
    "sst-02-#{String.replace(report.tax_type, "_", "-")}-#{report.period_start}-" <>
      "#{report.period_end}-return-#{report.return_number}.#{extension}"
  end

  ## CSV

  defp csv(report, company) do
    figures = report.figures
    minor_units = figures.minor_units

    header = [
      ["part", "item", "description", "value", "tax"],
      ["A", "", "Status", status(report), ""],
      ["A", "", "Amendment", if(report.amends_return_id, do: "yes", else: "no"), ""],
      ["A", "1", "Type of return", @tax_names[report.tax_type], ""],
      ["A", "1", "SST registration number", report.registration_number || "", ""],
      ["A", "2", "Name", company.name, ""],
      ["A", "3", "Taxable period from", Date.to_iso8601(report.period_start), ""],
      ["A", "3", "Taxable period to", Date.to_iso8601(report.period_end), ""],
      ["A", "4", "Return and payment due date", Date.to_iso8601(report.due_date), ""],
      ["A", "", "Currency", figures.currency_code, ""]
    ]

    boxes =
      for box <- figures.boxes do
        [
          box.part,
          box.item,
          box.label,
          amount(box.taxable_amount, minor_units),
          amount(box.tax_amount, minor_units)
        ]
      end

    pins = [
      ["", "", "Read through ledger entry", to_string(figures.through_entry_number), ""],
      ["", "", "Read through mapping", to_string(figures.through_mapping_number), ""]
    ]

    Enum.map_join(
      header ++ boxes ++ pins,
      "",
      &(Enum.map_join(&1, ",", fn cell -> cell(cell) end) <> "\r\n")
    )
  end

  defp status(%{status: "finalised", version: version}), do: "Finalised, version #{version}"
  defp status(_report), do: "Draft, not finalised"

  defp amount(nil, _minor_units), do: ""

  defp amount(amount, minor_units),
    do: amount |> Decimal.round(minor_units) |> Decimal.to_string(:normal)

  # RFC 4180 quoting, and a leading quote on text a spreadsheet would read
  # as a formula; amounts are written as plain numbers.
  defp cell(value) do
    text = to_string(value)

    text =
      if String.match?(text, ~r/^[=+\-@\t\r]/) and not String.match?(text, ~r/^-?\d+(\.\d+)?$/),
        do: "'" <> text,
        else: text

    if String.contains?(text, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(text, "\"", "\"\"") <> "\"",
      else: text
  end

  ## HTML

  defp html(report, company) do
    figures = report.figures
    minor_units = figures.minor_units

    rows =
      Enum.map_join(figures.boxes, "\n", fn box ->
        "<tr class=\"#{if box.kind == :total, do: "total", else: ""}\"><td>#{e(box.item)}</td>" <>
          "<td>#{e(box.label)}</td><td class=\"n\">#{e(amount(box.taxable_amount, minor_units))}</td>" <>
          "<td class=\"n\">#{e(amount(box.tax_amount, minor_units))}</td></tr>"
      end)

    adjustments =
      report.adjustments
      |> Enum.filter(& &1.standing)
      |> Enum.map_join("\n", fn a ->
        box = Form.box(report.tax_type, a.box)

        "<tr><td>#{e(box && box.item)}</td><td>#{e(a.description)}#{if a.reference, do: " (" <> e(a.reference) <> ")", else: ""}</td>" <>
          "<td class=\"n\">#{e(amount(a.taxable_amount, minor_units))}</td>" <>
          "<td class=\"n\">#{e(amount(a.tax_amount, minor_units))}</td></tr>"
      end)

    accounts =
      Enum.map_join(figures.accounts, "\n", fn a ->
        "<tr><td>#{e(a.account_code)} #{e(a.account_name)}</td>" <>
          "<td class=\"n\">#{e(amount(Decimal.sub(a.ledger_credits, a.ledger_debits), minor_units))}</td>" <>
          "<td class=\"n\">#{e(amount(Decimal.sub(a.document_credits, a.document_debits), minor_units))}</td>" <>
          "<td class=\"n\">#{e(amount(a.difference, minor_units))}</td></tr>"
      end)

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>SST-02 #{e(@tax_names[report.tax_type])} #{report.period_start} to #{report.period_end}</title>
    <style>
    body { font: 12px/1.4 system-ui, sans-serif; color: #111; margin: 24px; }
    h1 { font-size: 18px; margin: 0 0 4px; }
    h2 { font-size: 14px; margin: 20px 0 6px; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #999; padding: 4px 6px; text-align: left; vertical-align: top; }
    td.n, th.n { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
    tr.total td { font-weight: 600; background: #f2f2f2; }
    .draft { border: 2px solid #b00; color: #b00; padding: 6px 10px; display: inline-block; font-weight: 600; }
    dl { display: grid; grid-template-columns: max-content 1fr; gap: 2px 12px; margin: 0; }
    dt { color: #555; }
    @media print { body { margin: 0; } }
    </style>
    </head>
    <body>
    <h1>SST-02: #{e(@tax_names[report.tax_type])} return</h1>
    #{if report.status == "finalised", do: "<p>#{e(status(report))}, read through ledger entry #{figures.through_entry_number} and mapping #{figures.through_mapping_number}.</p>", else: "<p class=\"draft\">Draft: not finalised. Its figures change as documents post.</p>"}
    <h2>Part A</h2>
    <dl>
    <dt>1. Type of return</dt><dd>#{e(@tax_names[report.tax_type])}#{if report.amends_return_id, do: " (amendment)", else: ""}</dd>
    <dt>1. SST registration number</dt><dd>#{e(report.registration_number)}</dd>
    <dt>2. Name</dt><dd>#{e(company.name)}</dd>
    <dt>3. Taxable period</dt><dd>#{report.period_start} to #{report.period_end}</dd>
    <dt>4. Return and payment due date</dt><dd>#{report.due_date}</dd>
    <dt>Currency</dt><dd>#{e(figures.currency_code)}</dd>
    </dl>
    <h2>Items</h2>
    <table>
    <thead><tr><th>Item</th><th>Description</th><th class="n">Value</th><th class="n">Tax</th></tr></thead>
    <tbody>
    #{rows}
    </tbody>
    </table>
    <h2>Adjustments</h2>
    <table>
    <thead><tr><th>Item</th><th>Description</th><th class="n">Value</th><th class="n">Tax</th></tr></thead>
    <tbody>
    #{if adjustments == "", do: "<tr><td colspan=\"4\">None.</td></tr>", else: adjustments}
    </tbody>
    </table>
    <h2>Ledger reconciliation</h2>
    <table>
    <thead><tr><th>Tax account</th><th class="n">Ledger, credits less debits</th><th class="n">Documents</th><th class="n">Difference</th></tr></thead>
    <tbody>
    #{if accounts == "", do: "<tr><td colspan=\"4\">No tax account.</td></tr>", else: accounts}
    </tbody>
    </table>
    <p>Items 15 (penalty) and 16, Part B1's item lines, and Part F's declaration are completed when the return is filed.</p>
    </body>
    </html>
    """
  end

  defp e(nil), do: ""

  defp e(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
