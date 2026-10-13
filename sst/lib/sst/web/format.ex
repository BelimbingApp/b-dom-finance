defmodule Bilimbi.Finance.Sst.Web.Format do
  @moduledoc false
  # Amounts, names, and refusals as the SST pages show them.

  alias Bilimbi.Finance.Sst

  @doc "A signed amount with thousands separators, rounded to the book's minor units."
  def money(nil, _minor_units), do: "—"

  def money(%Decimal{} = amount, minor_units) do
    rounded = Decimal.round(amount, minor_units)

    [whole | fraction] =
      rounded |> Decimal.abs() |> Decimal.to_string(:normal) |> String.split(".")

    grouped =
      whole
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(",", &Enum.join/1)
      |> String.reverse()

    sign = if Decimal.negative?(rounded), do: "-", else: ""
    sign <> Enum.join([grouped | fraction], ".")
  end

  def tax_name("sales_tax"), do: "Sales tax"
  def tax_name("service_tax"), do: "Service tax"

  def basis_name("payment"), do: "when payment is received"
  def basis_name("invoice"), do: "when invoiced (approved accrual basis)"
  def basis_name(nil), do: "—"

  def source_name("receivables"), do: "Receivables"
  def source_name("payables"), do: "Payables"

  def kind_name("invoice"), do: "Invoices"
  def kind_name("credit_note"), do: "Credit notes"
  def kind_name("bill"), do: "Bills"
  def kind_name("debit_note"), do: "Debit notes"

  def measure_name("documents"), do: "by document date"
  def measure_name("received"), do: "payments received"
  def measure_name("unpaid"), do: "unpaid twelve months"
  def measure_name("credited_after_due"), do: "credited after falling due"

  @doc "A box as `item label` from its tax's form, or the key when no form holds it."
  def box_name(_tax_type, nil), do: "Not reported"

  def box_name(tax_type, key) do
    case Enum.find(Sst.boxes(tax_type), &(&1.key == key)) do
      nil -> key
      box -> "#{box.item} #{box.label}"
    end
  end

  @doc "A mapped box named with the tax its form is for."
  def mapped_box_name(nil), do: "Not reported"

  def mapped_box_name(key) do
    Enum.find_value(Sst.tax_types(), key, fn tax_type ->
      case Enum.find(Sst.boxes(tax_type), &(&1.key == key)) do
        nil -> nil
        box -> "#{tax_name(tax_type)} #{box.item} #{box.label}"
      end
    end)
  end

  def actor(user_id, nil), do: "user #{user_id}"
  def actor(user_id, impersonator_id), do: "user #{user_id} (impersonated by #{impersonator_id})"

  @doc "The sentence a refusal from the facade reads as."
  def refusal(:unauthorized), do: "You do not have permission for that action."
  def refusal(:company_archived), do: "The company is archived; nothing can be changed."
  def refusal(:company_not_found), do: "The company could not be found."
  def refusal(:book_not_open), do: "The company's ledger book is not open yet."
  def refusal(:not_registered), do: "Record the company's SST registration first."

  def refusal(:not_registered_for_tax),
    do: "The registration holds no number for that tax."

  def refusal(:not_a_taxable_period),
    do: "That date does not start a taxable period of the registration's cycle."

  def refusal(:invalid_tax_type), do: "Choose sales tax or service tax."
  def refusal(:return_open), do: "That period already has an open return."

  def refusal(:return_finalised),
    do: "That return is finalised; its figures are fixed. Amend it to change them."

  def refusal(:return_discarded), do: "That return was discarded."
  def refusal(:return_not_found), do: "The return no longer exists."
  def refusal(:return_not_finalised), do: "Only a finalised return is amended."

  def refusal(:return_superseded),
    do: "A later finalised version amends that return; amend the latest one."

  def refusal(:period_overlaps), do: "That period overlaps another period's return."
  def refusal(:period_not_ended), do: "The period has not ended yet."
  def refusal(:adjustment_not_found), do: "The adjustment no longer exists."
  def refusal(:adjustment_withdrawn), do: "That adjustment is already withdrawn."
  def refusal(:tax_code_not_found), do: "That tax code no longer exists."
  def refusal(:invalid_source), do: "Choose a receivables or payables tax code."
  def refusal(:invalid_option), do: "The request was malformed."

  def refusal({:unmapped_tax_codes, rows}),
    do:
      "Map every tax code with tax in the period first: " <>
        Enum.map_join(rows, ", ", &"#{source_name(&1.source)} #{&1.tax_code}") <> "."

  def refusal({:rate_mismatch, rows}),
    do:
      "A tax code's rate does not fit its box: " <>
        Enum.map_join(rows, ", ", &"#{&1.tax_code} (#{Decimal.to_string(&1.rate, :normal)}%)") <>
        "."

  def refusal(%Ecto.Changeset{} = changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, options} ->
        Enum.reduce(options, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)
      |> Enum.map_join("; ", fn {field, messages} ->
        "#{field |> to_string() |> String.replace("_", " ")} #{Enum.join(List.wrap(messages), ", ")}"
      end)

    "Refused: #{errors}."
  end

  def refusal(reason), do: "It could not be done (#{inspect(reason)})."
end
