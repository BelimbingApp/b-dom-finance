defmodule Bilimbi.Finance.Sst.Figures do
  @moduledoc false
  # A return's figures: the document tax of the period read through the
  # ledger, receivables, and payables facades at one ledger entry number,
  # routed to boxes by the tax code mappings in force through one mapping
  # number, plus the return's standing adjustments; and how each tax
  # account's ledger postings compare with the documents behind them.
  #
  # Routing, by each row's tax code mapping:
  #
  # - no mapping: listed as unmapped, which stops the return finalising;
  # - mapped as not reported (no box): listed, counted nowhere;
  # - mapped to the other tax's form: left to that return;
  # - mapped to a box of this form: an invoice or bill adds its value and
  #   tax; a credit note on an invoice of the same period, or a debit note,
  #   subtracts them; a credit note on an earlier period's invoice deducts
  #   its tax in item 13(a), where a credit note for tax already paid goes.
  #
  # Service tax due when payment is received reads receivables' tax share
  # of payments instead of its invoices: `received` and `unpaid` add to the
  # mapped box, and `credited_after_due` deducts in item 13(a).

  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Payables
  alias Bilimbi.Finance.Receivables
  alias Bilimbi.Finance.Sst.{Form, Mappings}

  @zero Decimal.new(0)

  # Section 11(2) of the Service Tax Act 2018: service tax not paid within
  # twelve months of the invoice is due the day after.
  @unpaid_months 12

  @doc """
  The figures of a `tax_type` return for `period_start` to `period_end`
  under `registration`, with `adjustments` (standing ones, as maps), read
  at `pins` (`through_entry_number` and `through_mapping_number`, each the
  latest when absent).
  """
  def compute(scope, company_id, period, registration, adjustments, pins \\ []) do
    %{tax_type: tax_type, period_start: from, period_end: to} = period
    payment_basis? = tax_type == "service_tax" and registration.service_tax_basis == "payment"
    mapping_number = pins[:through_mapping_number] || Mappings.last_number(scope, company_id)

    with {:ok, book} <- Ledger.get_book(scope, company_id),
         {:ok, totals} <-
           Ledger.account_totals(
             scope,
             company_id,
             [from: from, to: to] ++ Keyword.take(pins, [:through_entry_number])
           ),
         through = totals.through_entry_number,
         window = [from: from, to: to, through_entry_number: through],
         {:ok, receivables} <- Receivables.tax_totals(scope, company_id, window),
         {:ok, payables} <- Payables.tax_totals(scope, company_id, window),
         {:ok, received} <- received(scope, company_id, window, payment_basis?),
         {:ok, accounts} <- Ledger.list_accounts(scope, company_id) do
      mappings = Mappings.at(scope, company_id, mapping_number)

      accrual =
        Enum.map(receivables, &receivables_row/1) ++ Enum.map(payables, &payables_row/1)

      # On the payment basis, receivables' codes mapped to service tax
      # boxes count what was received instead of what was invoiced.
      read =
        if payment_basis?,
          do:
            Enum.reject(accrual, &(&1.source == "receivables" and service?(&1, mappings))) ++
              (received |> Enum.map(&received_row/1) |> Enum.filter(&service?(&1, mappings))),
          else: accrual

      routed = Enum.map(read, &route(&1, mappings, tax_type))
      sources = for {:counted, row} <- routed, do: row

      unmapped =
        for({:unmapped, row} <- routed, do: row) |> Enum.uniq_by(&{&1.source, &1.tax_code_id})

      sums = sums(sources, adjustments)

      boxes = Form.figures(tax_type, sums, book.minor_units)

      {:ok,
       %{
         tax_type: tax_type,
         period_start: from,
         period_end: to,
         service_tax_basis: if(tax_type == "service_tax", do: registration.service_tax_basis),
         currency_code: book.currency_code,
         minor_units: book.minor_units,
         through_entry_number: through,
         through_mapping_number: mapping_number,
         boxes: boxes,
         tax_payable: Enum.find(boxes, &(&1.key == Form.payable_box())).tax_amount,
         sources:
           Enum.with_index(sources, 1)
           |> Enum.map(fn {row, n} -> Map.put(row, :line_number, n) end),
         unmapped: unmapped,
         rate_mismatches: Enum.filter(sources, & &1.rate_mismatch),
         accounts: reconcile(accrual, tax_type, mappings, totals.rows, accounts)
       }}
    end
  end

  defp received(_scope, _company_id, _window, false), do: {:ok, []}

  defp received(scope, company_id, window, true),
    do:
      Receivables.received_tax_totals(
        scope,
        company_id,
        window ++ [unpaid_months: @unpaid_months]
      )

  # Source rows in one shape: what a document carried, signed by whether it
  # adds to its box (`sign`) or deducts.
  defp receivables_row(row) do
    %{
      source: "receivables",
      document_kind: row.kind,
      measure: "documents",
      prior_period: row.credits_prior_period,
      tax_code_id: row.tax_code_id,
      tax_code: row.tax_code,
      rate: row.tax_rate,
      account_id: row.account_id,
      document_count: row.document_count,
      carried_taxable: row.taxable_amount,
      carried_tax: row.tax_amount,
      sign: if(row.kind == "invoice", do: 1, else: -1)
    }
  end

  defp payables_row(row) do
    %{
      source: "payables",
      document_kind: row.document_type,
      measure: "documents",
      prior_period: false,
      tax_code_id: row.tax_code_id,
      tax_code: row.tax_code,
      rate: row.rate,
      account_id: row.account_id,
      document_count: row.document_count,
      carried_taxable: row.taxable_amount,
      carried_tax: row.tax_amount,
      sign: if(row.document_type == "bill", do: 1, else: -1)
    }
  end

  defp received_row(row) do
    credited? = row.measure == "credited_after_due"

    %{
      source: "receivables",
      document_kind: if(credited?, do: "credit_note", else: "invoice"),
      measure: row.measure,
      prior_period: credited?,
      tax_code_id: row.tax_code_id,
      tax_code: row.tax_code,
      rate: row.tax_rate,
      account_id: row.account_id,
      document_count: row.document_count,
      carried_taxable: row.taxable_amount,
      carried_tax: row.tax_amount,
      sign: if(credited?, do: -1, else: 1)
    }
  end

  defp service?(row, mappings) do
    case Map.get(mappings, {row.source, row.tax_code_id}) do
      %{box: box} when is_binary(box) -> Form.mapped_tax_type(box) == "service_tax"
      _other -> false
    end
  end

  defp route(row, mappings, tax_type) do
    case Map.get(mappings, {row.source, row.tax_code_id}) do
      nil ->
        {:unmapped, Map.take(row, [:source, :document_kind, :tax_code_id, :tax_code, :rate])}

      %{box: nil} = mapping ->
        {:counted,
         counted(
           row,
           mapping,
           nil,
           scaled(row.carried_taxable, row.sign),
           scaled(row.carried_tax, row.sign)
         )}

      %{box: key} = mapping ->
        if Form.mapped_tax_type(key) == tax_type,
          do: {:counted, to_box(row, mapping, Form.box(tax_type, key))},
          else: :elsewhere
    end
  end

  # A deduction of tax already reported goes to item 13(a); a value-only
  # box nets its credit notes in place, since it holds no tax to deduct.
  defp to_box(%{sign: -1, prior_period: true} = row, mapping, %{kind: kind} = box)
       when kind != :value do
    row
    |> counted(mapping, "13a", @zero, row.carried_tax)
    |> Map.put(:rate_mismatch, mismatch?(row, box))
  end

  defp to_box(row, mapping, box) do
    row
    |> counted(
      mapping,
      box.key,
      scaled(row.carried_taxable, row.sign),
      scaled(row.carried_tax, row.sign)
    )
    |> Map.put(:rate_mismatch, mismatch?(row, box))
  end

  defp mismatch?(row, %{kind: :rated, rate: rate}), do: not Decimal.equal?(row.rate, rate)
  defp mismatch?(row, %{kind: :value}), do: not Decimal.equal?(row.carried_tax, 0)
  defp mismatch?(_row, _box), do: false

  # Contributions keep the columns' four places, so a finalised return's
  # stored rows add up to its boxes exactly.
  defp counted(row, mapping, box, taxable, tax) do
    row
    |> Map.take([
      :source,
      :document_kind,
      :measure,
      :prior_period,
      :tax_code_id,
      :tax_code,
      :rate,
      :account_id,
      :document_count
    ])
    |> Map.merge(%{
      box: box,
      mapping_number: mapping.mapping_number,
      taxable_amount: Decimal.round(taxable, 4),
      tax_amount: Decimal.round(tax, 4),
      rate_mismatch: false
    })
  end

  defp scaled(amount, sign), do: Decimal.mult(amount, sign)

  defp sums(sources, adjustments) do
    contributions =
      for row <- sources, row.box, do: {row.box, row.taxable_amount, row.tax_amount}

    adjusted = for a <- adjustments, do: {a.box, a.taxable_amount, a.tax_amount}

    Enum.reduce(contributions ++ adjusted, %{}, fn {box, taxable, tax}, acc ->
      Map.update(acc, box, {taxable, tax}, fn {t, x} ->
        {Decimal.add(t, taxable), Decimal.add(x, tax)}
      end)
    end)
  end

  # Each tax account a code of this form (or an unmapped code) posted to
  # in the period, its debits and credits over the period against what
  # every document posted to it: receivables' invoices credit their tax and
  # credit notes debit it; payables' bills debit theirs and debit notes
  # credit it. Only the period's own rows name the accounts, so a finalised
  # return's reconciliation reproduces whatever tax codes say later.
  defp reconcile(accrual, tax_type, mappings, ledger_rows, accounts) do
    account_ids =
      for(row <- accrual, form_code?(row, mappings, tax_type), do: row.account_id)
      |> Enum.uniq()

    by_id = Map.new(accounts, &{&1.id, &1})
    ledger = Map.new(ledger_rows, &{&1.id, &1})

    account_ids
    |> Enum.map(fn id ->
      {debits, credits} = document_sides(accrual, id)
      account = Map.get(by_id, id, %{code: "?", name: "Account #{id}"})
      posted = Map.get(ledger, id, %{debits: @zero, credits: @zero})

      %{
        account_id: id,
        account_code: account.code,
        account_name: account.name,
        ledger_debits: posted.debits,
        ledger_credits: posted.credits,
        document_debits: debits,
        document_credits: credits,
        difference:
          posted.credits
          |> Decimal.sub(posted.debits)
          |> Decimal.sub(Decimal.sub(credits, debits))
      }
    end)
    |> Enum.sort_by(& &1.account_code)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, n} -> Map.put(row, :line_number, n) end)
  end

  defp form_code?(row, mappings, tax_type) do
    case Map.get(mappings, {row.source, row.tax_code_id}) do
      nil -> true
      %{box: nil} -> false
      %{box: box} -> Form.mapped_tax_type(box) == tax_type
    end
  end

  defp document_sides(accrual, account_id) do
    Enum.reduce(accrual, {@zero, @zero}, fn
      %{account_id: ^account_id} = row, {debits, credits} ->
        if credits_account?(row),
          do: {debits, Decimal.add(credits, row.carried_tax)},
          else: {Decimal.add(debits, row.carried_tax), credits}

      _row, sides ->
        sides
    end)
  end

  defp credits_account?(%{source: "receivables", document_kind: kind}), do: kind == "invoice"
  defp credits_account?(%{source: "payables", document_kind: kind}), do: kind == "debit_note"
end
