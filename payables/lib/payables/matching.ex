defmodule Bilimbi.Finance.Payables.Matching do
  @moduledoc false
  # The three-way match: each bill line that names an order line is compared
  # with what the order source says was ordered and received, less what this
  # module already billed against that line, within the company's
  # tolerances. The result is the figures compared and the exceptions found,
  # which the facade records as a match event. Callers authorize first.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Payables.{Document, DocumentLine, OrderSource}

  @open_order_statuses ~w(approved sent partially_received closed)
  @hundred Decimal.new(100)

  # One per rule; the migration's check lists the same codes.
  @exception_codes ~w(
    order_source_unavailable
    order_line_not_found
    order_line_superseded
    order_not_open
    currency_mismatch
    quantity_exceeds_ordered
    quantity_exceeds_received
    price_differs
  )

  @doc "The codes an exception carries, one per rule the match applies."
  def exception_codes, do: @exception_codes

  @doc "The order statuses a bill is matched against; any other order is not open to billing."
  def open_order_statuses, do: @open_order_statuses

  @doc """
  Matches the bill's order lines: `{:ok, lines}`, one result per bill line
  naming an order line, each with the figures compared and `exceptions`
  (`%{code, detail}`), empty when the line matched. The source answering
  that the line is missing is an exception; the source refusing the actor
  is `{:error, {:order_source, reason}}`, which rolls the posting back.
  """
  def evaluate(scope, company_id, %Document{} = document, settings, book) do
    lines = Enum.filter(document.lines, &(not is_nil(&1.order_line_id)))
    ids = lines |> Enum.map(& &1.order_line_id) |> Enum.uniq()
    billed = billed_quantities(scope, company_id, ids, document.id)
    tolerances = tolerances(settings)

    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, results} ->
      case match_line(scope, company_id, line, billed, tolerances, book) do
        {:ok, result} -> {:cont, {:ok, results ++ [result]}}
        {:error, reason} -> {:halt, {:error, {:order_source, reason}}}
      end
    end)
  end

  @doc """
  The quantity billed against each order line, by ID: the quantities of
  posted bill lines naming it, less those of posted debit note lines, in the
  company. `except` leaves one document out, for the document being matched.
  """
  def billed_quantities(_scope, _company_id, [], _except), do: %{}

  def billed_quantities(scope, company_id, order_line_ids, except) do
    from(l in Tenancy.scope_query(DocumentLine, scope),
      join: d in ^Tenancy.scope_query(Document, scope),
      on: d.id == l.document_id,
      where: l.company_id == ^company_id and l.order_line_id in ^order_line_ids,
      where: d.status == "posted",
      group_by: l.order_line_id,
      select:
        {l.order_line_id,
         sum(
           fragment(
             "CASE WHEN ? = 'bill' THEN ? ELSE -? END",
             d.document_type,
             l.quantity,
             l.quantity
           )
         )}
    )
    |> then(&if(except, do: where(&1, [l], l.document_id != ^except), else: &1))
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The quantities a debit note's order lines take back, checked against the
  corrected bill: each order line is one the bill names, and the quantity
  with what earlier posted debit notes took back fits what the bill billed.
  `{:error, {line_number, field, message}}` names the first line that does not.
  """
  def within_billed(scope, company_id, %Document{} = bill, lines, except) do
    billed_on_bill =
      bill.lines
      |> Enum.filter(& &1.order_line_id)
      |> Enum.group_by(& &1.order_line_id, & &1.quantity)
      |> Map.new(fn {id, quantities} -> {id, Enum.reduce(quantities, &Decimal.add/2)} end)

    ids = Map.keys(billed_on_bill)

    taken_back =
      if ids == [] do
        %{}
      else
        from(l in Tenancy.scope_query(DocumentLine, scope),
          join: d in ^Tenancy.scope_query(Document, scope),
          on: d.id == l.document_id,
          where: l.company_id == ^company_id and l.order_line_id in ^ids,
          where: d.status == "posted" and d.corrects_document_id == ^bill.id,
          group_by: l.order_line_id,
          select: {l.order_line_id, sum(l.quantity)}
        )
        |> then(&if(except, do: where(&1, [l], l.document_id != ^except), else: &1))
        |> Repo.all()
        |> Map.new()
      end

    lines
    |> Enum.filter(& &1.order_line_id)
    |> Enum.group_by(& &1.order_line_id)
    |> Enum.reduce_while(:ok, fn {order_line_id, note_lines}, :ok ->
      taking = note_lines |> Enum.map(& &1.quantity) |> Enum.reduce(&Decimal.add/2)
      first = hd(note_lines).line_number

      case Map.get(billed_on_bill, order_line_id) do
        nil ->
          {:halt, {:error, {first, :order_line_id, "is not an order line of the corrected bill"}}}

        billed ->
          taken = Map.get(taken_back, order_line_id, Decimal.new(0))

          if Decimal.gt?(Decimal.add(taking, taken), billed),
            do:
              {:halt,
               {:error, {first, :quantity, "exceeds the quantity billed on the corrected bill"}}},
            else: {:cont, :ok}
      end
    end)
  end

  defp tolerances(settings) do
    Map.take(settings, [
      :quantity_tolerance_kind,
      :quantity_tolerance,
      :price_tolerance_kind,
      :price_tolerance
    ])
  end

  defp match_line(scope, company_id, line, billed, tolerances, book) do
    previously = Map.get(billed, line.order_line_id, Decimal.new(0))
    unit_price = line.amount |> Decimal.div(line.quantity) |> Decimal.round(4, :half_up)

    base =
      Map.merge(tolerances, %{
        line_number: line.line_number,
        order_line_id: line.order_line_id,
        order_number: nil,
        billed_quantity: line.quantity,
        billed_unit_price: unit_price,
        previously_billed_quantity: previously,
        ordered_quantity: nil,
        ordered_unit_price: nil,
        received_quantity: nil,
        exceptions: []
      })

    case OrderSource.order_line(scope, company_id, line.order_line_id) do
      {:error, :order_source_unavailable} ->
        {:ok,
         exception(
           base,
           "order_source_unavailable",
           "no order source is installed to match against"
         )}

      {:error, :line_not_found} ->
        {:ok, exception(base, "order_line_not_found", "the order source has no such order line")}

      {:error, reason} ->
        {:error, reason}

      {:ok, order_line} ->
        with {:ok, receipts} <- OrderSource.line_receipts(scope, company_id, line.order_line_id) do
          received = receipts.received_quantity

          result =
            base
            |> Map.merge(%{
              order_number: order_line.order_number,
              ordered_quantity: order_line.quantity,
              ordered_unit_price: order_line.unit_price,
              received_quantity: received
            })
            |> check_order(order_line)
            |> check_currency(order_line, book)
            |> check_quantities(order_line, received)
            |> check_price(order_line, book)

          {:ok, result}
        end
    end
  end

  defp exception(result, code, detail),
    do: Map.update!(result, :exceptions, &(&1 ++ [%{code: code, detail: detail}]))

  defp check_order(result, order_line) do
    cond do
      order_line.superseded_by_amendment_id ->
        exception(
          result,
          "order_line_superseded",
          "the order line was replaced by an amendment of order #{order_line.order_number}"
        )

      order_line.order_status not in @open_order_statuses ->
        exception(
          result,
          "order_not_open",
          "order #{order_line.order_number} is #{order_line.order_status}, not open to billing"
        )

      true ->
        result
    end
  end

  defp check_currency(result, order_line, book) do
    if order_line.currency_code == book.currency_code,
      do: result,
      else:
        exception(
          result,
          "currency_mismatch",
          "the order is in #{order_line.currency_code}, the book in #{book.currency_code}"
        )
  end

  defp check_quantities(result, order_line, received) do
    ordered = order_line.quantity
    allowance = allowance(result.quantity_tolerance_kind, result.quantity_tolerance, ordered)
    total = Decimal.add(result.previously_billed_quantity, result.billed_quantity)
    billable = Decimal.sub(received, result.previously_billed_quantity)

    result
    |> then(fn result ->
      if Decimal.gt?(total, Decimal.add(ordered, allowance)),
        do:
          exception(
            result,
            "quantity_exceeds_ordered",
            "#{text(total)} billed in all against #{text(ordered)} ordered" <> within(allowance)
          ),
        else: result
    end)
    |> then(fn result ->
      if Decimal.gt?(result.billed_quantity, Decimal.add(billable, allowance)),
        do:
          exception(
            result,
            "quantity_exceeds_received",
            "#{text(result.billed_quantity)} billed against #{text(billable)} received and not yet billed" <>
              within(allowance)
          ),
        else: result
    end)
  end

  # A currency mismatch already says the prices cannot be compared.
  defp check_price(result, order_line, book) do
    if order_line.currency_code != book.currency_code do
      result
    else
      ordered = order_line.unit_price
      allowance = allowance(result.price_tolerance_kind, result.price_tolerance, ordered)
      difference = result.billed_unit_price |> Decimal.sub(ordered) |> Decimal.abs()

      if Decimal.gt?(difference, allowance),
        do:
          exception(
            result,
            "price_differs",
            "#{text(result.billed_unit_price)} per unit billed against #{text(ordered)} ordered" <>
              within(allowance)
          ),
        else: result
    end
  end

  defp allowance(nil, _tolerance, _base), do: Decimal.new(0)
  defp allowance("amount", tolerance, _base), do: tolerance

  defp allowance("percent", tolerance, base),
    do: base |> Decimal.mult(tolerance) |> Decimal.div(@hundred)

  defp within(allowance),
    do: if(Decimal.eq?(allowance, 0), do: "", else: ", within #{text(allowance)}")

  defp text(%Decimal{} = value), do: value |> Decimal.normalize() |> Decimal.to_string(:normal)
end
