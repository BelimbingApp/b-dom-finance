defmodule Bilimbi.Finance.Einvoice.Posting do
  @moduledoc """
  The bridge from a cleared document to the company's ledger.

  A document the authority validated posts one balanced entry through
  `Bilimbi.Finance.Ledger.post_entry/3`, as the user the work runs for,
  dated the document's issue date, with the document's code number and
  authority UUID in the entry's `reference`. The accounts come from the
  company's `finance.einvoice.posting.*` settings, by account code in its
  own chart; nothing here names an account, and the authority's
  `posting_rule/1` says which settings each document type posts to. An
  invoice or debit note debits the receivable account and credits revenue
  and tax; a credit note posts the mirror image; a refund note debits
  revenue and tax and credits the settlement account. A self-billed
  document is a purchase: its invoice or debit note credits the payable
  account and debits expense and purchase tax, its credit note posts the
  mirror image, and its refund note debits the settlement account. A tax
  of zero posts no tax line.

  The entry's ID is recorded on a `posted` status event, and a cancelled
  document's entry is reversed with `Ledger.reverse_entry/4` and recorded
  on a `posting_reversed` event, so both sides stay immutable and an
  auditor walks document to UUID to entry. A posting that cannot happen
  (accounts unset, book not open, currency mismatch, missing grant) is
  recorded as `posting_failed` or `reversal_failed` with its reason, and
  the reconciliation page lists the document until it is resolved by the
  manual retry. Only a database failure that may pass at once (a lost
  connection, a timeout, lock contention) is tried a second time, as a
  fresh transaction once the first has ended, and recorded as one failure
  that says it was tried twice; a ledger refusal (an
  inactive account, a closed period) or a configuration failure is final.
  A document posts once: asking again after a `posted` event is `:noop`.
  A rejected document is still valid at the authority, so it posts too.

  An entry and the event that names it are one transaction under the
  company's writable lock, so a document never has an entry without its
  `posted` event, and the database also refuses a second `posted` and a
  second `posting_reversed` event for a document. The ledger rolls back
  the transaction it joins when it refuses an entry, so a failure event is
  recorded afterwards, in a transaction of its own, and `post/3` and
  `reverse/4` must not run inside one of the caller's.
  """

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Einvoice.Configuration
  alias Bilimbi.Finance.Einvoice.Documents
  alias Bilimbi.Finance.Ledger

  @transient_codes [
    :lock_not_available,
    :serialization_failure,
    :deadlock_detected,
    :query_canceled
  ]

  @doc """
  Posts the entry for a document the authority holds as valid and records
  the outcome as an event. The document is read again under the company's
  lock, so a document that already has its entry is `:noop`, whatever view
  of it the caller holds. A database failure is returned as an error and
  never raised.
  """
  @spec post(Scope.t(), pos_integer(), map()) :: {:ok, map()} | {:error, String.t()} | :noop
  def post(%Scope{} = scope, company_id, %{id: document_id}) do
    settle(scope, company_id, document_id, "posting_failed", fn ->
      transaction(scope, company_id, fn ->
        case current(scope, company_id, document_id) do
          nil -> {:ok, :noop}
          %{ledger_entry_id: entry_id} when not is_nil(entry_id) -> {:ok, :noop}
          current -> post_entry(scope, company_id, current)
        end
      end)
    end)
  end

  @doc """
  Runs `fun`, a whole transaction returning `{:ok, _}` or `{:error, _}`. A
  database failure that may pass at once (a lost connection, a timeout,
  lock contention) is `{:error, {:transient, message}}` and `fun` runs one
  more time, on a connection of its own; every other result, including
  every ledger refusal, is final.
  """
  @spec attempt((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def attempt(fun) when is_function(fun, 0) do
    case run(fun) do
      {:error, {:transient, _message}} -> run(fun)
      result -> result
    end
  end

  defp run(fun) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      if transient?(error),
        do: {:error, {:transient, Exception.message(error)}},
        else: reraise(error, __STACKTRACE__)
  end

  @doc "Whether a database exception is a failure that may pass on its own."
  @spec transient?(Exception.t()) :: boolean()
  def transient?(%DBConnection.ConnectionError{}), do: true
  def transient?(%Postgrex.Error{postgres: %{code: code}}), do: code in @transient_codes
  def transient?(_error), do: false

  # The attempt's outcome as the caller sees it. A failure is recorded once,
  # after the attempt's transaction ended, and only if the database can take
  # it; either way the error is returned.
  defp settle(scope, company_id, document_id, failure_event, fun) do
    case attempt(fun) do
      {:ok, :noop} ->
        :noop

      {:ok, entry} ->
        {:ok, entry}

      {:error, reason} ->
        message = failure_message(reason)
        record_failure(scope, company_id, document_id, failure_event, message)
        {:error, message}
    end
  end

  # One transaction holding the company's writable lock. An error returned
  # from `fun` rolls it back, which the ledger's refusal has already done.
  defp transaction(scope, company_id, fun) do
    Repo.transact(fn ->
      case Company.lock_writable_company(scope, company_id) do
        {:ok, _proof} -> fun.()
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp record_failure(scope, company_id, document_id, event, message) do
    transaction(scope, company_id, fn ->
      {:ok,
       Documents.record_event!(scope, company_id, document_id, %{event: event, reason: message})}
    end)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp current(scope, company_id, document_id) do
    case Documents.fetch(scope, company_id, document_id) do
      nil -> nil
      fetched -> Documents.document_view(fetched)
    end
  end

  defp post_entry(scope, company_id, document) do
    with :ok <- postable(document),
         {:ok, book} <- book(scope, company_id, document),
         {:ok, accounts} <- accounts(scope, company_id, document.document_type),
         {:ok, lines} <- lines(document, accounts, book),
         {:ok, entry} <-
           Ledger.post_entry(scope, company_id, %{
             entry_date: DateTime.to_date(document.issued_at),
             description: description(document),
             reference: reference(document),
             lines: lines
           }) do
      Documents.record_event!(scope, company_id, document.id, %{
        event: "posted",
        ledger_entry_id: entry.id,
        reason: "entry #{entry.entry_number}"
      })

      {:ok, entry}
    end
  end

  @doc """
  Reverses a cancelled document's entry and records the outcome as an
  event. Read again under the company's lock: a document without an entry,
  or already reversed, is `:noop`.
  """
  @spec reverse(Scope.t(), pos_integer(), map(), DateTime.t()) ::
          {:ok, map()} | {:error, String.t()} | :noop
  def reverse(%Scope{} = scope, company_id, %{id: document_id}, %DateTime{} = now) do
    settle(scope, company_id, document_id, "reversal_failed", fn ->
      transaction(scope, company_id, fn ->
        case current(scope, company_id, document_id) do
          nil -> {:ok, :noop}
          %{ledger_entry_id: nil} -> {:ok, :noop}
          %{reversal_entry_id: entry_id} when not is_nil(entry_id) -> {:ok, :noop}
          current -> reverse_entry(scope, company_id, current, now)
        end
      end)
    end)
  end

  defp reverse_entry(scope, company_id, document, now) do
    with {:ok, entry} <-
           Ledger.reverse_entry(scope, company_id, document.ledger_entry_id, %{
             entry_date: DateTime.to_date(now),
             description: "Reversal of " <> description(document),
             reference: reference(document)
           }) do
      Documents.record_event!(scope, company_id, document.id, %{
        event: "posting_reversed",
        ledger_entry_id: entry.id,
        reason: "entry #{entry.entry_number}"
      })

      {:ok, entry}
    end
  end

  defp postable(%{status: status, document_uuid: uuid}) when is_binary(uuid) do
    if status in Documents.valid_statuses(),
      do: :ok,
      else: {:error, "the document is not validated"}
  end

  defp postable(_document), do: {:error, "the document is not validated"}

  defp accounts(scope, company_id, document_type) do
    settings = Configuration.posting_accounts(scope, company_id)

    needed =
      case Configuration.authority().posting_rule(document_type) do
        %{counter: counter, net: net, tax: tax} -> [counter, net, tax]
        nil -> []
      end

    missing = Enum.filter(needed, &is_nil(settings[&1]))

    cond do
      needed == [] ->
        {:error, "document type #{document_type} has no posting rule"}

      missing != [] ->
        {:error, "posting accounts not set: #{Enum.join(missing, ", ")}"}

      true ->
        with {:ok, chart} <- Ledger.list_accounts(scope, company_id) do
          by_code = Map.new(chart, &{&1.code, &1})

          resolved =
            Map.new(needed, fn field ->
              code = settings[field]
              {field, Map.get(by_code, code)}
            end)

          unknown = for {field, nil} <- resolved, do: "#{field} #{settings[field]}"

          if unknown == [],
            do: {:ok, resolved},
            else: {:error, "accounts not in the chart: #{Enum.join(unknown, ", ")}"}
        end
    end
  end

  defp book(scope, company_id, document) do
    case Ledger.get_book(scope, company_id) do
      {:ok, %{currency_code: currency} = book} when currency == document.currency_code ->
        {:ok, book}

      {:ok, %{currency_code: currency}} ->
        {:error, "the book is kept in #{currency}, the document in #{document.currency_code}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The entry's lines by document type. The counter-account (receivable,
  # payable, or settlement) takes the rule's side; the net (revenue or
  # expense) and tax accounts take the opposite side.
  defp lines(document, accounts, _book) do
    net = document.tax_exclusive_amount
    tax = document.tax_amount
    gross = document.payable_amount

    rule = Configuration.authority().posting_rule(document.document_type)
    opposite = if rule.side == :debit, do: :credit, else: :debit

    lines =
      [
        {Map.fetch!(accounts, rule.counter), rule.side, gross, nil},
        {Map.fetch!(accounts, rule.net), opposite, net, "Tax-exclusive amount"},
        {Map.fetch!(accounts, rule.tax), opposite, tax, "Tax"}
      ]
      |> Enum.reject(fn {_account, _side, amount, _description} -> Decimal.eq?(amount, 0) end)
      |> Enum.map(fn {account, side, amount, description} ->
        %{side => amount, account_id: account.id, description: description}
      end)

    if length(lines) >= 2, do: {:ok, lines}, else: {:error, "the document's amounts are zero"}
  end

  defp description(document) do
    "E-invoice #{document.code_number} (#{type_name(document.document_type)})"
  end

  # Code number (at most 50 characters) and UUID (26) fit the reference's 100.
  defp reference(document), do: "#{document.code_number} #{document.document_uuid}"

  defp type_name(type),
    do: type |> Configuration.authority().document_type_name() |> String.downcase()

  defp failure_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> error_lines([])
    |> Enum.join("; ")
    |> String.slice(0, 300)
  end

  defp failure_message({:transient, message}),
    do: String.slice("a database failure, tried twice: " <> message, 0, 300)

  defp failure_message(reason) when is_binary(reason), do: String.slice(reason, 0, 300)
  defp failure_message(:unauthorized), do: "the actor may not post to the ledger"
  defp failure_message(:book_not_open), do: "the company's book is not open"
  defp failure_message(:company_archived), do: "the company is archived"
  defp failure_message(reason), do: reason |> inspect() |> String.slice(0, 300)

  defp error_lines(errors, path) when is_map(errors) do
    errors
    |> Enum.sort()
    |> Enum.flat_map(fn {key, value} -> error_lines(value, path ++ [to_string(key)]) end)
  end

  defp error_lines([first | _] = messages, path) when is_binary(first),
    do: [Enum.join(path ++ [Enum.join(messages, ", ")], " ")]

  defp error_lines(errors, path) when is_list(errors) do
    errors
    |> Enum.with_index()
    |> Enum.flat_map(fn {error, index} ->
      error_lines(error, List.update_at(path, -1, &"#{&1}[#{index}]"))
    end)
  end
end
