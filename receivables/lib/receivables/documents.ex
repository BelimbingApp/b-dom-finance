defmodule Bilimbi.Finance.Receivables.Documents do
  @moduledoc false
  # Invoices and credit notes: drafts, issuing, and reads. The facade
  # authorizes every call and holds the company lock for writes.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Receivables.Balances
  alias Bilimbi.Finance.Receivables.Configuration
  alias Bilimbi.Finance.Receivables.Customer
  alias Bilimbi.Finance.Receivables.Document
  alias Bilimbi.Finance.Receivables.DocumentLine
  alias Bilimbi.Finance.Receivables.LedgerAccounts
  alias Bilimbi.Finance.Receivables.Records
  alias Bilimbi.Finance.Receivables.Series
  alias Bilimbi.Finance.Receivables.TaxCode
  alias Bilimbi.Finance.Receivables.TaxLine
  alias Ecto.Changeset

  ## Drafts

  def create_draft(scope, company_id, attributes) do
    with {:ok, context} <- Configuration.context(scope, company_id) do
      %Document{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        currency_code: context.book.currency_code,
        subtotal: Decimal.new(0),
        tax_total: Decimal.new(0),
        total: Decimal.new(0),
        lines: [],
        tax_lines: []
      }
      |> Document.create_changeset(attributes)
      |> validate_references(scope, company_id)
      |> put_lines(scope, company_id, context, Records.fetch(attributes, :lines) || [])
      |> Repo.insert()
      |> read_back(scope, company_id)
    end
  end

  def update_draft(scope, company_id, document_id, attributes) do
    with {:ok, context} <- Configuration.context(scope, company_id),
         {:ok, draft} <- draft(scope, company_id, document_id) do
      draft
      |> Document.update_changeset(attributes)
      |> validate_references(scope, company_id)
      |> put_lines(scope, company_id, context, Records.fetch(attributes, :lines))
      |> Repo.update()
      |> read_back(scope, company_id)
    end
  end

  # A discarded draft is kept, numberless, with who discarded it and when.
  def discard_draft(scope, company_id, document_id) do
    with {:ok, draft} <- draft(scope, company_id, document_id) do
      {user_id, _impersonator_id} = Records.actor_ids(scope)

      draft
      |> Changeset.change(status: "discarded", discarded_by_user_id: user_id)
      |> Repo.update()
      |> read_back(scope, company_id)
    end
  end

  defp draft(scope, company_id, document_id) do
    case document(scope, company_id, document_id) do
      nil -> {:error, :document_not_found}
      %Document{status: "draft"} = draft -> {:ok, draft}
      %Document{} -> {:error, :not_a_draft}
    end
  end

  # The series must number this kind of document and be active; an invoice's
  # customer must be active, a credit note's need not be, as it corrects an
  # existing invoice; a credit note credits an issued invoice of the customer.
  defp validate_references(changeset, scope, company_id) do
    kind = Changeset.get_field(changeset, :kind)
    customer_id = Changeset.get_field(changeset, :customer_id)

    changeset
    |> validate_record(:series_id, fn id ->
      case Records.get(Series, scope, company_id, id) do
        nil -> "is not a series of this company"
        %Series{kind: ^kind, active: true} -> nil
        %Series{kind: ^kind} -> "is an inactive series"
        %Series{} -> "does not number #{kind} documents"
      end
    end)
    |> validate_record(:customer_id, fn id ->
      case Records.get(Customer, scope, company_id, id) do
        nil -> "is not a customer of this company"
        %Customer{active: false} when kind == "invoice" -> "is an inactive customer"
        %Customer{} -> nil
      end
    end)
    |> validate_record(:credited_document_id, fn id ->
      case Records.get(Document, scope, company_id, id) do
        %Document{kind: "invoice", status: "issued", customer_id: ^customer_id} -> nil
        _other -> "is not an issued invoice of this customer"
      end
    end)
  end

  defp validate_record(changeset, field, problem) do
    with id when is_integer(id) <- Changeset.get_field(changeset, field),
         message when is_binary(message) <- problem.(id) do
      Changeset.add_error(changeset, field, message)
    else
      _no_problem -> changeset
    end
  end

  # Lines replace the draft's lines whole; their tax lines and the totals
  # follow from them. Omitting `lines` on an update keeps the lines.
  defp put_lines(changeset, _scope, _company_id, _context, nil), do: changeset

  defp put_lines(changeset, scope, company_id, context, lines) do
    cast =
      lines
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.map(fn {line, number} ->
        %DocumentLine{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          line_number: number
        }
        |> DocumentLine.changeset(
          if(is_map(line), do: line, else: %{}),
          context.setup.income_account_id
        )
        |> LedgerAccounts.validate(context.accounts, :account_id, "income")
      end)

    tax_codes =
      Records.query(TaxCode, scope, company_id)
      |> where([t], t.id in ^tax_code_ids(cast))
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    line_changesets = Enum.map(cast, &put_tax(&1, tax_codes, context.book.minor_units))
    changeset = Changeset.put_assoc(changeset, :lines, line_changesets)

    if Enum.all?(line_changesets, & &1.valid?),
      do: put_totals(changeset, scope, company_id, line_changesets, tax_codes),
      else: changeset
  end

  defp tax_code_ids(lines) do
    lines |> Enum.map(&Changeset.get_field(&1, :tax_code_id)) |> Enum.filter(&is_integer/1)
  end

  defp put_tax(line, tax_codes, minor_units) do
    case Changeset.get_field(line, :tax_code_id) do
      nil ->
        DocumentLine.put_amounts(line, minor_units, nil)

      id ->
        case Map.get(tax_codes, id) do
          %TaxCode{active: true, rate: rate} ->
            DocumentLine.put_amounts(line, minor_units, rate)

          %TaxCode{} ->
            Changeset.add_error(line, :tax_code_id, "is an inactive tax code")

          nil ->
            Changeset.add_error(line, :tax_code_id, "is not a tax code of this company")
        end
    end
  end

  defp put_totals(changeset, scope, company_id, lines, tax_codes) do
    tax_lines =
      lines
      |> Enum.filter(&Changeset.get_field(&1, :tax_code_id))
      |> Enum.group_by(&Changeset.get_field(&1, :tax_code_id))
      |> Enum.sort_by(fn {id, _lines} -> Map.fetch!(tax_codes, id).code end)
      |> Enum.map(fn {id, taxed} ->
        tax_code = Map.fetch!(tax_codes, id)

        %TaxLine{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          tax_code_id: id,
          tax_code: tax_code.code,
          tax_rate: tax_code.rate,
          taxable_amount: total(taxed, :amount),
          tax_amount: total(taxed, :tax_amount),
          account_id: tax_code.account_id
        }
      end)

    subtotal = total(lines, :amount)
    tax_total = total(lines, :tax_amount)

    changeset
    |> Changeset.put_assoc(:tax_lines, tax_lines)
    |> Changeset.put_change(:subtotal, subtotal)
    |> Changeset.put_change(:tax_total, tax_total)
    |> Changeset.put_change(:total, Decimal.add(subtotal, tax_total))
    |> Changeset.validate_number(:total, less_than: Decimal.new("1E16"))
  end

  defp total(lines, field) do
    Enum.reduce(lines, Decimal.new(0), &Decimal.add(field_value(&1, field), &2))
  end

  defp field_value(%Changeset{} = changeset, field), do: Changeset.get_field(changeset, field)
  defp field_value(record, field), do: Map.fetch!(record, field)

  ## Issuing

  @doc """
  Issues a draft: checks it as it stands, numbers it next in its series,
  copies the customer as its party, posts its entry through the ledger
  facade, and records the posting on the now immutable document.
  """
  def issue(scope, company_id, document_id) do
    with {:ok, context} <- Configuration.context(scope, company_id),
         {:ok, draft} <- draft(scope, company_id, document_id),
         {:ok, changeset} <- issue_changeset(scope, company_id, context, draft),
         {:ok, entry} <- post_entry(scope, company_id, changeset) do
      changeset
      |> Changeset.change(ledger_entry_id: entry.id, ledger_entry_number: entry.entry_number)
      |> Repo.update()
      |> read_back(scope, company_id)
    end
  end

  defp issue_changeset(scope, company_id, context, draft) do
    customer = Records.get(Customer, scope, company_id, draft.customer_id)
    series = Records.get(Series, scope, company_id, draft.series_id)
    {user_id, impersonator_id} = Records.actor_ids(scope)
    number = next_number(scope, company_id, series.id)

    changeset =
      draft
      |> Changeset.change(
        status: "issued",
        document_number: number,
        document_reference: Series.reference(series, number),
        receivable_account_id: receivable_account_id(scope, company_id, context, draft),
        issued_by_user_id: user_id,
        issued_by_impersonator_id: impersonator_id
      )
      |> Changeset.change(party(customer))
      |> Changeset.validate_required([:issue_date])
      |> put_due_date(customer)
      |> validate_issuable(customer, series)
      |> validate_posting_accounts(context)
      |> validate_credit(scope, company_id)

    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  # An invoice records the receivable account the setup names now; a credit
  # note posts to the one its invoice recorded. Later postings against a
  # document use its recorded account, whatever the setup becomes.
  defp receivable_account_id(scope, company_id, _context, %Document{kind: "credit_note"} = draft) do
    Records.get(Document, scope, company_id, draft.credited_document_id).receivable_account_id
  end

  defp receivable_account_id(_scope, _company_id, context, %Document{}),
    do: context.setup.receivable_account_id

  defp next_number(scope, company_id, series_id) do
    Records.query(Document, scope, company_id)
    |> where([d], d.series_id == ^series_id)
    |> select([d], coalesce(max(d.document_number), 0))
    |> Repo.one()
    |> Kernel.+(1)
  end

  @party_columns Enum.map(Customer.party_fields(), &{&1, :"party_#{&1}"})

  defp party(customer) do
    Map.new(@party_columns, fn {field, column} -> {column, Map.fetch!(customer, field)} end)
  end

  # An invoice falls due after its customer's payment terms unless the
  # draft names a due date.
  defp put_due_date(changeset, customer) do
    issue_date = Changeset.get_field(changeset, :issue_date)

    if Changeset.get_field(changeset, :kind) == "invoice" and not is_nil(issue_date) and
         is_nil(Changeset.get_field(changeset, :due_date)),
       do:
         Changeset.put_change(
           changeset,
           :due_date,
           Date.add(issue_date, customer.payment_terms_days)
         ),
       else: changeset
  end

  defp validate_issuable(changeset, customer, series) do
    changeset
    |> then(fn cs ->
      if customer.active or changeset.data.kind == "credit_note",
        do: cs,
        else: Changeset.add_error(cs, :customer_id, "is inactive")
    end)
    |> then(fn cs ->
      if series.active, do: cs, else: Changeset.add_error(cs, :series_id, "is inactive")
    end)
    |> then(fn cs ->
      cond do
        changeset.data.lines == [] -> Changeset.add_error(cs, :lines, "needs at least one line")
        Decimal.gt?(changeset.data.total, 0) -> cs
        true -> Changeset.add_error(cs, :total, "must be greater than zero")
      end
    end)
  end

  # Accounts may have been deactivated since the draft was saved. A credit
  # note's receivable account is its invoice's, which it settles, so it need
  # not be active.
  defp validate_posting_accounts(changeset, context) do
    draft = changeset.data
    receivable_id = Changeset.get_field(changeset, :receivable_account_id)

    checks =
      [{"receivable account", receivable_id, "asset", draft.kind == "invoice"}] ++
        Enum.map(draft.lines, &{"line #{&1.line_number} account", &1.account_id, "income", true}) ++
        Enum.map(
          draft.tax_lines,
          &{"tax code #{&1.tax_code} account", &1.account_id, "liability", true}
        )

    Enum.reduce(checks, changeset, fn {label, id, type, require_active}, acc ->
      case LedgerAccounts.problem(context.accounts, id, type, require_active) do
        nil -> acc
        message -> Changeset.add_error(acc, :lines, "#{label} #{message}")
      end
    end)
  end

  # A credit note is dated on or after its invoice and credits no more than
  # the invoice still owes.
  defp validate_credit(changeset, scope, company_id) do
    case changeset.data do
      %Document{kind: "credit_note", credited_document_id: credited_id, total: total} ->
        invoice = Records.get(Document, scope, company_id, credited_id)
        owed = Balances.outstanding_now(scope, company_id, credited_id)
        issue_date = Changeset.get_field(changeset, :issue_date)

        changeset
        |> then(fn cs ->
          if issue_date && Date.before?(issue_date, invoice.issue_date),
            do: Changeset.add_error(cs, :issue_date, "cannot be before the credited invoice's"),
            else: cs
        end)
        |> then(fn cs ->
          if owed && not Decimal.gt?(total, owed),
            do: cs,
            else: Changeset.add_error(cs, :total, "exceeds what the credited invoice still owes")
        end)

      %Document{} ->
        changeset
    end
  end

  # A credit note settles its invoice, so it may post to the receivable
  # account the invoice recorded even after that account was deactivated.
  # The entry names this document as its owner: the ledger refuses a second
  # entry for it and a reversal from anywhere but this module.
  defp post_entry(scope, company_id, changeset) do
    settled =
      if Changeset.get_field(changeset, :kind) == "credit_note",
        do: [Changeset.get_field(changeset, :receivable_account_id)],
        else: []

    Ledger.post_entry(scope, company_id, entry(changeset),
      settlement_account_ids: settled,
      owner: Records.owner(:document, changeset.data.id)
    )
  end

  # An invoice debits the receivable and credits income and tax; a credit
  # note posts the mirror image.
  defp entry(changeset) do
    document = Changeset.apply_changes(changeset)
    {receivable_side, other_side} = sides(document.kind)

    income = sum_by_account(document.lines, :amount)
    tax = sum_by_account(document.tax_lines, :tax_amount)

    lines =
      [%{receivable_side => document.total, account_id: document.receivable_account_id}] ++
        Enum.map(income ++ tax, fn {account_id, amount} ->
          %{other_side => amount, account_id: account_id}
        end)

    %{
      entry_date: document.issue_date,
      description:
        "#{label(document.kind)} #{document.document_reference} to #{document.party_name}",
      reference: document.document_reference,
      lines: lines
    }
  end

  defp sides("invoice"), do: {:debit, :credit}
  defp sides("credit_note"), do: {:credit, :debit}

  defp label("invoice"), do: "Invoice"
  defp label("credit_note"), do: "Credit note"

  defp sum_by_account(rows, field) do
    rows
    |> Enum.group_by(& &1.account_id, &Map.fetch!(&1, field))
    |> Enum.map(fn {account_id, amounts} ->
      {account_id, Enum.reduce(amounts, &Decimal.add/2)}
    end)
    |> Enum.reject(fn {_account_id, amount} -> Decimal.eq?(amount, 0) end)
    |> Enum.sort()
  end

  ## Reads

  def get(scope, company_id, document_id) do
    case document(scope, company_id, document_id) do
      nil -> {:error, :document_not_found}
      document -> {:ok, view(document, outstanding(scope, company_id, [document]))}
    end
  end

  def list(scope, company_id, options) do
    with {:ok, limit, cursor} <- Records.page_options(options),
         {:ok, filters} <- filters(options) do
      Records.query(Document, scope, company_id)
      |> where(^filters)
      |> Records.page(limit, cursor)
      |> preload_lines(scope, company_id)
      |> Repo.all()
      |> views(scope, company_id)
    end
  end

  # Issued documents in the order they were issued, for a consumer such as
  # an e-invoicing module to follow by the last ledger entry number it read.
  def list_issued(scope, company_id, options) do
    limit = Keyword.get(options, :limit, 100)
    cursor = Keyword.get(options, :after_entry_number, 0)

    if is_integer(limit) and limit in 1..500 and is_integer(cursor) and
         cursor in 0..Records.max_bigint() do
      Records.query(Document, scope, company_id)
      |> where([d], d.status == "issued" and d.ledger_entry_number > ^cursor)
      |> order_by([d], asc: d.ledger_entry_number)
      |> limit(^limit)
      |> preload_lines(scope, company_id)
      |> Repo.all()
      |> views(scope, company_id)
    else
      {:error, :invalid_option}
    end
  end

  @filters [kind: Document.kinds(), status: ~w(draft issued discarded)]

  defp filters(options) do
    Enum.reduce_while([:kind, :status, :customer_id], {:ok, []}, fn key, {:ok, acc} ->
      case {key, Keyword.get(options, key)} do
        {_key, nil} ->
          {:cont, {:ok, acc}}

        {:customer_id, id} when is_integer(id) and id > 0 ->
          {:cont, {:ok, [{:customer_id, id} | acc]}}

        {key, value} ->
          if value in Keyword.get(@filters, key, []),
            do: {:cont, {:ok, [{key, value} | acc]}},
            else: {:halt, {:error, :invalid_option}}
      end
    end)
  end

  defp views(documents, scope, company_id) do
    outstanding = outstanding(scope, company_id, documents)
    {:ok, Enum.map(documents, &view(&1, outstanding))}
  end

  defp outstanding(scope, company_id, documents) do
    ids = for %Document{kind: "invoice", status: "issued", id: id} <- documents, do: id

    if ids == [],
      do: %{},
      else:
        Balances.outstanding(
          scope,
          company_id,
          where(Balances.invoices(scope, company_id), [d], d.id in ^ids)
        )
  end

  def document(scope, company_id, document_id) when is_integer(document_id) do
    Records.query(Document, scope, company_id)
    |> where([d], d.id == ^document_id)
    |> preload_lines(scope, company_id)
    |> Repo.one()
  end

  def document(_scope, _company_id, _document_id), do: nil

  defp preload_lines(query, scope, company_id) do
    preload(query,
      lines: ^order_by(Records.query(DocumentLine, scope, company_id), asc: :line_number),
      tax_lines: ^order_by(Records.query(TaxLine, scope, company_id), asc: :tax_code)
    )
  end

  # Read back what PostgreSQL stored, so the result equals get/3's.
  defp read_back({:ok, document}, scope, company_id), do: get(scope, company_id, document.id)
  defp read_back(error, _scope, _company_id), do: error

  @fields [
    :id,
    :kind,
    :status,
    :series_id,
    :customer_id,
    :credited_document_id,
    :receivable_account_id,
    :currency_code,
    :issue_date,
    :due_date,
    :description,
    :subtotal,
    :tax_total,
    :total,
    :document_number,
    :document_reference,
    :party_name,
    :party_tax_identifier,
    :party_registration_identifier,
    :party_email,
    :party_phone,
    :party_line1,
    :party_line2,
    :party_line3,
    :party_locality,
    :party_postcode,
    :party_admin1_code,
    :party_country_iso,
    :ledger_entry_id,
    :ledger_entry_number,
    :issued_by_user_id,
    :issued_by_impersonator_id,
    :issued_at,
    :discarded_by_user_id,
    :discarded_at
  ]

  defp view(document, outstanding) do
    document
    |> Map.take(@fields)
    |> Map.put(:outstanding, Map.get(outstanding, document.id))
    |> Map.put(
      :lines,
      Enum.map(
        document.lines,
        &Map.take(&1, [
          :line_number,
          :description,
          :quantity,
          :unit_price,
          :amount,
          :account_id,
          :tax_code_id,
          :tax_rate,
          :tax_amount
        ])
      )
    )
    |> Map.put(
      :tax_lines,
      Enum.map(
        document.tax_lines,
        &Map.take(&1, [
          :tax_code_id,
          :tax_code,
          :tax_rate,
          :taxable_amount,
          :tax_amount,
          :account_id
        ])
      )
    )
  end
end
