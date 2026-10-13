defmodule Bilimbi.Finance.Reconciliation.Posting do
  @moduledoc false
  # Posts a statement line the books do not have, a bank charge or
  # interest, through the ledger facade and matches it to the entry in the
  # same transaction. The facade authorizes the call and holds the company
  # lock; the ledger authorizes the posting itself and rolls the joined
  # transaction back when it refuses, so nothing is recorded then.

  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Reconciliation.{Matching, Records}

  @kinds ~w(charge interest)
  @posting_note "Posted from statement line as "

  @doc "The kinds of statement line this module posts: a bank charge or interest."
  def kinds, do: @kinds

  @doc """
  Posts `line`, an unmatched statement line of the bank account, as `kind`
  (`"charge"` for money out against the account's charges account,
  `"interest"` for money in against its interest account), dated the line's
  date with the line's description unless `description` is given, and
  matches the line to the new entry. Returns `{:ok, %{entry, match}}`.
  """
  def post_statement_line(scope, company_id, bank_account, line, attributes) do
    kind = Records.fetch(attributes, :kind)

    with :ok <- kind?(kind),
         {:ok, counter_account_id} <- counter_account(bank_account, kind),
         :ok <- sign(line, kind),
         :ok <- unmatched?(scope, company_id, bank_account.id, line),
         {:ok, entry} <-
           post_once(scope, company_id, line, %{
             entry_date: line.line_date,
             description: description(attributes, line),
             reference: line.reference,
             lines: lines(bank_account.ledger_account_id, counter_account_id, line.amount)
           }),
         item = Matching.ledger_item(entry, bank_account.ledger_account_id),
         {:ok, match} <-
           Matching.insert_match(scope, company_id, bank_account, [line], [item], %{
             note: @posting_note <> kind
           }) do
      {:ok, %{entry: entry, match: match}}
    end
  end

  @doc """
  Reverses the entry `line` posted: `line` must stand matched, alone, to
  that entry. The match is unmatched with `reason` (an `unmatched` event, so
  never once a finalised reconciliation counted it) and the entry reversed
  as its owner, dated `entry_date` (default today). An entry posted before
  owners were recorded and not claimed is reversed the same way when the
  match is the one that posted it. Returns `{:ok, %{reversal, match}}`.
  """
  def reverse_statement_line(scope, company_id, bank_account, line, attributes) do
    with {:ok, reason} <- reason(attributes),
         {:ok, match} <- standing_match(scope, company_id, bank_account, line),
         {:ok, entry} <- posted_entry(scope, company_id, line, match),
         {:ok, unmatched} <- Matching.unmatch(scope, company_id, match, %{reason: reason}),
         {:ok, reversal} <-
           Ledger.reverse_owned_entry(scope, company_id, entry.id, owner(line), %{
             entry_date: Records.fetch(attributes, :entry_date) || Date.utc_today(),
             description: String.slice("Reversal of " <> entry.description, 0, 500),
             reference: entry.reference
           }) do
      {:ok, %{reversal: reversal, match: unmatched}}
    end
  end

  defp standing_match(scope, company_id, bank_account, line) do
    case Matching.standing_for_line(scope, company_id, bank_account.id, line.id) do
      nil -> {:error, :statement_line_not_matched}
      match -> {:ok, match}
    end
  end

  defp reason(attributes) do
    case Records.fetch(attributes, :reason) do
      text when is_binary(text) ->
        trimmed = String.trim(text)
        if trimmed != "" and String.length(trimmed) <= 500, do: {:ok, trimmed}, else: invalid()

      _none ->
        invalid()
    end
  end

  defp invalid, do: {:error, :invalid_reason}

  defp posted_entry(
         scope,
         company_id,
         line,
         %{lines: [_line], entries: [%{entry_id: entry_id}]} = match
       ) do
    owner = owner(line)

    case Ledger.get_entry(scope, company_id, entry_id) do
      {:ok, %{owner: ^owner} = entry} -> {:ok, entry}
      {:ok, %{owner: nil, legacy: true} = entry} -> legacy_posting(entry, match)
      {:ok, _other} -> {:error, :statement_line_not_posted}
      {:error, _reason} = error -> error
    end
  end

  defp posted_entry(_scope, _company_id, _line, _match), do: {:error, :statement_line_not_posted}

  defp legacy_posting(entry, %{note: note}) do
    if is_binary(note) and String.starts_with?(note, @posting_note),
      do: {:ok, entry},
      else: {:error, :statement_line_not_posted}
  end

  @module_id "finance/reconciliation"

  @doc "This module's descriptor ID, the `owner_module` of every entry it posts."
  def module_id, do: @module_id

  @doc "The owner identity of the entry a statement line posted."
  def owner(%{id: line_id}), do: %{module: @module_id, record: "statement_line:#{line_id}"}

  # The entry names the statement line as its owner, so the ledger holds one
  # entry per line: a line unmatched since it posted is matched to that
  # entry again, never posted again (`:statement_line_posted`).
  defp post_once(scope, company_id, line, entry) do
    case Ledger.post_entry(scope, company_id, entry, owner: owner(line)) do
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :owner_record),
          do: {:error, :statement_line_posted},
          else: {:error, changeset}

      result ->
        result
    end
  end

  defp kind?(kind) when kind in @kinds, do: :ok
  defp kind?(_kind), do: {:error, :invalid_kind}

  defp counter_account(%{charges_account_id: nil}, "charge"), do: {:error, :no_charges_account}
  defp counter_account(%{charges_account_id: id}, "charge"), do: {:ok, id}

  defp counter_account(%{interest_account_id: nil}, "interest"),
    do: {:error, :no_interest_account}

  defp counter_account(%{interest_account_id: id}, "interest"), do: {:ok, id}

  # A charge takes money out; interest brings it in.
  defp sign(line, "charge"),
    do: if(Decimal.negative?(line.amount), do: :ok, else: {:error, :not_a_charge})

  defp sign(line, "interest"),
    do: if(Decimal.positive?(line.amount), do: :ok, else: {:error, :not_interest})

  defp unmatched?(scope, company_id, bank_account_id, line) do
    taken = Matching.taken(scope, company_id, bank_account_id)
    if MapSet.member?(taken.lines, line.id), do: {:error, :statement_line_matched}, else: :ok
  end

  defp description(attributes, line) do
    case Records.fetch(attributes, :description) do
      text when is_binary(text) and byte_size(text) > 0 -> String.trim(text)
      _none -> line.description
    end
  end

  # Money out: debit the counter account, credit the bank; money in: the
  # reverse.
  defp lines(bank_account_id, counter_account_id, amount) do
    absolute = Decimal.abs(amount)

    if Decimal.negative?(amount),
      do: [
        %{account_id: counter_account_id, debit: absolute},
        %{account_id: bank_account_id, credit: absolute}
      ],
      else: [
        %{account_id: bank_account_id, debit: absolute},
        %{account_id: counter_account_id, credit: absolute}
      ]
  end
end
