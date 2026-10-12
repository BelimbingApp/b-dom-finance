defmodule Bilimbi.Finance.Einvoice.ArtifactOwner do
  @moduledoc """
  The module's adapter for Base Artifacts: who may create, read, and
  delete a document's generated PDF, and how the PDF is rendered.

  A PDF is a regenerable visual of the stored record, not the record: the
  payload the authority validated lives in the submission. The render uses
  Base Artifacts' pure PDF serializer (`Bilimbi.Base.Artifacts.PDF.Renderer`),
  so it needs no browser or external tool and is deterministic for one
  document view. It prints the parties, lines, totals, status, the
  authority's identifiers, and the validation link whose QR code the
  document page shows.

  Every operation re-asks `finance.einvoice.view` for the company, as the
  facade does; a system scope is refused.
  """

  @behaviour Bilimbi.Base.Artifacts.Owner
  @behaviour Bilimbi.Base.Artifacts.PDF

  alias Bilimbi.Base.Artifacts.PDF.Renderer
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Einvoice.Configuration

  @view "finance.einvoice.view"
  @kind "document-pdf"

  @impl Bilimbi.Base.Artifacts.Owner
  def artifact_owner_id, do: "finance/einvoice"

  @doc "The artifact reference for a document's PDF."
  def reference(%{id: id}), do: %{subject: "document-#{id}", kind: @kind}

  @doc "The download name of a stored PDF, from its reference."
  def filename(%{subject: "document-" <> id}), do: "e-invoice-#{id}.pdf"
  def filename(_metadata), do: "e-invoice.pdf"

  @impl Bilimbi.Base.Artifacts.Owner
  def authorize(%Scope{} = scope, company_id, operation, reference)
      when operation in [:create, :read, :delete, :purge] do
    with true <-
           operation == :purge or match?(%{subject: "document-" <> _, kind: @kind}, reference),
         {:ok, _company} <- Company.authorize_company_target(scope, company_id, @view),
         true <- Company.live_company?(scope, company_id) do
      :ok
    else
      _refused -> {:error, :forbidden}
    end
  end

  @impl Bilimbi.Base.Artifacts.PDF
  def render_pdf(%Scope{}, _company_id, _reference, %{document: document}) do
    Renderer.render(%{
      title: "#{type_name(document.document_type)} #{document.code_number}",
      metadata: %{
        author: document.supplier["name"] || "",
        subject: "#{type_name(document.document_type)} #{document.code_number}",
        keywords:
          Enum.join(Enum.reject([document.document_uuid, document.long_id], &is_nil/1), " ")
      },
      blocks: blocks(document)
    })
  end

  def render_pdf(_scope, _company_id, _reference, _data), do: {:error, :invalid_document}

  defp blocks(document) do
    supplier = document.supplier
    buyer = document.buyer

    [
      {:text,
       Enum.join(
         [
           "#{String.upcase(type_name(document.document_type))} #{document.code_number}",
           "Issued #{DateTime.to_iso8601(document.issued_at)}",
           "Status: #{status_name(document.status)}",
           document.document_uuid && "Authority UUID: #{document.document_uuid}",
           document.validated_at && "Validated #{DateTime.to_iso8601(document.validated_at)}",
           document.validation_url && "Validation link: #{document.validation_url}",
           document.details["original_code_number"] &&
             "Original document: #{document.details["original_code_number"]} " <>
               "(#{document.details["original_document_uuid"]})"
         ]
         |> Enum.reject(&(&1 in [nil, false]))
         |> Enum.map(&latin1/1),
         "\n"
       )},
      {:table, ["Supplier", "Buyer"],
       [
         [party_text(supplier, "tax_id"), party_text(buyer, "tax_id")]
       ]},
      {:table, ["#", "Description", "Qty", "Unit price", "Amount", "Tax", "Tax amount"],
       Enum.map(document.lines, fn line ->
         [
           Integer.to_string(line.line_number),
           latin1(line.description),
           decimal(line.quantity),
           decimal(line.unit_price),
           decimal(line.line_extension_amount),
           "#{line.tax_type} #{decimal(line.tax_rate)}%",
           decimal(line.tax_amount)
         ]
       end)},
      {:table, ["Total", "Amount (#{document.currency_code})"],
       [
         ["Tax exclusive", decimal(document.tax_exclusive_amount)],
         ["Tax", decimal(document.tax_amount)],
         ["Tax inclusive", decimal(document.tax_inclusive_amount)],
         ["Payable", decimal(document.payable_amount)]
       ]},
      {:text,
       "Generated from the recorded document; the payload the authority validated is kept " <>
         "with its submission. Open the validation link, or scan its QR code on the document page, " <>
         "to confirm the document with the authority."}
    ]
  end

  defp party_text(party, id_key) do
    address = party["address"] || %{}

    [
      party["name"],
      "TIN #{party[id_key]}",
      party["registration_number"] && "Reg. #{party["registration_number"]}",
      Enum.join(List.wrap(address["lines"]), ", "),
      Enum.join(Enum.reject([address["postcode"], address["city"]], &is_nil/1), " "),
      Enum.join(Enum.reject([address["state_code"], address["country_code"]], &is_nil/1), " "),
      party["phone"],
      party["email"]
    ]
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.map_join("\n", &latin1/1)
  end

  defp decimal(nil), do: ""
  defp decimal(%Decimal{} = value), do: Decimal.to_string(Decimal.round(value, 2), :normal)

  # The serializer's font covers printable ASCII and Latin-1; anything
  # else is replaced visibly rather than refused.
  defp latin1(text) when is_binary(text) do
    text
    |> String.to_charlist()
    |> Enum.map(fn
      code when code in 32..126 or code in 160..255 -> code
      ?\n -> ?\n
      _other -> ??
    end)
    |> List.to_string()
  end

  defp latin1(other), do: to_string(other)

  defp type_name(type), do: Configuration.authority().document_type_name(type)

  defp status_name(nil), do: "recorded"
  defp status_name(status), do: status
end
