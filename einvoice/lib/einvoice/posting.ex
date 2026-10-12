defmodule Bilimbi.Finance.Einvoice.Posting do
  @moduledoc """
  The bridge from a cleared document to the company's ledger.

  A document the authority validated posts one balanced entry through
  `Bilimbi.Finance.Ledger.post_entry/3`, as the user the work runs for,
  dated the document's issue date, with the document's code number and
  authority UUID in the entry's `reference`. The accounts come from the
  company's `finance.einvoice.posting.*` settings, by account code in its
  own chart; nothing here names an account. An invoice or debit note
  debits the receivable account and credits revenue and tax; a credit note
  posts the mirror image; a refund note debits revenue and tax and credits
  the settlement account. A tax of zero posts no tax line.

  The entry's ID is recorded on a `posted` status event, and a cancelled
  document's entry is reversed with `Ledger.reverse_entry/4` and recorded
  on a `posting_reversed` event, so both sides stay immutable and an
  auditor walks document to UUID to entry. A posting that cannot happen
  (accounts unset, book not open, currency mismatch, missing grant) is
  recorded as `posting_failed` or `reversal_failed` with its reason, and
  the reconciliation page lists the document until it is resolved by the
  manual retry. Only a database failure that may pass at once (a lost
  connection, a timeout, lock contention) is tried a second time, inside
  the same call and recorded as one failure; a ledger refusal (an
  inactive account, a closed period) or a configuration failure is final.
  A document posts once: asking again after a `posted` event is `:noop`.
  A rejected document is still valid at the authority, so it posts too.

  The ledger rolls back its own transaction when it refuses an entry, so
  `post/3` and `reverse/4` must not run inside one of ours. Each holds a
  per-document advisory lock across the check, the ledger call, and the
  event it records in a transaction of its own; the database also refuses
  a second `posted` and a second `posting_reversed` event for a document.
  """

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Einvoice.Configuration
  alias Bilimbi.Finance.Einvoice.Documents
  alias Bilimbi.Finance.Ledger
  alias Ecto.Adapters.SQL

  @debit_side ["01", "03"]
  @credit_side ["02"]
  @refund ["04"]
  @transient_codes [
    :lock_not_available,
    :serialization_failure,
    :deadlock_detected,
    :query_canceled
  ]

  @doc """
  Posts the entry for a document the authority holds as valid and records
  the outcome as an event. The document is read again under a lock of its
  own, so a document that already has its entry is `:noop`, whatever view
  of it the caller holds.
  """
  @spec post(Scope.t(), pos_integer(), map()) :: {:ok, map()} | {:error, String.t()} | :noop
  def post(%Scope{} = scope, company_id, %{id: document_id}) do
    locked(company_id, document_id, fn ->
      case current(scope, company_id, document_id) do
        nil -> {:error, "the document was not found"}
        %{ledger_entry_id: entry_id} when not is_nil(entry_id) -> :noop
        current -> post_entry(scope, company_id, current)
      end
    end)
  end

  @doc """
  Runs one ledger attempt (`fun` returns `{:ok, _}` or `{:error, _}`). A
  database failure that may pass at once (a lost connection, a timeout,
  lock contention) is `{:error, {:transient, message}}` and is tried one
  more time; every other result, including every ledger refusal, is final.
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

  # One decision at a time per document, across processes and nodes: the
  # lock outlives the ledger's own transaction, which a refusal rolls back.
  defp locked(company_id, document_id, fun) do
    key = "finance/einvoice/posting/#{company_id}/#{document_id}"

    Repo.checkout(fn ->
      SQL.query!(Repo, "SELECT pg_advisory_lock(hashtextextended($1, 0))", [key])

      try do
        fun.()
      after
        SQL.query!(Repo, "SELECT pg_advisory_unlock(hashtextextended($1, 0))", [key])
      end
    end)
  end

  defp current(scope, company_id, document_id) do
    case Documents.fetch(scope, company_id, document_id) do
      nil -> nil
      fetched -> Documents.document_view(fetched)
    end
  end

  defp record!(scope, company_id, document_id, attributes) do
    Documents.write!(scope, company_id, fn ->
      Documents.record_event!(scope, company_id, document_id, attributes)
    end)
  end

  defp post_entry(scope, company_id, document) do
    result =
      attempt(fn ->
        with :ok <- postable(document),
             {:ok, book} <- book(scope, company_id, document),
             {:ok, accounts} <- accounts(scope, company_id, document.document_type),
             {:ok, lines} <- lines(document, accounts, book) do
          Ledger.post_entry(scope, company_id, %{
            entry_date: DateTime.to_date(document.issued_at),
            description: description(document),
            reference: reference(document),
            lines: lines
          })
        end
      end)

    case result do
      {:ok, entry} ->
        record!(scope, company_id, document.id, %{
          event: "posted",
          ledger_entry_id: entry.id,
          reason: "entry #{entry.entry_number}"
        })

        {:ok, entry}

      {:error, reason} ->
        message = failure_message(reason)
        record!(scope, company_id, document.id, %{event: "posting_failed", reason: message})
        {:error, message}
    end
  end

  @doc """
  Reverses a cancelled document's entry and records the outcome as an
  event. Read again under the document's lock: a document without an
  entry, or already reversed, is `:noop`.
  """
  @spec reverse(Scope.t(), pos_integer(), map(), DateTime.t()) ::
          {:ok, map()} | {:error, String.t()} | :noop
  def reverse(%Scope{} = scope, company_id, %{id: document_id}, %DateTime{} = now) do
    locked(company_id, document_id, fn ->
      case current(scope, company_id, document_id) do
        nil -> :noop
        %{ledger_entry_id: nil} -> :noop
        %{reversal_entry_id: entry_id} when not is_nil(entry_id) -> :noop
        current -> reverse_entry(scope, company_id, current, now)
      end
    end)
  end

  defp reverse_entry(scope, company_id, document, now) do
    result =
      attempt(fn ->
        Ledger.reverse_entry(scope, company_id, document.ledger_entry_id, %{
          entry_date: DateTime.to_date(now),
          description: "Reversal of " <> description(document),
          reference: reference(document)
        })
      end)

    case result do
      {:ok, entry} ->
        record!(scope, company_id, document.id, %{
          event: "posting_reversed",
          ledger_entry_id: entry.id,
          reason: "entry #{entry.entry_number}"
        })

        {:ok, entry}

      {:error, reason} ->
        message = failure_message(reason)
        record!(scope, company_id, document.id, %{event: "reversal_failed", reason: message})
        {:error, message}
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
      cond do
        document_type in @debit_side -> [:receivable_account, :revenue_account, :tax_account]
        document_type in @credit_side -> [:receivable_account, :revenue_account, :tax_account]
        document_type in @refund -> [:settlement_account, :revenue_account, :tax_account]
        true -> []
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

  # The entry's lines by document type. `other` is the side the receivable
  # or settlement account takes; revenue and tax take the opposite side.
  defp lines(document, accounts, _book) do
    type = document.document_type
    net = document.tax_exclusive_amount
    tax = document.tax_amount
    gross = document.payable_amount

    {other_account, other_side, revenue_side} =
      cond do
        type in @debit_side -> {accounts.receivable_account, :debit, :credit}
        type in @credit_side -> {accounts.receivable_account, :credit, :debit}
        type in @refund -> {accounts.settlement_account, :credit, :debit}
      end

    lines =
      [
        {other_account, other_side, gross, nil},
        {accounts.revenue_account, revenue_side, net, "Tax-exclusive amount"},
        {accounts.tax_account, revenue_side, tax, "Tax"}
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

  defp type_name("01"), do: "invoice"
  defp type_name("02"), do: "credit note"
  defp type_name("03"), do: "debit note"
  defp type_name("04"), do: "refund note"
  defp type_name(type), do: "type #{type}"

  defp failure_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(List.wrap(messages), ", ")}"
    end)
    |> String.slice(0, 300)
  end

  defp failure_message({:transient, message}),
    do: String.slice("a database failure, tried twice: " <> message, 0, 300)

  defp failure_message(reason) when is_binary(reason), do: String.slice(reason, 0, 300)
  defp failure_message(:unauthorized), do: "the actor may not post to the ledger"
  defp failure_message(:book_not_open), do: "the company's book is not open"
  defp failure_message(:company_archived), do: "the company is archived"
  defp failure_message(reason), do: reason |> inspect() |> String.slice(0, 300)
end
