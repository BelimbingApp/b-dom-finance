defmodule Bilimbi.Finance.Reconciliation.Web.Format do
  @moduledoc false
  # Amounts and refusals as the pages show them.

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

  def money(amount, minor_units) when is_binary(amount) do
    case Decimal.parse(amount) do
      {decimal, ""} -> money(decimal, minor_units)
      _other -> amount
    end
  end

  @doc "The sentence a refusal from the facade reads as."
  def refusal(:unauthorized), do: "You do not have permission for that action."
  def refusal(:company_archived), do: "The company is archived; nothing can be changed."
  def refusal(:company_not_found), do: "The company could not be found."
  def refusal(:book_not_open), do: "The company's ledger book is not open yet."
  def refusal(:bank_account_not_found), do: "The bank account no longer exists."
  def refusal(:bank_account_inactive), do: "The bank account is inactive."
  def refusal(:statement_not_found), do: "The statement no longer exists."
  def refusal(:statement_line_not_found), do: "The statement line no longer exists."
  def refusal(:statement_line_matched), do: "That statement line is already matched."
  def refusal(:entry_matched), do: "That ledger entry is already matched on this account."
  def refusal(:entry_not_found), do: "That ledger entry no longer exists."
  def refusal(:entry_not_on_account), do: "That ledger entry does not post to this bank account."
  def refusal(:invalid_selection), do: "Choose at least one statement line and one ledger entry."
  def refusal(:match_not_found), do: "The match no longer exists."
  def refusal(:match_not_standing), do: "That match is already unmatched."

  def refusal(:match_finalised),
    do: "A finalised reconciliation counted that match, so it is kept."

  def refusal(:reconciliation_not_found), do: "The reconciliation no longer exists."
  def refusal(:reconciliation_finalised), do: "The reconciliation is finalised and cannot change."
  def refusal(:reconciliation_abandoned), do: "The reconciliation was abandoned."

  def refusal(:same_person),
    do:
      "This company separates duties: someone other than whoever opened the reconciliation " <>
        "must finalise it."

  def refusal(:invalid_kind), do: "Choose whether the line is a charge or interest."
  def refusal(:no_charges_account), do: "Set the bank account's charges account first."
  def refusal(:no_interest_account), do: "Set the bank account's interest account first."
  def refusal(:not_a_charge), do: "Money in cannot be posted as a bank charge."
  def refusal(:not_interest), do: "Money out cannot be posted as interest."
  def refusal(:invalid_file_name), do: "The file needs a name."
  def refusal(:invalid_content), do: "The file could not be read."
  def refusal(:no_lines), do: "The file holds no statement lines."
  def refusal(:too_large), do: "The file is larger than the import allows."
  def refusal(:not_utf8), do: "The file is not UTF-8 text."
  def refusal(:invalid_option), do: "The request was malformed."

  def refusal({:unbalanced, statement_side, ledger_side}),
    do:
      "The sides do not agree: the statement lines sum to #{Decimal.to_string(statement_side, :normal)} " <>
        "and the ledger entries to #{Decimal.to_string(ledger_side, :normal)}."

  def refusal({:difference, difference}),
    do:
      "The difference is #{Decimal.to_string(difference, :normal)}, not zero; " <>
        "match or post what is unmatched, or check the statement balance."

  def refusal({:duplicate_file, number}),
    do: "This file was already imported as statement #{number}."

  def refusal({:duplicate_lines, duplicates}) do
    shown =
      duplicates
      |> Enum.take(5)
      |> Enum.map_join(
        ", ",
        &"row #{&1.row} (statement #{&1.statement_number}, line #{&1.statement_line_number})"
      )

    more = if length(duplicates) > 5, do: " and #{length(duplicates) - 5} more", else: ""
    "Nothing was imported: #{length(duplicates)} lines are already on file: #{shown}#{more}."
  end

  def refusal({:invalid_lines, errors}) do
    shown = errors |> Enum.take(5) |> Enum.map_join("; ", &"row #{&1.row}: #{&1.message}")
    more = if length(errors) > 5, do: "; and #{length(errors) - 5} more", else: ""
    "Nothing was imported: #{shown}#{more}."
  end

  def refusal({:missing_headers, headers}),
    do:
      "The file has no column named #{Enum.map_join(headers, ", ", &"“#{&1}”")}; check the bank account's import mapping."

  def refusal({:too_many_lines, max}), do: "The file holds more than #{max} lines; split it."

  def refusal({:running_balance_mismatch, row}),
    do:
      "Row #{row}'s running balance does not follow from the amounts; check the amount sign or the balance column."

  def refusal({:unterminated_quote, row}), do: "Row #{row} opens a quote it never closes."
  def refusal({:stray_quote, row}), do: "Row #{row} has a quote in the middle of a value."

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
