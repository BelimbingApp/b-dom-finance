defmodule Bilimbi.Finance.Receivables.Payments do
  @moduledoc false
  # Payments received, their allocations to invoices, and their reversals.
  # The facade authorizes every call and holds the company lock for writes.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Receivables.Allocation
  alias Bilimbi.Finance.Receivables.Balances
  alias Bilimbi.Finance.Receivables.Configuration
  alias Bilimbi.Finance.Receivables.Customer
  alias Bilimbi.Finance.Receivables.Document
  alias Bilimbi.Finance.Receivables.LedgerAccounts
  alias Bilimbi.Finance.Receivables.Payment
  alias Bilimbi.Finance.Receivables.PaymentReversal
  alias Bilimbi.Finance.Receivables.Records
  alias Bilimbi.Finance.Receivables.Series
  alias Ecto.Changeset

  ## Recording

  @doc """
  Records a payment allocated whole to issued invoices of its customer,
  numbers it next in its payment series, and posts the deposit against the
  receivable through the ledger facade.
  """
  def record(scope, company_id, attributes) do
    with {:ok, context} <- Configuration.context(scope, company_id) do
      %{book: book, setup: setup, accounts: accounts} = context
      {user_id, impersonator_id} = Records.actor_ids(scope)

      changeset =
        %Payment{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          currency_code: book.currency_code,
          recorded_by_user_id: user_id,
          recorded_by_impersonator_id: impersonator_id
        }
        |> Payment.changeset(attributes, book.minor_units)
        |> LedgerAccounts.validate(accounts, :deposit_account_id, "asset")
        |> validate_customer(scope, company_id)
        |> put_series_number(scope, company_id)
        |> put_allocations(scope, company_id, attributes, book.minor_units)

      with {:ok, changeset} <- valid(changeset),
           {:ok, entry} <-
             Ledger.post_entry(scope, company_id, entry(changeset, setup, scope, company_id)) do
        changeset
        |> Changeset.change(ledger_entry_id: entry.id, ledger_entry_number: entry.entry_number)
        |> Repo.insert()
        |> read_back(scope, company_id)
      end
    end
  end

  defp valid(%Changeset{valid?: true} = changeset), do: {:ok, changeset}
  defp valid(changeset), do: {:error, changeset}

  defp validate_customer(changeset, scope, company_id) do
    case Changeset.get_field(changeset, :customer_id) do
      nil ->
        changeset

      id ->
        case Records.get(Customer, scope, company_id, id) do
          nil ->
            Changeset.add_error(changeset, :customer_id, "is not a customer of this company")

          %Customer{active: false} ->
            Changeset.add_error(changeset, :customer_id, "is an inactive customer")

          %Customer{} ->
            changeset
        end
    end
  end

  defp put_series_number(changeset, scope, company_id) do
    with id when is_integer(id) <- Changeset.get_field(changeset, :series_id) do
      case Records.get(Series, scope, company_id, id) do
        %Series{kind: "payment", active: true} = series ->
          number = next_number(scope, company_id, series.id)

          Changeset.change(changeset,
            payment_number: number,
            payment_reference: Series.reference(series, number)
          )

        %Series{kind: "payment"} ->
          Changeset.add_error(changeset, :series_id, "is an inactive series")

        %Series{} ->
          Changeset.add_error(changeset, :series_id, "does not number payments")

        nil ->
          Changeset.add_error(changeset, :series_id, "is not a series of this company")
      end
    else
      _missing -> changeset
    end
  end

  defp next_number(scope, company_id, series_id) do
    Payment
    |> Records.query(scope, company_id)
    |> where([p], p.series_id == ^series_id)
    |> select([p], coalesce(max(p.payment_number), 0))
    |> Repo.one()
    |> Kernel.+(1)
  end

  # Each allocation names a distinct issued invoice of the payment's
  # customer, dated on or before the payment, for no more than it owes; the
  # allocations add up to the payment's amount.
  defp put_allocations(changeset, scope, company_id, attributes, minor_units) do
    allocations =
      attributes
      |> Records.fetch(:allocations)
      |> List.wrap()
      |> Enum.map(fn allocation ->
        %Allocation{tenant_id: Scope.tenant_id(scope), company_id: company_id}
        |> Allocation.changeset(if(is_map(allocation), do: allocation, else: %{}), minor_units)
      end)

    ids =
      allocations
      |> Enum.map(&Changeset.get_field(&1, :document_id))
      |> Enum.filter(&is_integer/1)

    invoices =
      scope
      |> Balances.invoices(company_id)
      |> where([d], d.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    owed =
      Balances.outstanding(
        scope,
        company_id,
        where(Balances.invoices(scope, company_id), [d], d.id in ^ids)
      )

    customer_id = Changeset.get_field(changeset, :customer_id)
    payment_date = Changeset.get_field(changeset, :payment_date)

    checked =
      allocations
      |> Enum.map_reduce(%{}, fn allocation, seen ->
        id = Changeset.get_field(allocation, :document_id)

        problem =
          case Map.get(invoices, id) do
            _invoice when not is_integer(id) ->
              nil

            _invoice when is_map_key(seen, id) ->
              "is allocated twice"

            %Document{customer_id: ^customer_id} = invoice ->
              invoice_problem(invoice, allocation, owed, payment_date)

            _other ->
              "is not an issued invoice of this customer"
          end

        allocation =
          if problem, do: Changeset.add_error(allocation, :document_id, problem), else: allocation

        {allocation, Map.put(seen, id, true)}
      end)
      |> elem(0)

    changeset
    |> Changeset.put_assoc(:allocations, checked)
    |> validate_allocated(checked)
  end

  defp invoice_problem(invoice, allocation, owed, payment_date) do
    amount = Changeset.get_field(allocation, :amount)

    cond do
      payment_date && Date.before?(payment_date, invoice.issue_date) ->
        "was issued after the payment date"

      amount && Decimal.gt?(amount, Map.fetch!(owed, invoice.id)) ->
        "owes less than the allocated amount"

      true ->
        nil
    end
  end

  defp validate_allocated(changeset, allocations) do
    amount = Changeset.get_field(changeset, :amount)

    cond do
      allocations == [] ->
        Changeset.add_error(changeset, :allocations, "needs at least one invoice")

      is_nil(amount) or not Enum.all?(allocations, & &1.valid?) ->
        changeset

      Decimal.equal?(sum(allocations), amount) ->
        changeset

      true ->
        Changeset.add_error(changeset, :allocations, "do not add up to the payment amount")
    end
  end

  defp sum(allocations),
    do:
      Enum.reduce(allocations, Decimal.new(0), &Decimal.add(Changeset.get_field(&1, :amount), &2))

  defp entry(changeset, setup, scope, company_id) do
    payment = Changeset.apply_changes(changeset)
    customer = Records.get(Customer, scope, company_id, payment.customer_id)

    %{
      entry_date: payment.payment_date,
      description: "Payment #{payment.payment_reference} from #{customer.name}",
      reference: payment.payment_reference,
      lines: [
        %{account_id: payment.deposit_account_id, debit: payment.amount},
        %{account_id: setup.receivable_account_id, credit: payment.amount}
      ]
    }
  end

  ## Reversing

  @doc """
  Reverses a payment on `reversal_date` (not before the payment's) for a
  `reason`: the ledger posts the reversal of its entry, and its allocations
  stop settling the invoices from that date. A payment is reversed once.
  """
  def reverse(scope, company_id, payment_id, attributes) do
    with {:ok, payment} <- reversible(scope, company_id, payment_id) do
      {user_id, impersonator_id} = Records.actor_ids(scope)

      changeset =
        %PaymentReversal{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          payment_id: payment.id,
          reversed_by_user_id: user_id,
          reversed_by_impersonator_id: impersonator_id
        }
        |> PaymentReversal.changeset(attributes)
        |> Changeset.validate_change(:reversal_date, fn :reversal_date, date ->
          if Date.before?(date, payment.payment_date),
            do: [reversal_date: "cannot be before the payment date"],
            else: []
        end)

      with {:ok, changeset} <- valid(changeset),
           {:ok, entry} <-
             Ledger.reverse_entry(scope, company_id, payment.ledger_entry_id, %{
               entry_date: Changeset.get_field(changeset, :reversal_date),
               description: "Reversal of payment #{payment.payment_reference}"
             }) do
        changeset
        |> Changeset.change(ledger_entry_id: entry.id, ledger_entry_number: entry.entry_number)
        |> Repo.insert()
        |> case do
          {:ok, _reversal} -> get(scope, company_id, payment.id)
          error -> error
        end
      end
    end
  end

  defp reversible(scope, company_id, payment_id) do
    case payment(scope, company_id, payment_id) do
      nil -> {:error, :payment_not_found}
      %Payment{reversal: nil} = payment -> {:ok, payment}
      %Payment{} -> {:error, :already_reversed}
    end
  end

  ## Reads

  def get(scope, company_id, payment_id) do
    case payment(scope, company_id, payment_id) do
      nil -> {:error, :payment_not_found}
      payment -> {:ok, view(payment)}
    end
  end

  def list(scope, company_id, options) do
    customer_id = Keyword.get(options, :customer_id)

    with {:ok, limit, cursor} <- Records.page_options(options),
         true <- is_nil(customer_id) or (is_integer(customer_id) and customer_id > 0) do
      payments =
        Payment
        |> Records.query(scope, company_id)
        |> then(fn query ->
          if customer_id, do: where(query, [p], p.customer_id == ^customer_id), else: query
        end)
        |> Records.page(limit, cursor)
        |> preload_parts(scope, company_id)
        |> Repo.all()

      {:ok, Enum.map(payments, &view/1)}
    else
      _invalid -> {:error, :invalid_option}
    end
  end

  defp payment(scope, company_id, payment_id) when is_integer(payment_id) do
    Payment
    |> Records.query(scope, company_id)
    |> where([p], p.id == ^payment_id)
    |> preload_parts(scope, company_id)
    |> Repo.one()
  end

  defp payment(_scope, _company_id, _payment_id), do: nil

  defp preload_parts(query, scope, company_id) do
    preload(query,
      allocations: ^order_by(Records.query(Allocation, scope, company_id), asc: :id),
      reversal: ^Records.query(PaymentReversal, scope, company_id)
    )
  end

  defp read_back({:ok, payment}, scope, company_id), do: get(scope, company_id, payment.id)
  defp read_back(error, _scope, _company_id), do: error

  defp view(payment) do
    payment
    |> Map.take([
      :id,
      :series_id,
      :customer_id,
      :payment_number,
      :payment_reference,
      :payment_date,
      :amount,
      :currency_code,
      :deposit_account_id,
      :reference,
      :description,
      :ledger_entry_id,
      :ledger_entry_number,
      :recorded_by_user_id,
      :recorded_by_impersonator_id,
      :recorded_at
    ])
    |> Map.put(
      :allocations,
      Enum.map(payment.allocations, &Map.take(&1, [:document_id, :amount]))
    )
    |> Map.put(
      :reversal,
      payment.reversal &&
        Map.take(payment.reversal, [
          :reversal_date,
          :reason,
          :ledger_entry_id,
          :ledger_entry_number,
          :reversed_by_user_id,
          :reversed_by_impersonator_id,
          :reversed_at
        ])
    )
  end
end
