defmodule Bilimbi.Finance.Payroll.Posting do
  @moduledoc """
  The bridge from a finalised payroll run or an approved claim to the
  company's ledger.

  A run posts one balanced entry through `Bilimbi.Finance.Ledger.post_entry/3`,
  as the user the work runs for, dated the run's pay date, with the run's
  reference in the entry's `reference`. Its lines are the run's components,
  each summed per pay item code and direction: an earning debits the
  expense account its mapping names, a deduction credits the liability
  account its mapping names, and an employer contribution debits its
  expense and credits its liability (what is owed to the authority). Net
  pay, the earnings less the deductions, is credited to the settings' net
  pay account (what is owed to staff), or debited when the deductions
  exceed the earnings. A claim posts one entry dated its approval date:
  its approved amount debits the expense account its category's mapping
  names and credits the settings' claims payable account.

  Each component's total is rounded to the book's minor units, half away
  from zero, and net pay is the difference of the rounded earnings and
  deductions, so the entry balances in the book's units; the source keeps
  its own finer figures. A component with a zero total posts no line.

  The entry and the `posted` event that names it are one transaction under
  the company's writable lock, after the source is read again under that
  lock, so a source never has an entry without its event and the database
  refuses a second `posted` event for a source. The ledger rolls back the
  transaction it joins when it refuses an entry, so a failure (accounts
  unset or unmapped, the book not open or kept in another currency, a
  closed period, a missing grant) is recorded afterwards as a
  `posting_failed` event with its reason, in a transaction of its own, and
  the page lists the source until a retry succeeds. Only a database failure
  that may pass at once (a lost connection, a timeout, lock contention) is
  tried a second time, as a fresh transaction once the first has ended; a
  ledger refusal or a configuration failure is final. `post_run/5`,
  `post_claim/5`, and `reverse/4` must not run inside a caller's
  transaction.
  """

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Payroll.Events
  alias Bilimbi.Finance.Payroll.Mapping

  @transient_codes [
    :lock_not_available,
    :serialization_failure,
    :deadlock_detected,
    :query_canceled
  ]

  @run_kind "payroll_run"
  @claim_kind "claim"

  @doc """
  Posts the entry for a finalised run and records the outcome. `read` is
  the function that reads the run again, called under the company's lock;
  `settings` and `mappings` are read under that lock too. A run that has
  its `posted` event is `{:error, :already_posted}`, whatever view of it
  the caller holds.
  """
  @spec post_run(Scope.t(), term(), term(), (-> {:ok, map()} | {:error, term()}), (-> map())) ::
          {:ok, map()} | {:error, :already_posted | {:failed, String.t()}}
  def post_run(%Scope{} = scope, company_id, run_id, read, configuration)
      when is_function(read, 0) and is_function(configuration, 0) do
    post(scope, company_id, @run_kind, run_id, read, configuration, &run_entry/3)
  end

  @doc "Posts the entry for an approved claim and records the outcome, as `post_run/5` does."
  @spec post_claim(Scope.t(), term(), term(), (-> {:ok, map()} | {:error, term()}), (-> map())) ::
          {:ok, map()} | {:error, :already_posted | {:failed, String.t()}}
  def post_claim(%Scope{} = scope, company_id, claim_id, read, configuration)
      when is_function(read, 0) and is_function(configuration, 0) do
    post(scope, company_id, @claim_kind, claim_id, read, configuration, &claim_entry/3)
  end

  defp post(scope, company_id, kind, source_id, read, configuration, entry) do
    outcome =
      attempt(fn ->
        transaction(scope, company_id, fn ->
          with nil <- Events.posted(scope, company_id, kind, source_id),
               {:ok, source} <- read.(),
               %{settings: settings, mappings: mappings} <- configuration.(),
               :ok <- postable(kind, source),
               {:ok, book} <- book(scope, company_id, source),
               {:ok, attributes} <-
                 entry.(source, book, %{settings: settings, mappings: mappings}),
               {:ok, ledger_entry} <- Ledger.post_entry(scope, company_id, attributes) do
            event =
              Events.record!(scope, company_id, %{
                source_kind: kind,
                source_id: source_id,
                source_reference: source.reference,
                event: "posted",
                entry_id: ledger_entry.id,
                entry_number: ledger_entry.entry_number,
                entry_date: ledger_entry.entry_date,
                total: total(ledger_entry),
                currency_code: ledger_entry.currency_code
              })

            {:ok, Events.posting_view(event, nil)}
          else
            %{event: "posted"} -> {:error, :already_posted}
            {:error, reason} -> {:error, reason}
          end
        end)
      end)

    settle(scope, company_id, kind, source_id, "posting_failed", outcome)
  end

  @doc """
  Reverses a posting's entry on `entry_date` with `reason`, and records the
  outcome. Read again under the company's lock: a posting already reversed
  is `{:error, :already_reversed}`.
  """
  @spec reverse(Scope.t(), term(), map(), map()) ::
          {:ok, map()} | {:error, :already_reversed | :posting_not_found | {:failed, String.t()}}
  def reverse(%Scope{} = scope, company_id, %{id: posting_id}, attributes) do
    outcome =
      attempt(fn ->
        transaction(scope, company_id, fn ->
          case Events.posted_by_id(scope, company_id, posting_id) do
            nil ->
              {:error, :posting_not_found}

            posted ->
              events = Events.for_source(scope, company_id, posted.source_kind, posted.source_id)

              if Enum.any?(events, &(&1.event == "reversed")),
                do: {:error, :already_reversed},
                else: reverse_entry(scope, company_id, posted, attributes)
          end
        end)
      end)

    case outcome do
      {:ok, posting} ->
        {:ok, posting}

      {:error, reason} when reason in [:already_reversed, :posting_not_found] ->
        {:error, reason}

      {:error, reason} ->
        case Events.posted_by_id(scope, company_id, posting_id) do
          nil ->
            {:error, :posting_not_found}

          posted ->
            settle(scope, company_id, posted.source_kind, posted.source_id, "reversal_failed", {
              :error,
              reason
            })
        end
    end
  end

  defp reverse_entry(scope, company_id, posted, attributes) do
    reason = Map.get(attributes, :reason, Map.get(attributes, "reason"))
    entry_date = Map.get(attributes, :entry_date, Map.get(attributes, "entry_date"))

    with {:ok, entry} <-
           Ledger.reverse_entry(scope, company_id, posted.entry_id, %{
             entry_date: entry_date,
             description:
               "Reversal of #{description(posted.source_kind, posted.source_reference)}",
             reference: reference(posted.source_kind, posted.source_id, posted.source_reference)
           }),
         {:ok, reversed} <-
           Events.record(scope, company_id, %{
             source_kind: posted.source_kind,
             source_id: posted.source_id,
             source_reference: posted.source_reference,
             event: "reversed",
             entry_id: entry.id,
             entry_number: entry.entry_number,
             entry_date: entry.entry_date,
             total: total(entry),
             currency_code: entry.currency_code,
             reason: reason
           }) do
      {:ok, Events.posting_view(posted, reversed)}
    end
  end

  @doc """
  Runs `fun`, a whole transaction returning `{:ok, _}` or `{:error, _}`. A
  database failure that may pass at once is `{:error, {:transient, message}}`
  and `fun` runs one more time, on a connection of its own; every other
  result, including every ledger refusal, is final.
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
  defp settle(_scope, _company_id, _kind, _source_id, _event, {:ok, posting}), do: {:ok, posting}

  defp settle(_scope, _company_id, _kind, _source_id, _event, {:error, :already_posted}),
    do: {:error, :already_posted}

  defp settle(scope, company_id, kind, source_id, event, {:error, reason}) do
    message = failure_message(reason)
    record_failure(scope, company_id, kind, source_id, event, message)
    {:error, {:failed, message}}
  end

  # One transaction holding the company's writable lock. An error returned
  # from `fun` rolls it back, which the ledger's refusal has already done.
  defp transaction(scope, company_id, fun) do
    Repo.transact(fn ->
      case Company.lock_writable_company(scope, company_id) do
        {:ok, _proof} -> fun.()
        {:error, :not_found} -> {:error, :company_not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp record_failure(scope, company_id, kind, source_id, event, message) do
    transaction(scope, company_id, fn ->
      Events.record(scope, company_id, %{
        source_kind: kind,
        source_id: source_id,
        source_reference: "#{kind} #{source_id}",
        event: event,
        reason: message
      })
    end)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp postable(@run_kind, %{finalised: true}), do: :ok
  defp postable(@run_kind, _run), do: {:error, "the run is not finalised"}
  defp postable(@claim_kind, %{amount: %Decimal{}}), do: :ok
  defp postable(@claim_kind, _claim), do: {:error, "the claim is not approved"}

  defp book(scope, company_id, source) do
    case Ledger.get_book(scope, company_id) do
      {:ok, %{currency_code: currency} = book} when currency == source.currency_code ->
        {:ok, book}

      {:ok, %{currency_code: currency}} ->
        {:error, "the book is kept in #{currency}, the source in #{source.currency_code}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Entries

  defp run_entry(run, book, %{settings: settings, mappings: mappings}) do
    with {:ok, settings} <- configured(settings),
         {:ok, components} <- mapped_components(run.components, mappings) do
      rounded =
        for %{amount: amount} = component <- components,
            amount = Decimal.round(amount, book.minor_units, :half_up),
            not Decimal.eq?(amount, 0),
            do: %{component | amount: amount}

      earnings = sum(rounded, "earning")
      deductions = sum(rounded, "deduction")
      net = Decimal.sub(earnings, deductions)

      lines =
        Enum.flat_map(rounded, &component_lines/1) ++
          net_lines(net, settings.net_pay_account_id)

      if length(lines) >= 2 do
        {:ok,
         %{
           entry_date: run.pay_date,
           description: description(@run_kind, run.reference),
           reference: reference(@run_kind, run.id, run.reference),
           lines: lines
         }}
      else
        {:error, "the run's amounts are zero"}
      end
    end
  end

  defp claim_entry(claim, book, %{settings: settings, mappings: mappings}) do
    amount = Decimal.round(claim.amount, book.minor_units, :half_up)

    with {:ok, settings} <- configured(settings),
         {:ok, mapping} <- claim_mapping(claim, mappings),
         true <- Decimal.gt?(amount, 0) || {:error, "the claim's amount is zero"} do
      {:ok,
       %{
         entry_date: claim.approved_on,
         description: description(@claim_kind, claim.reference),
         reference: reference(@claim_kind, claim.id, claim.reference),
         lines: [
           %{
             account_id: mapping.expense_account_id,
             debit: amount,
             description: "Claim category #{claim.category_code}"
           },
           %{
             account_id: settings.claims_payable_account_id,
             credit: amount,
             description: "Owed to staff"
           }
         ]
       }}
    end
  end

  defp configured(nil), do: {:error, "payroll posting accounts not set"}
  defp configured(settings), do: {:ok, settings}

  # Every component names a mapping of its code and direction.
  defp mapped_components(components, mappings) do
    {mapped, missing} =
      Enum.reduce(components, {[], []}, fn component, {mapped, missing} ->
        case Map.get(mappings, {"component", component.code, component.direction}) do
          %Mapping{} = mapping -> {[Map.put(component, :mapping, mapping) | mapped], missing}
          nil -> {mapped, ["#{component.code} (#{component.direction})" | missing]}
        end
      end)

    case Enum.reverse(missing) do
      [] -> {:ok, Enum.reverse(mapped)}
      missing -> {:error, "components not mapped to accounts: #{Enum.join(missing, ", ")}"}
    end
  end

  defp claim_mapping(%{category_code: nil}, _mappings),
    do: {:error, "the claim's category is unknown"}

  defp claim_mapping(%{category_code: code}, mappings) do
    case Map.get(mappings, {"claim_category", code, Mapping.claim_direction()}) do
      %Mapping{} = mapping -> {:ok, mapping}
      nil -> {:error, "claim category not mapped to an account: #{code}"}
    end
  end

  defp component_lines(%{direction: "earning", mapping: mapping} = component) do
    [debit(mapping.expense_account_id, component)]
  end

  defp component_lines(%{direction: "deduction", mapping: mapping} = component) do
    [credit(mapping.liability_account_id, component)]
  end

  defp component_lines(%{direction: "employer", mapping: mapping} = component) do
    [
      debit(mapping.expense_account_id, component),
      credit(mapping.liability_account_id, component)
    ]
  end

  defp debit(account_id, component),
    do: %{account_id: account_id, debit: component.amount, description: label(component)}

  defp credit(account_id, component),
    do: %{account_id: account_id, credit: component.amount, description: label(component)}

  defp label(component), do: "#{component.code} (#{component.direction})"

  defp net_lines(net, account_id) do
    cond do
      Decimal.gt?(net, 0) ->
        [%{account_id: account_id, credit: net, description: "Net pay"}]

      Decimal.lt?(net, 0) ->
        [%{account_id: account_id, debit: Decimal.abs(net), description: "Net pay"}]

      true ->
        []
    end
  end

  defp sum(components, direction) do
    components
    |> Enum.filter(&(&1.direction == direction))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp total(%{lines: lines}) do
    Enum.reduce(lines, Decimal.new(0), fn line, acc ->
      Decimal.add(acc, line.debit || Decimal.new(0))
    end)
  end

  defp description(@run_kind, reference), do: "Payroll run #{reference}"
  defp description(@claim_kind, reference), do: "Staff #{reference}"

  # The reference (at most 100 characters) names the source by ID first,
  # so an auditor walks entry to source whatever the reference says.
  defp reference(kind, id, reference), do: String.slice("#{kind} #{id}: #{reference}", 0, 100)

  defp failure_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> error_lines([])
    |> Enum.join("; ")
    |> String.slice(0, 500)
  end

  defp failure_message({:transient, message}),
    do: String.slice("a database failure, tried twice: " <> message, 0, 500)

  defp failure_message(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp failure_message(:unauthorized), do: "the actor may not post to the ledger"
  defp failure_message(:book_not_open), do: "the company's book is not open"
  defp failure_message(:company_archived), do: "the company is archived"
  defp failure_message(:company_not_found), do: "the company could not be found"
  defp failure_message(:people_unavailable), do: "the payroll source is not installed"
  defp failure_message(:not_found), do: "the source no longer exists"
  defp failure_message(:entry_not_found), do: "the ledger entry no longer exists"
  defp failure_message(:already_reversed), do: "the ledger entry is already reversed"
  defp failure_message(reason), do: reason |> inspect() |> String.slice(0, 500)

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
