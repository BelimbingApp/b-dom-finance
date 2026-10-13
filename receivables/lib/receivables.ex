defmodule Bilimbi.Finance.Receivables do
  @moduledoc """
  What a company's customers owe it: customers, invoices and credit notes,
  payments received, and aged receivables.

  Every function takes the validated `Bilimbi.Base.Tenancy.Scope` it was
  handed and an explicit company ID, and authorizes its capability for the
  scope's signed-in actor and the target company when it runs, through
  `Bilimbi.Core.Company.authorize_company_target/3`, as
  `Bilimbi.Finance.Ledger` does: a system scope, a missing grant, or a
  sibling company without tenant-wide reach is `{:error, :unauthorized}`,
  and a company the scope cannot see is `{:error, :company_not_found}`. A
  write then holds `Bilimbi.Core.Company.lock_writable_company/2` for its
  transaction, so an archived company is `{:error, :company_archived}` and
  the company's receivables writes run one at a time.

  Money moves only through the ledger's facade, with the same scope: issuing
  a document, recording a payment, and reversing one post a ledger entry in
  the same transaction, so the caller also needs the ledger capability that
  call asks for, and the ledger's refusal (such as `{:error, :book_not_open}`)
  is returned unchanged. Amounts are decimals in the currency of the
  company's book.

  A document is an invoice or a credit note. It is a draft, changed freely,
  until `issue_document/3` numbers it next in its series, copies its
  customer as the document's party, and posts it; from then on the database
  refuses any change to it. An issued invoice is corrected by a credit note,
  a mistaken payment by `reverse_payment/4`, and nothing is deleted.

  Results are plain maps; the schemas stay private to this module.
  """

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Receivables.{Aging, Configuration, Customers, Document, Documents}
  alias Bilimbi.Finance.Receivables.{Payments, Records, Series, TaxReport, TieOut}
  alias Ecto.Changeset

  @view "finance.receivables.view"
  @manage_setup "finance.receivables.setup.manage"
  @manage_customers "finance.receivables.customers.manage"
  @manage_documents "finance.receivables.documents.manage"
  @issue_documents "finance.receivables.documents.issue"
  @post_payments "finance.receivables.payments.post"

  @default_bucket_days [30, 60, 90]

  @type refusal :: :unauthorized | :company_not_found
  @type write_refusal :: refusal() | :company_archived
  @type context_refusal :: :book_not_open | :not_configured

  @doc "The capability every receivables read asks for."
  def view_capability, do: @view

  @doc "The capability that maintains the setup, series, and tax codes."
  def manage_setup_capability, do: @manage_setup

  @doc "The capability that maintains customers."
  def manage_customers_capability, do: @manage_customers

  @doc "The capability that creates, changes, and discards draft documents."
  def manage_documents_capability, do: @manage_documents

  @doc "The capability that issues documents."
  def issue_documents_capability, do: @issue_documents

  @doc "The capability that records and reverses payments."
  def post_payments_capability, do: @post_payments

  ## Setup

  @doc """
  The company's receivables setup: `%{company_id, receivable_account_id,
  income_account_id}`, or `{:error, :not_configured}`.
  """
  @spec get_setup(Scope.t(), term()) :: {:ok, map()} | {:error, refusal() | :not_configured}
  def get_setup(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case Configuration.setup(scope, company_id) do
        nil -> {:error, :not_configured}
        setup -> {:ok, Configuration.setup_view(setup)}
      end
    end
  end

  @doc """
  Sets the ledger accounts receivables posts to: `receivable_account_id`, an
  asset account, and `income_account_id`, the income account a document
  line posts to when it names none. Reads the chart through the ledger, so
  it also needs `finance.ledger.view`.

  A new `receivable_account_id` reaches only documents issued after it: an
  issued invoice records the account it was issued against, a credit note
  the account of the invoice it credits, and every payment against an
  invoice, and its reversal, posts to that recorded account. So the ledger's
  balance of each receivable account stays the sum of what its documents
  owe, however the setup changes. `list_setup_changes/3` keeps the history.
  """
  @spec configure(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def configure(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_setup, fn ->
      Configuration.configure(scope, company_id, attributes)
    end)
  end

  @doc """
  The history of the setup's accounts, oldest first, one entry per account
  set or changed: `%{id, field, old_value, new_value, changed_by_user_id,
  changed_by_impersonator_id, changed_at}` (`old_value` is nil when first
  set; the database stamps `changed_at`). Options: `limit` (1 to 500,
  default 100) and `after`, the last ID already read. A malformed option is
  `{:error, :invalid_option}`.
  """
  @spec list_setup_changes(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_setup_changes(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         do: Configuration.list_setup_changes(scope, company_id, options)
  end

  @doc "The company's document and payment series, ordered by code."
  @spec list_series(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_series(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view),
         do: {:ok, Configuration.list_series(scope, company_id)}
  end

  @doc """
  Adds a series: `code` (unique in the company), `name`, `kind` (one of
  `series_kinds/0`), `prefix` (unique in the company, may be empty), and
  `number_width`, the digits its numbers are zero-padded to (1 to 12). A
  series numbers its records 1, 2, 3, ... without gaps; its reference for
  number 42 with prefix `"A-"` and width 4 is `"A-0042"`. Code, kind,
  prefix, and width never change.
  """
  @spec create_series(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def create_series(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_setup, fn ->
      Configuration.create_series(scope, company_id, attributes)
    end)
  end

  @doc "Changes a series' `name` or `active` flag. An inactive series numbers nothing new."
  @spec update_series(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :series_not_found | Changeset.t()}
  def update_series(%Scope{} = scope, company_id, series_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_setup, fn ->
      Configuration.update_series(scope, company_id, series_id, attributes)
    end)
  end

  @doc "The kinds of record a series numbers."
  @spec series_kinds() :: [String.t()]
  def series_kinds, do: Series.kinds()

  @doc "The company's tax codes, ordered by code."
  @spec list_tax_codes(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_tax_codes(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view),
         do: {:ok, Configuration.list_tax_codes(scope, company_id)}
  end

  @doc """
  Adds a tax code: `code` (unique in the company), `name`, `rate` (a
  percentage from 0 to below 1000, up to four decimal places), and
  `account_id`, the liability account its tax posts to. Code and rate never
  change; a new rate is a new tax code. Also needs `finance.ledger.view`.
  """
  @spec create_tax_code(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def create_tax_code(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_setup, fn ->
      Configuration.create_tax_code(scope, company_id, attributes)
    end)
  end

  @doc "Changes a tax code's `name`, `account_id`, or `active` flag."
  @spec update_tax_code(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :tax_code_not_found | Changeset.t()}
  def update_tax_code(%Scope{} = scope, company_id, tax_code_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_setup, fn ->
      Configuration.update_tax_code(scope, company_id, tax_code_id, attributes)
    end)
  end

  ## Customers

  @doc "The company's customers, ordered by code."
  @spec list_customers(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_customers(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view),
         do: {:ok, Customers.list(scope, company_id)}
  end

  @doc "One customer."
  @spec get_customer(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :customer_not_found}
  def get_customer(%Scope{} = scope, company_id, customer_id) do
    with :ok <- authorize(scope, company_id, @view),
         do: Customers.get(scope, company_id, customer_id)
  end

  @doc """
  Adds a customer: `code` (unique in the company), `name`, and optionally
  `tax_identifier`, `registration_identifier`, `email`, `phone`, the
  address fields `line1`, `line2`, `line3`, `locality`, `postcode`,
  `admin1_code`, and `country_iso` (two upper-case letters),
  `payment_terms_days` (0 to 3650, default 0), and `active`.
  """
  @spec create_customer(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def create_customer(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_customers, fn ->
      Customers.create(scope, company_id, attributes)
    end)
  end

  @doc """
  Changes anything about a customer but its code. Issued documents keep the
  party as it was when they were issued. A customer is never deleted; an
  inactive one takes no new invoices, but its existing invoices can still be
  paid, credited, and have their payments reversed.
  """
  @spec update_customer(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :customer_not_found | Changeset.t()}
  def update_customer(%Scope{} = scope, company_id, customer_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_customers, fn ->
      Customers.update(scope, company_id, customer_id, attributes)
    end)
  end

  ## Documents

  @doc "The kinds of document: `invoice` and `credit_note`."
  @spec document_kinds() :: [String.t()]
  def document_kinds, do: Document.kinds()

  @doc """
  Creates a draft document: `kind`, `series_id` (a series of that kind),
  `customer_id`, optionally `issue_date`, `due_date`, `description`, and
  `lines`, and for a credit note `credited_document_id`, an issued invoice
  of the same customer. Each line is `%{description, quantity, unit_price}`
  with an optional income `account_id` (default: the setup's) and
  `tax_code_id`. A line's amount is quantity times unit price and its tax
  the tax code's rate of that amount, each rounded half up to the book's
  minor units; the tax lines sum the lines per tax code. Reads the book and
  chart through the ledger, so it also needs `finance.ledger.view`.
  """
  @spec create_draft(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | context_refusal() | Changeset.t()}
  def create_draft(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_documents, fn ->
      Documents.create_draft(scope, company_id, attributes)
    end)
  end

  @doc """
  Changes a draft, with the same attributes as `create_draft/3` but `kind`.
  Passing `lines` replaces them all; omitting it keeps them.
  `{:error, :not_a_draft}` once the document is issued or discarded.
  """
  @spec update_draft(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | context_refusal()
             | :document_not_found
             | :not_a_draft
             | Changeset.t()}
  def update_draft(%Scope{} = scope, company_id, document_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_documents, fn ->
      Documents.update_draft(scope, company_id, document_id, attributes)
    end)
  end

  @doc "Discards a draft. It is kept, unnumbered, with who discarded it and when."
  @spec discard_draft(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, write_refusal() | :document_not_found | :not_a_draft}
  def discard_draft(%Scope{} = scope, company_id, document_id) do
    write(scope, company_id, @manage_documents, fn ->
      Documents.discard_draft(scope, company_id, document_id)
    end)
  end

  @doc """
  Issues a draft. It needs an `issue_date`, at least one line, a total above
  zero, an active series and (for an invoice) customer, and active ledger accounts of the
  right types (a credit note's receivable account is its invoice's and may
  be inactive, as it settles that invoice); an invoice without a `due_date` falls due after the
  customer's payment terms; a credit note is dated no earlier than its
  invoice and credits no more than the invoice still owes. Issuing numbers
  the document next in its series, copies the customer's party fields onto
  it, and posts its entry through `Bilimbi.Finance.Ledger.post_entry/4`
  (so it also needs `finance.ledger.entries.post`): an invoice debits the
  setup's receivable account with its total and credits each income account
  and each tax code's account; a credit note posts the reverse, against the
  receivable account its invoice recorded. The document records that
  account (`receivable_account_id`), the entry's ID and number, and who
  issued it; the database stamps when.
  """
  @spec issue_document(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | context_refusal()
             | :document_not_found
             | :not_a_draft
             | Changeset.t()}
  def issue_document(%Scope{} = scope, company_id, document_id) do
    write(scope, company_id, @issue_documents, fn ->
      Documents.issue(scope, company_id, document_id)
    end)
  end

  @doc """
  One document with its lines and tax lines, and, for an issued invoice,
  `outstanding`: its total less its issued credit notes and its allocations
  from payments that were not reversed.
  """
  @spec get_document(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :document_not_found}
  def get_document(%Scope{} = scope, company_id, document_id) do
    with :ok <- authorize(scope, company_id, @view),
         do: Documents.get(scope, company_id, document_id)
  end

  @doc """
  Documents ordered by ID. Options: `kind`, `status` (`draft`, `issued`, or
  `discarded`), `customer_id`, `limit` (1 to 500, default 100), and
  `after`, the last ID already read. A malformed option is
  `{:error, :invalid_option}`.
  """
  @spec list_documents(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_documents(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         do: Documents.list(scope, company_id, options)
  end

  @doc """
  Issued documents in the order they were issued, by the ledger entry
  number each posted: the seam a module that submits documents elsewhere,
  such as an e-invoicing module, follows. Pass `after_entry_number`, the
  last `ledger_entry_number` already handled (default 0), and `limit` (1 to
  500, default 100); an issued document never changes, so each is read
  once. A malformed option is `{:error, :invalid_option}`.
  """
  @spec list_issued_documents(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_issued_documents(%Scope{} = scope, company_id, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         do: Documents.list_issued(scope, company_id, options)
  end

  @doc """
  The tax on issued documents, summed by PostgreSQL per document `kind`,
  tax code, rate, and tax account: `%{kind, credits_prior_period,
  tax_code_id, tax_code, tax_rate, account_id, document_count,
  taxable_amount, tax_amount}`, each amount as the document carries it (a
  credit note's positive). `credits_prior_period` is true for a credit
  note whose invoice was issued before `from`. Options:
  `from` and `to`, issue dates (inclusive), and `through_entry_number`,
  which counts only documents whose ledger entry is numbered up to it, so
  a reading pinned to a ledger entry number reproduces exactly. A module
  reporting tax to an authority reads it; a malformed option is
  `{:error, :invalid_option}`.
  """
  @spec tax_totals(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def tax_totals(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         do: TaxReport.totals(scope, company_id, options)
  end

  @doc """
  The tax share of what customers paid in a window, for tax that is due
  when payment is received, or once an invoice has gone unpaid for
  `unpaid_months` months (default 12) after its issue date: `%{measure,
  tax_code_id, tax_code, tax_rate, account_id, document_count,
  taxable_amount, tax_amount}` per measure, tax code, rate, and tax
  account. `measure` is `received` (each allocation of a payment dated in
  the window, before its invoice fell due under that rule, as its share of
  the invoice total, less the share of such payments reversed in the
  window), `unpaid` (an invoice whose due day falls in the window, as the
  share it still owed the day before), or `credited_after_due` (credit
  notes issued in the window on an invoice already due under the rule, as
  they carry their tax). Amounts are exact shares, unrounded. Needs `from`
  and `to`; `through_entry_number` pins every document, payment, and
  reversal to the ledger entries it posted, so the reading reproduces. A
  malformed option is `{:error, :invalid_option}`.
  """
  @spec received_tax_totals(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def received_tax_totals(%Scope{} = scope, company_id, options) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         do: TaxReport.received_totals(scope, company_id, options)
  end

  ## Payments

  @doc """
  Records a payment received: `series_id` (a payment series),
  `customer_id`, `payment_date`, `amount`, `deposit_account_id` (the asset
  account it was paid into), optionally `reference` and `description`, and
  `allocations`, each `%{document_id, amount}` naming a distinct issued
  invoice of the customer dated on or before the payment, for no more than
  it owes. The allocations add up to the amount; a payment may settle an
  invoice in part. It is numbered next in its series and posted through
  `Bilimbi.Finance.Ledger.post_entry/4` (so it also needs
  `finance.ledger.entries.post`), debiting the deposit account and crediting
  each allocated invoice's recorded receivable account with the amount
  allocated to it, even if that account has been deactivated since: an
  inactive account blocks new business, not settling an existing invoice.
  """
  @spec record_payment(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | context_refusal() | Changeset.t()}
  def record_payment(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @post_payments, fn ->
      Payments.record(scope, company_id, attributes)
    end)
  end

  @doc """
  Reverses a payment on `reversal_date` (not before the payment's) for a
  `reason`, through `Bilimbi.Finance.Ledger.reverse_owned_entry/5`. Its
  allocations stop settling the invoices from that date. A payment is
  reversed once (`{:error, :already_reversed}`); a corrected payment is
  recorded anew.
  """
  @spec reverse_payment(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :payment_not_found | :already_reversed | Changeset.t()}
  def reverse_payment(%Scope{} = scope, company_id, payment_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @post_payments, fn ->
      Payments.reverse(scope, company_id, payment_id, attributes)
    end)
  end

  @doc "One payment with its allocations and its reversal, if any."
  @spec get_payment(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :payment_not_found}
  def get_payment(%Scope{} = scope, company_id, payment_id) do
    with :ok <- authorize(scope, company_id, @view),
         do: Payments.get(scope, company_id, payment_id)
  end

  @doc """
  Payments ordered by ID. Options: `customer_id`, `limit` (1 to 500,
  default 100), and `after`, the last ID already read. A malformed option
  is `{:error, :invalid_option}`.
  """
  @spec list_payments(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_payments(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         do: Payments.list(scope, company_id, options)
  end

  ## Aged receivables

  @doc """
  Aged receivables as of a date: each customer's issued invoices that still
  owe something, with what they owe and how many days past due they are,
  in buckets: not yet due, then one per limit in `bucket_days` (ascending
  positive integers, default `#{inspect(@default_bucket_days)}`), then
  older. Customer and bucket totals sum the invoices.

  Every invoice, credit note, payment, and reversal counts from its own
  date and posted one ledger entry. The result names `through_entry_number`,
  the last entry it counts; passing the same `as_of` and
  `through_entry_number` reproduces the report's figures exactly, as the
  ledger's trial balance does, so a back-dated document issued later does
  not change a report already given. Customer codes and names are read as
  they are now. Reads the book through the ledger, so it also needs
  `finance.ledger.view`. A malformed option is `{:error, :invalid_option}`.
  """
  @spec aged_receivables(Scope.t(), term(), Date.t(), keyword()) ::
          {:ok, map()} | {:error, refusal() | :book_not_open | :invalid_option}
  def aged_receivables(%Scope{} = scope, company_id, %Date{} = as_of, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, through, bucket_days} <- aging_options(options),
         {:ok, book} <- Ledger.get_book(scope, company_id) do
      {:ok, Aging.report(scope, company_id, book, as_of, through, bucket_days)}
    end
  end

  @doc """
  The control-account tie-out as of a date: for each receivable account
  (every one an issued document recorded, the setup's, and any this module
  posted to), what this module's records say is still owed on it
  (`subledger_balance`, the aged receivables' total for the account), what
  the ledger holds on it (`ledger_balance`, debits less credits over every
  entry dated through `as_of`), the part of that this module posted
  (`owned_balance`), and every other posting on the account
  (`other_postings`, one per owner module, `nil` for an entry with no
  owner, with `legacy` for one posted before owners were recorded), each
  with its balance. `difference` is `subledger_balance` less
  `ledger_balance`, and `tied_out?` whether every account's is zero: an
  entry reversed outside this module, a manual journal on the account, a
  sale posted by another module as well, each shows here as a difference
  with its posting, never netted away.

  All figures are read at one ledger entry number, named
  `through_entry_number`; passing it back reproduces the tie-out exactly.
  Reads the ledger, so it also needs `finance.ledger.view`. A malformed
  option is `{:error, :invalid_option}`.
  """
  @spec tie_out_control_accounts(Scope.t(), term(), Date.t(), keyword()) ::
          {:ok, map()} | {:error, refusal() | :book_not_open | :invalid_option}
  def tie_out_control_accounts(%Scope{} = scope, company_id, %Date{} = as_of, options \\ [])
      when is_list(options) do
    through = Keyword.get(options, :through_entry_number)

    with :ok <- authorize(scope, company_id, @view),
         true <-
           (Keyword.keys(options) -- [:through_entry_number] == [] and
              (is_nil(through) or (is_integer(through) and through in 0..Records.max_bigint()))) ||
             {:error, :invalid_option} do
      TieOut.report(scope, company_id, as_of, through)
    end
  end

  defp aging_options(options) do
    through = Keyword.get(options, :through_entry_number)
    days = Keyword.get(options, :bucket_days, @default_bucket_days)

    if (is_nil(through) or (is_integer(through) and through in 0..Records.max_bigint())) and
         ascending_days?(days),
       do: {:ok, through, days},
       else: {:error, :invalid_option}
  end

  defp ascending_days?([_ | _] = days) do
    Enum.all?(days, &(is_integer(&1) and &1 > 0 and &1 <= 36_500)) and
      days == Enum.uniq(Enum.sort(days))
  end

  defp ascending_days?(_days), do: false

  ## Authorization and writes

  # The actor's current grant and company reach decide every call.
  defp authorize(scope, company_id, capability) do
    case Company.authorize_company_target(scope, company_id, capability) do
      {:ok, _company} -> :ok
      {:error, :not_found} -> {:error, :company_not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  defp write(scope, company_id, capability, fun) do
    with :ok <- authorize(scope, company_id, capability) do
      Repo.transact(fn ->
        case Company.lock_writable_company(scope, company_id) do
          {:ok, _proof} -> fun.()
          {:error, :not_found} -> {:error, :company_not_found}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end
end
