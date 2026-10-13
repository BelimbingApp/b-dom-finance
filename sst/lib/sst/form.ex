defmodule Bilimbi.Finance.Sst.Form do
  @moduledoc """
  The SST-02 return's boxes, in the form's order, for each of the two taxes
  it is filed for: sales tax and service tax, each on its own form.

  The layout is the Royal Malaysian Customs Department's Borang SST-02 as
  amended on 2 October 2026, read with its completion guide, *Panduan
  Mengisi Penyata SST-02 (Secara Manual/Pindaan)* of 31 May 2026; the
  module README cites both. A box's `key` names it in this module's data
  (item 13A is `13aa`, since keys are lowercase); `item` is how the form
  prints it.

  Each box is one of:

  - `:rated`: a value and its tax at the box's `rate` percent (items 11(a)
    to 11(d)); a tax code mapped to it must carry that rate;
  - `:specific`: Second Schedule goods at specific rates (item 17), any
    rate;
  - `:value`: a value with no tax (Parts D and E); a tax code mapped to it
    must carry no tax;
  - `:tax`: a tax amount only (item 11(e) and the deductions of item 13);
  - `:total`: computed from other boxes (items 12 and 14).

  `sources` lists the modules whose tax codes may be mapped to a box, and
  `adjustable` whether a preparer may add an adjustment to it. Items the
  form asks for that no record here holds (Part A's particulars, Part B1's
  per-item lines, item 15's penalty, Part F's declaration) are left to the
  filing.
  """

  @tax_types ~w(sales_tax service_tax)

  @boxes %{
    "sales_tax" => [
      %{key: "11a", item: "11(a)", part: "B2", kind: :rated, rate: 5,
        label: "Taxable goods at 5%", sources: ["receivables"], adjustable: true},
      %{key: "11b", item: "11(b)", part: "B2", kind: :rated, rate: 10,
        label: "Taxable goods at 10%", sources: ["receivables"], adjustable: true},
      %{key: "12", item: "12", part: "B2", kind: :total, rate: nil,
        label: "Total tax payable", sources: [], adjustable: false},
      %{key: "13a", item: "13(a)", part: "B2", kind: :tax, rate: nil,
        label: "Deduction from credit notes", sources: [], adjustable: true},
      %{key: "13b", item: "13(b)", part: "B2", kind: :tax, rate: nil,
        label: "Sales tax deduction", sources: [], adjustable: true},
      %{key: "13d", item: "13(d)", part: "B2", kind: :tax, rate: nil,
        label: "Bad debt relief", sources: [], adjustable: true},
      %{key: "13aa", item: "13A", part: "B2", kind: :tax, rate: nil,
        label: "Adjustment of excess sales tax deduction claimed earlier", sources: [],
        adjustable: true},
      %{key: "14", item: "14", part: "B2", kind: :total, rate: nil,
        label: "Tax payable before penalty", sources: [], adjustable: false},
      %{key: "17", item: "17", part: "C", kind: :specific, rate: nil,
        label: "Second Schedule goods at specific rates", sources: ["receivables"],
        adjustable: true},
      %{key: "18a", item: "18(a)", part: "D", kind: :value, rate: nil,
        label: "Exports, and sales to a Special or Designated Area", sources: ["receivables"],
        adjustable: true},
      %{key: "18b1", item: "18(b)(1)", part: "D", kind: :value, rate: nil,
        label: "Sales exempted to Schedule A persons", sources: ["receivables"],
        adjustable: true},
      %{key: "18b2", item: "18(b)(2)", part: "D", kind: :value, rate: nil,
        label: "Sales exempted to Schedule B persons", sources: ["receivables"],
        adjustable: true},
      %{key: "18b3i", item: "18(b)(3)(i)", part: "D", kind: :value, rate: nil,
        label: "Sales exempted under Schedule C items 1 and 2", sources: ["receivables"],
        adjustable: true},
      %{key: "18b3ii", item: "18(b)(3)(ii)", part: "D", kind: :value, rate: nil,
        label: "Sales exempted under Schedule C items 3 and 4", sources: ["receivables"],
        adjustable: true},
      %{key: "18b3iii", item: "18(b)(3)(iii)", part: "D", kind: :value, rate: nil,
        label: "Work performed exempted under Schedule C item 5", sources: ["receivables"],
        adjustable: true},
      %{key: "18d", item: "18(d)", part: "D", kind: :value, rate: nil,
        label: "Sales exempted under section 35(3) or 61A", sources: ["receivables"],
        adjustable: true},
      %{key: "19", item: "19", part: "E", kind: :value, rate: nil,
        label: "Purchases exempted under Schedule C items 1 and 2", sources: ["payables"],
        adjustable: true},
      %{key: "20", item: "20", part: "E", kind: :value, rate: nil,
        label: "Purchases exempted under Schedule C items 3 and 4", sources: ["payables"],
        adjustable: true},
      %{key: "21", item: "21", part: "E", kind: :value, rate: nil,
        label: "Purchases exempted under Schedule C item 5", sources: ["payables"],
        adjustable: true}
    ],
    "service_tax" => [
      %{key: "11c", item: "11(c)", part: "B2", kind: :rated, rate: 6,
        label: "Taxable services at 6%", sources: ["receivables", "payables"],
        adjustable: true},
      %{key: "11d", item: "11(d)", part: "B2", kind: :rated, rate: 8,
        label: "Taxable services at 8%", sources: ["receivables", "payables"],
        adjustable: true},
      %{key: "11e", item: "11(e)", part: "B2", kind: :tax, rate: nil,
        label: "Group H item 1: credit and charge cards", sources: [], adjustable: true},
      %{key: "12", item: "12", part: "B2", kind: :total, rate: nil,
        label: "Total tax payable", sources: [], adjustable: false},
      %{key: "13a", item: "13(a)", part: "B2", kind: :tax, rate: nil,
        label: "Deduction from credit notes", sources: [], adjustable: true},
      %{key: "13c", item: "13(c)", part: "B2", kind: :tax, rate: nil,
        label: "Service tax deduction", sources: [], adjustable: true},
      %{key: "13d", item: "13(d)", part: "B2", kind: :tax, rate: nil,
        label: "Bad debt relief", sources: [], adjustable: true},
      %{key: "14", item: "14", part: "B2", kind: :total, rate: nil,
        label: "Tax payable before penalty", sources: [], adjustable: false},
      %{key: "18c1", item: "18(c)(1)", part: "D", kind: :value, rate: nil,
        label: "Services exempted business to business", sources: ["receivables"],
        adjustable: true},
      %{key: "18c2", item: "18(c)(2)", part: "D", kind: :value, rate: nil,
        label: "Services exempted under group relief", sources: ["receivables"],
        adjustable: true},
      %{key: "18c3", item: "18(c)(3)", part: "D", kind: :value, rate: nil,
        label: "Services exempted under section 34(3)(a)", sources: ["receivables"],
        adjustable: true},
      %{key: "18c4", item: "18(c)(4)", part: "D", kind: :value, rate: nil,
        label: "Other non-taxable services", sources: ["receivables"], adjustable: true}
    ]
  }

  # Item 12 sums the taxed boxes; item 14 deducts item 13 from it, as the
  # completion guide gives the formula for each tax.
  @totals %{
    "sales_tax" => %{"12" => {~w(11a 11b 17), []}, "14" => {~w(12), ~w(13a 13b 13d 13aa)}},
    "service_tax" => %{"12" => {~w(11c 11d 11e), []}, "14" => {~w(12), ~w(13a 13c 13d)}}
  }

  @doc "The two taxes a return is filed for."
  def tax_types, do: @tax_types

  @doc "The boxes of a tax's form, in the form's order."
  def boxes(tax_type) when tax_type in @tax_types do
    Enum.map(@boxes[tax_type], fn box ->
      Map.update!(box, :rate, &(&1 && Decimal.new(&1)))
    end)
  end

  @doc "One box of a tax's form, or nil."
  def box(tax_type, key) when tax_type in @tax_types,
    do: Enum.find(boxes(tax_type), &(&1.key == key))

  def box(_tax_type, _key), do: nil

  @doc "The tax whose form holds a box a tax code can be mapped to, or nil."
  def mapped_tax_type(key) do
    Enum.find(@tax_types, fn tax_type ->
      Enum.any?(@boxes[tax_type], &(&1.key == key and &1.sources != []))
    end)
  end

  @doc "The boxes a tax code of `source` may be mapped to, across both forms."
  def mappable_boxes(source) do
    for tax_type <- @tax_types,
        box <- boxes(tax_type),
        source in box.sources,
        do: Map.put(box, :tax_type, tax_type)
  end

  @doc "The boxes of a tax's form a preparer may adjust."
  def adjustable_boxes(tax_type), do: Enum.filter(boxes(tax_type), & &1.adjustable)

  @doc "Whether a box takes a value, a tax amount, or both."
  def columns(%{kind: kind}) when kind in [:rated, :specific], do: [:taxable, :tax]
  def columns(%{kind: :value}), do: [:taxable]
  def columns(%{kind: kind}) when kind in [:tax, :total], do: [:tax]

  @doc """
  The form's figures from each box's summed `{taxable, tax}`, rounded half
  up to `minor_units` per box: every box in order with its
  `taxable_amount` and `tax_amount` (nil where the box takes no such
  column), the totals computed from the rounded boxes.
  """
  def figures(tax_type, sums, minor_units) do
    rounded =
      tax_type
      |> boxes()
      |> Enum.reject(&(&1.kind == :total))
      |> Map.new(fn box ->
        {taxable, tax} = Map.get(sums, box.key, {zero(), zero()})
        {box.key, {round(taxable, minor_units), round(tax, minor_units)}}
      end)

    totals =
      Enum.reduce(["12", "14"], rounded, fn key, acc ->
        {added, deducted} = @totals[tax_type][key]
        tax = Decimal.sub(sum_tax(acc, added), sum_tax(acc, deducted))
        Map.put(acc, key, {zero(), tax})
      end)

    Enum.map(boxes(tax_type), fn box ->
      {taxable, tax} = Map.fetch!(totals, box.key)
      columns = columns(box)

      box
      |> Map.take([:key, :item, :part, :kind, :label, :rate])
      |> Map.merge(%{
        taxable_amount: if(:taxable in columns, do: taxable),
        tax_amount: if(:tax in columns, do: tax)
      })
    end)
  end

  @doc "The box holding the return's tax payable."
  def payable_box, do: "14"

  defp sum_tax(figures, keys),
    do: Enum.reduce(keys, zero(), fn key, acc -> Decimal.add(acc, elem(figures[key], 1)) end)

  defp round(amount, minor_units), do: Decimal.round(amount, minor_units, :half_up)
  defp zero, do: Decimal.new(0)
end
