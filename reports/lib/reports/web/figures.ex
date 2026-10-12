defmodule Bilimbi.Finance.Reports.Web.Figures do
  @moduledoc false

  # Presentation shared by the report pages: amounts in the book's minor
  # units, and the grouped statement table.

  use Bilimbi.Base.UI, :html

  @doc """
  An amount at the book's decimal places with thousands grouped, such as
  `-1,234.50`. Amounts are exact decimals; this only pads or rounds a
  computed total for display.
  """
  def amount(%Decimal{} = amount, minor_units) do
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

    sign = if Decimal.lt?(rounded, 0), do: "-", else: ""
    Enum.join([sign <> grouped | fraction], ".")
  end

  @doc "A reporting period or date as the column heading reads it."
  def column_label(%{from: from, to: to}), do: "#{Date.to_iso8601(from)} – #{Date.to_iso8601(to)}"
  def column_label(%{as_of: as_of}), do: "As of #{Date.to_iso8601(as_of)}"

  @doc "The heading of an account type's group."
  def type_label("asset"), do: "Assets"
  def type_label("liability"), do: "Liabilities"
  def type_label("equity"), do: "Equity"
  def type_label("income"), do: "Income"
  def type_label("expense"), do: "Expenses"

  @doc """
  A statement: groups of sections of account rows, each amount linking to
  the entries behind it, with section, group and statement totals.

  The rows stay local rather than going through `<.table>`: a statement
  needs group and section heading rows and total rows between the account
  rows, which `table/1` does not render. The geometry follows DESIGN.md
  "Data tables & row density".
  """
  attr(:id, :string, required: true)
  attr(:columns, :list, required: true, doc: "the report's columns, in order")
  attr(:minor_units, :integer, required: true)

  attr(:groups, :list,
    required: true,
    doc:
      "`%{id, label, sections, extras, total_label, totals}`; extras are `{id, label, amounts}`"
  )

  attr(:footer, :list, default: [], doc: "`{id, label, amounts}` rows under every group")
  attr(:drill, :any, required: true, doc: "row and column to the path of the entries behind it")

  def statement(assigns) do
    assigns = assign(assigns, :width, length(assigns.columns) + 1)

    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="w-full text-sm text-ink">
        <thead class="bg-surface-sunken">
          <tr>
            <th scope="col" class="px-2 py-1.5 text-left text-xs font-semibold text-ink-subtle">
              Account
            </th>
            <th
              :for={column <- @columns}
              scope="col"
              class="px-2 py-1.5 text-right text-xs font-semibold text-ink-subtle tabular-nums"
            >
              {column_label(column)}
            </th>
          </tr>
        </thead>
        <tbody :for={group <- @groups} id={"#{@id}-#{group.id}"} class="border-t border-line">
          <tr :if={group.label}>
            <th colspan={@width} scope="rowgroup" class="px-2 pt-3 pb-1 text-left font-semibold">
              {group.label}
            </th>
          </tr>
          <%= for {section, index} <- Enum.with_index(group.sections) do %>
            <tr :if={section.name} id={"#{@id}-#{group.id}-section-#{index}"}>
              <th
                colspan={@width}
                scope="rowgroup"
                class="px-2 pt-2 pb-0.5 text-left text-xs font-semibold text-ink-muted"
              >
                {section.name}
              </th>
            </tr>
            <tr :for={row <- section.rows} id={"#{@id}-account-#{row.account_id}"}>
              <td class={["py-0.5 pr-2", if(section.name, do: "pl-5", else: "pl-2")]}>
                <span class="tabular-nums text-ink-muted">{row.code}</span>
                <span class="ml-1.5">{row.name}</span>
              </td>
              <td
                :for={{amount, column_index} <- Enum.with_index(row.amounts)}
                class="px-2 py-0.5 text-right tabular-nums"
              >
                <.link
                  navigate={@drill.(row, Enum.at(@columns, column_index))}
                  id={"#{@id}-account-#{row.account_id}-#{column_index}"}
                  class="hover:underline"
                >
                  {amount(amount, @minor_units)}
                </.link>
              </td>
            </tr>
            <tr :if={section.name} class="text-ink-muted">
              <td class="py-0.5 pr-2 pl-5">Total {section.name}</td>
              <td :for={amount <- section.totals} class="px-2 py-0.5 text-right tabular-nums">
                {amount(amount, @minor_units)}
              </td>
            </tr>
          <% end %>
          <tr :for={{id, label, amounts} <- group.extras} id={"#{@id}-#{id}"}>
            <td class="px-2 py-0.5 italic">{label}</td>
            <td :for={amount <- amounts} class="px-2 py-0.5 text-right tabular-nums">
              {amount(amount, @minor_units)}
            </td>
          </tr>
          <tr id={"#{@id}-#{group.id}-total"} class="border-t border-line font-semibold">
            <td class="px-2 py-1">{group.total_label}</td>
            <td :for={amount <- group.totals} class="px-2 py-1 text-right tabular-nums">
              {amount(amount, @minor_units)}
            </td>
          </tr>
        </tbody>
        <tfoot :if={@footer != []} class="border-t-2 border-high-contrast-line">
          <tr :for={{id, label, amounts} <- @footer} id={"#{@id}-#{id}"} class="font-semibold">
            <td class="px-2 py-1.5">{label}</td>
            <td :for={amount <- amounts} class="px-2 py-1.5 text-right tabular-nums">
              {amount(amount, @minor_units)}
            </td>
          </tr>
        </tfoot>
      </table>
    </div>
    """
  end
end
