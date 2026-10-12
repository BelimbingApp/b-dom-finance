defmodule Bilimbi.Finance.Payables do
  @moduledoc """
  A company's accounts payable: documents from parties (bills and the debit
  notes that correct them), payments allocated to bills, and what is owed to
  whom as of any date.

  Every function takes the validated `Bilimbi.Base.Tenancy.Scope` it was
  handed and an explicit company ID. Reads authorize `finance.payables.view`
  and writes their own capability for the scope's signed-in actor and the
  target company at the moment they run, through
  `Bilimbi.Core.Company.authorize_company_target/3`: a system scope, a
  missing grant, or a sibling company without tenant-wide reach is
  `{:error, :unauthorized}`, and a company the scope cannot see is
  `{:error, :company_not_found}`. A write then holds
  `Bilimbi.Core.Company.lock_writable_company/2` for its transaction, so an
  archived company is `{:error, :company_archived}` and the company's
  payables writes run one at a time.

  Amounts are in the currency of the company's ledger book and posting goes
  through the `Bilimbi.Finance.Ledger` facade with the same scope, so a
  write also needs the ledger capability its ledger call asks for:
  `finance.ledger.view` to read the book and chart of accounts, and
  `finance.ledger.entries.post` to post.

  A document is recorded whole as a draft, approved, then posted; before it
  is posted it may be voided instead. Posting numbers it, per company and
  document type, without gaps, and posts its ledger entry. A posted document
  is never changed: a bill is corrected by a debit note against it. A payment
  is posted with its allocations to bills and corrected by its reversal.
  Nothing is deleted; the database refuses the same things on its own (see
  the migration). A change to the payable account or a tax code is recorded
  with who made it, why, and the values before and after, and never altered
  (`list_settings_changes/2`, `list_tax_code_changes/2`).

  Results are plain maps; the schemas stay private to this module.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Payables.Allocation
  alias Bilimbi.Finance.Payables.Amount
  alias Bilimbi.Finance.Payables.Balances
  alias Bilimbi.Finance.Payables.Document
  alias Bilimbi.Finance.Payables.DocumentLine
  alias Bilimbi.Finance.Payables.Payment
  alias Bilimbi.Finance.Payables.Settings
  alias Bilimbi.Finance.Payables.SettingsChange
  alias Bilimbi.Finance.Payables.TaxCode
  alias Bilimbi.Finance.Payables.TaxCodeChange
  alias Bilimbi.Finance.Payables.TaxLine
  alias Ecto.Changeset

  @view "finance.payables.view"
  @manage_settings "finance.payables.settings.manage"
  @create_documents "finance.payables.documents.create"
  @approve_documents "finance.payables.documents.approve"
  @post_documents "finance.payables.documents.post"
  @post_payments "finance.payables.payments.post"

  @party_fields [:party_key, :party_name, :party_tax_id, :party_registration_id, :party_address]

  @line_account_types ~w(asset expense)
  @payable_account_types ~w(liability)
  @paid_from_account_types ~w(asset liability)

  @default_limit 100
  @max_limit 500
  @max_bigint 9_223_372_036_854_775_807

  @type refusal :: :unauthorized | :company_not_found
  @type write_refusal :: refusal() | :company_archived

  @doc "The capability every payables read asks for."
  def view_capability, do: @view

  @doc "The capability that sets the payable account and maintains tax codes."
  def manage_settings_capability, do: @manage_settings

  @doc "The capability that records draft documents."
  def create_documents_capability, do: @create_documents

  @doc "The capability that approves or voids documents before they post."
  def approve_documents_capability, do: @approve_documents

  @doc "The capability that posts approved documents to the ledger."
  def post_documents_capability, do: @post_documents

  @doc "The capability that posts and reverses payments."
  def post_payments_capability, do: @post_payments

  @doc "The document types: a party's bill, and our debit note against one."
  @spec document_types() :: [String.t()]
  def document_types, do: Document.types()

  @doc "The statuses a document moves through."
  @spec document_statuses() :: [String.t()]
  def document_statuses, do: Document.statuses()

  ## Settings

  @doc """
  The company's payables settings: `%{company_id, payable_account_id}`, or
  `{:error, :payables_not_configured}` before `put_settings/3`.
  """
  @spec get_settings(Scope.t(), term()) ::
          {:ok, map()} | {:error, refusal() | :payables_not_configured}
  def get_settings(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case settings(scope, company_id) do
        nil -> {:error, :payables_not_configured}
        settings -> {:ok, settings_view(settings)}
      end
    end
  end

  @doc """
  Sets `payable_account_id`, the active liability account a posted bill
  credits. A change applies to documents posted afterwards; each posted
  document keeps the account it posted to, and payments against it debit
  that account. An optional `reason` is kept with the change in
  `list_settings_changes/2`.
  """
  @spec put_settings(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def put_settings(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_settings, fn ->
      with {:ok, accounts} <- ledger_accounts(scope, company_id) do
        previous = settings(scope, company_id)

        changeset =
          (previous || %Settings{tenant_id: Scope.tenant_id(scope), company_id: company_id})
          |> Settings.changeset(attributes)
          |> check_account(:payable_account_id, accounts, @payable_account_types)

        changeset
        |> Repo.insert_or_update()
        |> record_settings_change(scope, previous, changeset, attributes)
        |> public_result(&settings_view/1)
      end
    end)
  end

  @doc """
  The changes made to the payable account, oldest first: `old_payable_account_id`
  (nil the first time), `new_payable_account_id`, the optional `reason`, who
  made it (`changed_by_user_id`, `changed_by_impersonator_id`), and
  `changed_at`, the database's time.
  """
  @spec list_settings_changes(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_settings_changes(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok,
       from(c in Tenancy.scope_query(SettingsChange, scope),
         where: c.company_id == ^company_id,
         order_by: [asc: c.id]
       )
       |> Repo.all()
       |> Enum.map(
         &Map.take(&1, [
           :id,
           :old_payable_account_id,
           :new_payable_account_id,
           :reason,
           :changed_by_user_id,
           :changed_by_impersonator_id,
           :changed_at
         ])
       )}
    end
  end

  ## Tax codes

  @doc "The company's tax codes, ordered by code."
  @spec list_tax_codes(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_tax_codes(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok,
       scope
       |> tax_codes_query(company_id)
       |> order_by([t], asc: t.code)
       |> Repo.all()
       |> Enum.map(&tax_code_view/1)}
    end
  end

  @doc """
  Adds a tax code: `code` (unique in the company), `name`, `rate` (a
  percentage, at least zero, up to four decimal places), `account_id` (the
  active ledger account its tax is debited to), and optionally `active`.
  The code, rate, and account are a company's configuration; this module
  ships none. An optional `reason` is kept with the change in
  `list_tax_code_changes/2`.
  """
  @spec create_tax_code(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def create_tax_code(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_settings, fn ->
      with {:ok, accounts} <- ledger_accounts(scope, company_id) do
        %TaxCode{tenant_id: Scope.tenant_id(scope), company_id: company_id}
        |> TaxCode.create_changeset(attributes)
        |> check_account(:account_id, accounts, :any)
        |> Repo.insert()
        |> record_tax_code_change(scope, nil, true, attributes)
        |> public_result(&tax_code_view/1)
      end
    end)
  end

  @doc """
  Changes a tax code's `name`, `rate`, `account_id`, or `active` flag; its
  code never changes. Documents already recorded keep the code, rate, and
  account they copied. An optional `reason` is kept with the change in
  `list_tax_code_changes/2`.
  """
  @spec update_tax_code(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :tax_code_not_found | Changeset.t()}
  def update_tax_code(%Scope{} = scope, company_id, tax_code_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_settings, fn ->
      with {:ok, tax_code} <- fetch_tax_code(scope, company_id, tax_code_id),
           {:ok, accounts} <- ledger_accounts(scope, company_id) do
        changeset =
          tax_code
          |> TaxCode.update_changeset(attributes)
          |> check_account(:account_id, accounts, :any)

        changeset
        |> Repo.update()
        |> record_tax_code_change(scope, tax_code, changeset.changes != %{}, attributes)
        |> public_result(&tax_code_view/1)
      end
    end)
  end

  @doc """
  The changes made to the company's tax codes, oldest first: the
  `tax_code_id`, its `old_` and `new_` `name`, `rate`, `account_id`, and
  `active` (the `old_` ones nil when the code was added), the optional
  `reason`, who made the change (`changed_by_user_id`,
  `changed_by_impersonator_id`), and `changed_at`, the database's time.
  """
  @spec list_tax_code_changes(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_tax_code_changes(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok,
       from(c in Tenancy.scope_query(TaxCodeChange, scope),
         where: c.company_id == ^company_id,
         order_by: [asc: c.id]
       )
       |> Repo.all()
       |> Enum.map(
         &Map.take(&1, [
           :id,
           :tax_code_id,
           :old_name,
           :new_name,
           :old_rate,
           :new_rate,
           :old_account_id,
           :new_account_id,
           :old_active,
           :new_active,
           :reason,
           :changed_by_user_id,
           :changed_by_impersonator_id,
           :changed_at
         ])
       )}
    end
  end

  ## Documents

  @doc """
  Records a party's bill as a draft.

  Attributes: the party snapshot (`party_key`, the company's own stable key
  for the party; `party_name`; and optionally `party_tax_id`,
  `party_registration_id`, and `party_address`), `party_document_number`
  (the party's own number for the bill, recorded once per party),
  `document_date`, optional `due_date` (default the document date) and
  `description`, and `lines`, each `%{description, account_id, amount}`
  with an optional `tax_code_id` and `external_order_line_id`.

  A line's account is an active asset or expense account of the ledger and
  its amount is net of tax. Each tax code the lines use becomes a tax line:
  the lines' total for that code and its tax at the code's rate, rounded
  half up to the book's minor units. Optional `tax_lines`, each
  `%{tax_code_id, tax_amount}`, records the party's own tax figure for a
  code instead.
  """
  @spec create_bill(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :book_not_open | Changeset.t()}
  def create_bill(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @create_documents, fn ->
      with {:ok, book} <- Ledger.get_book(scope, company_id),
           {:ok, accounts} <- ledger_accounts(scope, company_id) do
        scope
        |> document_changeset(book, "bill", attributes, accounts)
        |> insert_document(scope)
      end
    end)
  end

  @doc """
  Records a debit note against a posted bill as a draft: what the party
  credits back, taken off what the company owes on that bill. Attributes
  are `create_bill/3`'s without the party, which is copied from the bill;
  `party_document_number` is optional. Its date is not before the bill's,
  and its total cannot exceed what is still owed on the bill, now and as
  of the debit note's date (`{:error, :exceeds_outstanding}`, checked again
  when it posts).
  """
  @spec create_debit_note(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :book_not_open
             | :document_not_found
             | :not_a_posted_bill
             | :exceeds_outstanding
             | Changeset.t()}
  def create_debit_note(%Scope{} = scope, company_id, bill_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @create_documents, fn ->
      with {:ok, bill} <- fetch_posted_bill(scope, company_id, bill_id),
           {:ok, book} <- Ledger.get_book(scope, company_id),
           {:ok, accounts} <- ledger_accounts(scope, company_id) do
        party = Map.take(bill, @party_fields)

        changeset =
          scope
          |> document_changeset(book, "debit_note", with_party(attributes, party), accounts)
          |> Changeset.put_change(:corrects_document_id, bill.id)
          |> Changeset.validate_change(:document_date, fn :document_date, date ->
            if Date.compare(date, bill.document_date) == :lt,
              do: [document_date: "cannot be before the corrected bill's date"],
              else: []
          end)

        with :ok <- within_outstanding(scope, company_id, bill, changeset) do
          insert_document(changeset, scope)
        end
      end
    end)
  end

  @doc "Approves a draft document. Anything else is `{:error, :not_draft}`."
  @spec approve_document(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, write_refusal() | :document_not_found | :not_draft}
  def approve_document(%Scope{} = scope, company_id, document_id) do
    write(scope, company_id, @approve_documents, fn ->
      with {:ok, document} <- fetch_document(scope, company_id, document_id),
           :ok <- require_status(document, "draft", :not_draft) do
        %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

        document
        |> Changeset.change(
          status: "approved",
          approved_by_user_id: user_id,
          approved_by_impersonator_id: impersonator_id
        )
        |> update_document(scope)
      end
    end)
  end

  @doc """
  Voids a draft or approved document with a `void_reason`; it stays on
  record and frees its party document number. A posted or voided document is
  `{:error, :not_voidable}`: correct a posted bill with a debit note.
  """
  @spec void_document(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :document_not_found | :not_voidable | Changeset.t()}
  def void_document(%Scope{} = scope, company_id, document_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @approve_documents, fn ->
      with {:ok, document} <- fetch_document(scope, company_id, document_id) do
        if document.status in ["draft", "approved"] do
          document
          |> Document.void_changeset(attributes, Scope.actor(scope))
          |> update_document(scope)
        else
          {:error, :not_voidable}
        end
      end
    end)
  end

  @doc """
  Posts an approved document to the ledger on its document date and numbers
  it. A bill debits each line's account and each tax line's account and
  credits the payable account with its total; a debit note posts the
  opposite. Anything but an approved document is `{:error, :not_approved}`;
  `{:error, :payables_not_configured}` before `put_settings/3`. A refusal
  from the ledger, such as an account deactivated since the document was
  recorded, is the ledger's changeset.
  """
  @spec post_document(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :document_not_found
             | :not_approved
             | :payables_not_configured
             | :exceeds_outstanding
             | Changeset.t()}
  def post_document(%Scope{} = scope, company_id, document_id) do
    write(scope, company_id, @post_documents, fn ->
      with {:ok, document} <- fetch_document(scope, company_id, document_id),
           :ok <- require_status(document, "approved", :not_approved),
           {:ok, payable_account_id} <- posting_account(scope, company_id, document),
           {:ok, entry} <-
             Ledger.post_entry(scope, company_id, document_entry(document, payable_account_id)) do
        %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

        document
        |> Changeset.change(
          status: "posted",
          posted_by_user_id: user_id,
          posted_by_impersonator_id: impersonator_id,
          payable_account_id: payable_account_id,
          entry_id: entry.id,
          entry_number: entry.entry_number
        )
        |> update_document(scope)
      end
    end)
  end

  @doc """
  One document with its lines and tax lines, and `debit_note_ids`, the
  debit notes recorded against it. A posted bill also shows `outstanding`,
  what is still owed on it now; `list_payments/3` with `document_id` lists
  the payments allocated to it.
  """
  @spec get_document(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :document_not_found}
  def get_document(%Scope{} = scope, company_id, document_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, document} <- fetch_document(scope, company_id, document_id) do
      {:ok, hd(document_views(scope, company_id, [document]))}
    end
  end

  @doc """
  Documents with their lines, ordered by document date and then ID.
  Options: `document_type`, `status`, `party_key`, `from` and `to` dates
  (inclusive), `limit` (1 to #{@max_limit}, default #{@default_limit}), and
  `after`, the `{document_date, id}` of the last document already read. A
  malformed option is `{:error, :invalid_option}`.
  """
  @spec list_documents(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_documents(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, page} <- page_options(options),
         {:ok, filters} <- document_filters(options) do
      documents =
        scope
        |> documents_query(company_id)
        |> where(^filters)
        |> date_bound(:document_date, page)
        |> after_cursor(:document_date, page.after)
        |> order_by([d], asc: d.document_date, asc: d.id)
        |> limit(^page.limit)
        |> preload(^document_preloads(scope))
        |> Repo.all()

      {:ok, document_views(scope, company_id, documents)}
    end
  end

  defp document_filters(options) do
    filters =
      for {key, allowed} <- [
            document_type: Document.types(),
            status: Document.statuses(),
            party_key: :any
          ],
          value = Keyword.get(options, key),
          not is_nil(value),
          do: {key, value, allowed}

    if Enum.all?(filters, fn {_key, value, allowed} ->
         is_binary(value) and (allowed == :any or value in allowed)
       end),
       do: {:ok, Enum.map(filters, fn {key, value, _allowed} -> {key, value} end)},
       else: {:error, :invalid_option}
  end

  ## Payments

  @doc """
  Posts a payment to one party: `payment_date`, `party_key`,
  `paid_from_account_id` (an active asset or liability account, such as a
  bank account), optional `reference` and `description`, and `allocations`,
  each `%{document_id, amount}` naming a posted bill of that party dated on
  or before the payment. The payment's amount is the allocations' total; an
  allocation cannot exceed what is still owed on its bill, so a bill may be
  paid in parts. It must also fit what was owed on the bill as of the payment's
  date, so a later reversal of an earlier payment cannot leave the bill owed
  less than nothing. The ledger entry debits each bill's payable account and
  credits the paid-from account.
  """
  @spec post_payment(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :book_not_open | Changeset.t()}
  def post_payment(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @post_payments, fn ->
      with {:ok, book} <- Ledger.get_book(scope, company_id),
           {:ok, accounts} <- ledger_accounts(scope, company_id) do
        {changeset, bills} = payment_changeset(scope, company_id, book, attributes, accounts)

        with {:ok, changeset} <- valid(changeset),
             {:ok, entry} <-
               Ledger.post_entry(scope, company_id, payment_entry(changeset, bills)) do
          changeset
          |> Changeset.put_change(:entry_id, entry.id)
          |> Changeset.put_change(:entry_number, entry.entry_number)
          |> insert_payment(scope)
        end
      end
    end)
  end

  @doc """
  Posts the reversal of a payment on `payment_date` (not before the
  original's) with an optional `description`: the ledger reverses its entry,
  and its bills are owed again from that date. A payment is reversed at most
  once (`{:error, :already_reversed}`), and a reversal is not itself
  reversed (`{:error, :reversal_not_reversible}`).
  """
  @spec reverse_payment(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :payment_not_found
             | :already_reversed
             | :reversal_not_reversible
             | Changeset.t()}
  def reverse_payment(%Scope{} = scope, company_id, payment_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @post_payments, fn ->
      with {:ok, original} <- reversible_payment(scope, company_id, payment_id) do
        %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

        changeset =
          %Payment{
            tenant_id: original.tenant_id,
            company_id: original.company_id,
            party_key: original.party_key,
            party_name: original.party_name,
            paid_from_account_id: original.paid_from_account_id,
            amount: original.amount,
            currency_code: original.currency_code,
            reference: original.reference,
            reverses_payment_id: original.id,
            posted_by_user_id: user_id,
            posted_by_impersonator_id: impersonator_id
          }
          |> Payment.changeset(Map.take(attributes, [:payment_date, "payment_date"]))
          |> Changeset.put_change(
            :description,
            attributes
            |> fetch(:description)
            |> default_text("Reversal of payment #{original.payment_number}")
          )
          |> Changeset.validate_length(:description, max: 500)
          |> Changeset.validate_change(:payment_date, fn :payment_date, date ->
            if Date.compare(date, original.payment_date) == :lt,
              do: [payment_date: "cannot be before the reversed payment's date"],
              else: []
          end)

        with {:ok, changeset} <- valid(changeset),
             {:ok, entry} <-
               Ledger.reverse_entry(scope, company_id, original.entry_id, %{
                 entry_date: Changeset.get_field(changeset, :payment_date),
                 description: Changeset.get_field(changeset, :description)
               }) do
          changeset
          |> Changeset.put_change(:entry_id, entry.id)
          |> Changeset.put_change(:entry_number, entry.entry_number)
          |> Changeset.put_assoc(:allocations, [])
          |> insert_payment(scope)
        end
      end
    end)
  end

  @doc """
  One payment with its allocations, and `reversed_by_payment_id` when a
  later payment reversed it.
  """
  @spec get_payment(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :payment_not_found}
  def get_payment(%Scope{} = scope, company_id, payment_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case payment_with_allocations(scope, company_id, payment_id) do
        nil -> {:error, :payment_not_found}
        payment -> {:ok, payment_view(payment, reversed_by(scope, company_id, [payment.id]))}
      end
    end
  end

  @doc """
  Payments with their allocations, ordered by payment date and then ID.
  Options: `party_key`; `document_id`, for the payments allocated to that
  document; and `from`, `to`, `limit`, and `after` (`{payment_date, id}`),
  as `list_documents/3` takes them.
  """
  @spec list_payments(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_payments(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, page} <- page_options(options),
         {:ok, party_key} <- party_option(options),
         {:ok, document_id} <- document_option(options) do
      payments =
        scope
        |> payments_query(company_id)
        |> then(&if(party_key, do: where(&1, [p], p.party_key == ^party_key), else: &1))
        |> allocated_to(scope, document_id)
        |> date_bound(:payment_date, page)
        |> after_cursor(:payment_date, page.after)
        |> order_by([p], asc: p.payment_date, asc: p.id)
        |> limit(^page.limit)
        |> preload(allocations: ^ordered(Allocation, scope))
        |> Repo.all()

      reversals = reversed_by(scope, company_id, Enum.map(payments, & &1.id))
      {:ok, Enum.map(payments, &payment_view(&1, reversals))}
    end
  end

  defp document_option(options) do
    case Keyword.get(options, :document_id) do
      nil -> {:ok, nil}
      id when is_integer(id) and id in 1..@max_bigint -> {:ok, id}
      _other -> {:error, :invalid_option}
    end
  end

  defp allocated_to(query, _scope, nil), do: query

  defp allocated_to(query, scope, document_id) do
    paid =
      from(a in Tenancy.scope_query(Allocation, scope),
        where: a.document_id == ^document_id,
        select: a.payment_id
      )

    where(query, [p], p.id in subquery(paid))
  end

  defp party_option(options) do
    case Keyword.get(options, :party_key) do
      nil -> {:ok, nil}
      key when is_binary(key) -> {:ok, key}
      _other -> {:error, :invalid_option}
    end
  end

  ## Aged payables

  @doc """
  What the company owes each party as of a date, by how long it is overdue.

  Every posted bill dated on or before `as_of` with something still owed
  counts, less its debit notes and the payments allocated to it that were
  dated on or before `as_of`; a payment reversed by then counts as unpaid.
  A bill owed less than nothing on that date is never dropped: it is listed
  in `exceptions` (with `outstanding` negative), outside the parties and
  buckets, and `exceptions_total` is their sum. `total + exceptions_total`
  is what the payable accounts hold for the bills as of the date. Posting
  checks keep this empty by refusing a debit note or payment that would
  leave a bill owed less than nothing, now or on its own date.
  Each party's rows list its bills with `days_overdue` (days past the due
  date) and `bucket`, the index of its column in `buckets`: column 0 is not
  yet due, column `i` is overdue up to `bucket_days[i - 1]` days, and the
  last is overdue longer. `bucket_days` is an option (default `[30, 60,
  90]`): strictly increasing positive integers.

  The result names `through_entry_number`, the last ledger entry number of a
  payables posting it counts. A document or payment posted later with an
  earlier date changes the figures for that date, so passing the same
  `as_of` and `through_entry_number: n` reproduces an earlier report's
  figures exactly: postings never change, and ledger entry numbers follow
  posting order. Party names are the latest bill's snapshot. A malformed
  option is `{:error, :invalid_option}`.
  """
  @spec aged_payables(Scope.t(), term(), Date.t(), keyword()) ::
          {:ok, map()} | {:error, refusal() | :invalid_option}
  def aged_payables(%Scope{} = scope, company_id, %Date{} = as_of, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, through} <- through_option(options),
         {:ok, bucket_days} <- bucket_option(options) do
      {:ok, Balances.aged_payables(scope, company_id, as_of, through, bucket_days)}
    end
  end

  defp through_option(options) do
    case Keyword.get(options, :through_entry_number) do
      nil -> {:ok, nil}
      number when is_integer(number) and number in 0..@max_bigint -> {:ok, number}
      _other -> {:error, :invalid_option}
    end
  end

  defp bucket_option(options) do
    days = Keyword.get(options, :bucket_days, [30, 60, 90])

    valid? =
      is_list(days) and days != [] and Enum.all?(days, &(is_integer(&1) and &1 > 0)) and
        Enum.sort(Enum.uniq(days)) == days

    if valid?, do: {:ok, days}, else: {:error, :invalid_option}
  end

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

  defp public_result({:ok, record}, view), do: {:ok, view.(record)}
  defp public_result(error, _view), do: error

  # A settings or tax code change is kept in the transaction that makes it; a
  # call that changes nothing keeps nothing.
  defp record_settings_change({:ok, settings} = saved, scope, previous, changeset, attributes) do
    if previous && changeset.changes == %{} do
      saved
    else
      %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

      %SettingsChange{
        tenant_id: settings.tenant_id,
        company_id: settings.company_id,
        old_payable_account_id: previous && previous.payable_account_id,
        new_payable_account_id: settings.payable_account_id,
        changed_by_user_id: user_id,
        changed_by_impersonator_id: impersonator_id
      }
      |> SettingsChange.changeset(Map.take(attributes, [:reason, "reason"]))
      |> Repo.insert()
      |> kept(saved)
    end
  end

  defp record_settings_change(error, _scope, _previous, _changeset, _attributes), do: error

  defp record_tax_code_change({:ok, tax_code} = saved, scope, previous, changed?, attributes) do
    if changed? do
      %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

      %TaxCodeChange{
        tenant_id: tax_code.tenant_id,
        company_id: tax_code.company_id,
        tax_code_id: tax_code.id,
        old_name: previous && previous.name,
        new_name: tax_code.name,
        old_rate: previous && previous.rate,
        new_rate: tax_code.rate,
        old_account_id: previous && previous.account_id,
        new_account_id: tax_code.account_id,
        old_active: previous && previous.active,
        new_active: tax_code.active,
        changed_by_user_id: user_id,
        changed_by_impersonator_id: impersonator_id
      }
      |> TaxCodeChange.changeset(Map.take(attributes, [:reason, "reason"]))
      |> Repo.insert()
      |> kept(saved)
    else
      saved
    end
  end

  defp record_tax_code_change(error, _scope, _previous, _changed?, _attributes), do: error

  defp kept({:ok, _change}, saved), do: saved
  defp kept({:error, _changeset} = error, _saved), do: error

  defp valid(%Changeset{valid?: true} = changeset), do: {:ok, changeset}
  defp valid(changeset), do: {:error, changeset}

  ## Ledger accounts

  defp ledger_accounts(scope, company_id) do
    with {:ok, accounts} <- Ledger.list_accounts(scope, company_id) do
      {:ok, Map.new(accounts, &{&1.id, &1})}
    end
  end

  # The field names an active account of the company, of one of `types`.
  defp check_account(changeset, field, accounts, types) do
    account_id = Changeset.get_field(changeset, field)

    case Map.get(accounts, account_id) do
      nil when is_integer(account_id) ->
        Changeset.add_error(changeset, field, "is not an account of this company")

      %{active: false} ->
        Changeset.add_error(changeset, field, "is inactive")

      %{account_type: type} when types != :any ->
        if type in types,
          do: changeset,
          else:
            Changeset.add_error(
              changeset,
              field,
              "must be an account of type #{Enum.join(types, " or ")}"
            )

      _account ->
        changeset
    end
  end

  defp payable_account(scope, company_id) do
    case settings(scope, company_id) do
      nil -> {:error, :payables_not_configured}
      settings -> {:ok, settings.payable_account_id}
    end
  end

  ## Documents

  defp document_changeset(scope, book, document_type, attributes, accounts) do
    %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)
    company_id = book.company_id
    tax_codes = scope |> tax_codes_query(company_id) |> Repo.all() |> Map.new(&{&1.id, &1})

    lines =
      attributes
      |> fetch(:lines)
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.map(fn {line, number} ->
        %DocumentLine{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          line_number: number
        }
        |> DocumentLine.changeset(if(is_map(line), do: line, else: %{}), book.minor_units)
        |> check_account(:account_id, accounts, @line_account_types)
        |> check_tax_code(tax_codes)
      end)

    %Document{
      tenant_id: Scope.tenant_id(scope),
      company_id: company_id,
      document_type: document_type,
      status: "draft",
      currency_code: book.currency_code,
      created_by_user_id: user_id,
      created_by_impersonator_id: impersonator_id
    }
    |> Document.changeset(Map.drop(attributes, [:lines, "lines", :tax_lines, "tax_lines"]))
    |> Changeset.put_assoc(:lines, lines)
    |> put_tax_lines(lines, fetch(attributes, :tax_lines), tax_codes, book.minor_units)
  end

  # The bill's party replaces any the caller sent, keyed as the caller keys.
  defp with_party(attributes, party) do
    string_keys? = Enum.any?(Map.keys(attributes), &is_binary/1)

    attributes
    |> Map.drop(@party_fields ++ Enum.map(@party_fields, &to_string/1))
    |> Map.merge(
      if string_keys?, do: Map.new(party, fn {k, v} -> {to_string(k), v} end), else: party
    )
  end

  defp check_tax_code(line, tax_codes) do
    case Changeset.get_field(line, :tax_code_id) do
      nil ->
        line

      tax_code_id ->
        case Map.get(tax_codes, tax_code_id) do
          nil -> Changeset.add_error(line, :tax_code_id, "is not a tax code of this company")
          %TaxCode{active: false} -> Changeset.add_error(line, :tax_code_id, "is inactive")
          %TaxCode{} -> line
        end
    end
  end

  # One tax line per tax code the lines use, in order of first use: the
  # lines' total for the code and its tax, at the code's rate or as stated.
  defp put_tax_lines(changeset, lines, stated, tax_codes, minor_units) do
    cond do
      lines == [] ->
        Changeset.add_error(changeset, :lines, "needs at least one line")

      not Enum.all?(lines, & &1.valid?) ->
        changeset

      true ->
        taxable =
          lines
          |> Enum.map(&{Changeset.get_field(&1, :tax_code_id), Changeset.get_field(&1, :amount)})
          |> Enum.reject(fn {tax_code_id, _amount} -> is_nil(tax_code_id) end)

        codes = taxable |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

        case stated_tax(stated, codes, minor_units) do
          {:ok, stated} ->
            tax_lines =
              codes
              |> Enum.with_index(1)
              |> Enum.map(fn {tax_code_id, number} ->
                tax_code = Map.fetch!(tax_codes, tax_code_id)

                base =
                  Enum.reduce(taxable, Decimal.new(0), fn
                    {^tax_code_id, amount}, total -> Decimal.add(amount, total)
                    _other, total -> total
                  end)

                %TaxLine{
                  tenant_id: Changeset.get_field(changeset, :tenant_id),
                  company_id: Changeset.get_field(changeset, :company_id),
                  line_number: number,
                  tax_code_id: tax_code_id,
                  tax_code: tax_code.code,
                  rate: tax_code.rate,
                  account_id: tax_code.account_id,
                  taxable_amount: base,
                  tax_amount:
                    Map.get_lazy(stated, tax_code_id, fn ->
                      base
                      |> Decimal.mult(tax_code.rate)
                      |> Decimal.div(100)
                      |> Amount.round(minor_units)
                    end)
                }
              end)

            net = Amount.sum(lines, :amount)
            tax = Amount.sum(tax_lines, :tax_amount)

            changeset
            |> Changeset.put_assoc(:tax_lines, tax_lines)
            |> Changeset.put_change(:total_net, net)
            |> Changeset.put_change(:total_tax, tax)
            |> Changeset.put_change(:total, Decimal.add(net, tax))

          {:error, message} ->
            Changeset.add_error(changeset, :tax_lines, message)
        end
    end
  end

  defp stated_tax(nil, _codes, _minor_units), do: {:ok, %{}}

  defp stated_tax(stated, codes, minor_units) when is_list(stated) do
    Enum.reduce_while(stated, {:ok, %{}}, fn item, {:ok, acc} ->
      changeset =
        {%{}, %{tax_code_id: :integer, tax_amount: :decimal}}
        |> Changeset.cast(if(is_map(item), do: item, else: %{}), [:tax_code_id, :tax_amount])
        |> Changeset.validate_required([:tax_code_id, :tax_amount])
        |> Amount.validate(:tax_amount, minor_units, :non_negative)

      tax_code_id = Changeset.get_field(changeset, :tax_code_id)

      cond do
        not changeset.valid? ->
          {:halt,
           {:error,
            "each needs a tax_code_id and a tax_amount of zero or more in the book's minor units"}}

        tax_code_id not in codes ->
          {:halt, {:error, "names a tax code no line uses"}}

        Map.has_key?(acc, tax_code_id) ->
          {:halt, {:error, "names a tax code twice"}}

        true ->
          {:cont, {:ok, Map.put(acc, tax_code_id, Changeset.get_field(changeset, :tax_amount))}}
      end
    end)
  end

  defp stated_tax(_stated, _codes, _minor_units), do: {:error, "must be a list"}

  # Read back what PostgreSQL stored, so the result equals `get_document/3`'s.
  defp insert_document(changeset, scope) do
    with {:ok, document} <- Repo.insert(changeset) do
      {:ok, document} = fetch_document(scope, document.company_id, document.id)
      {:ok, hd(document_views(scope, document.company_id, [document]))}
    end
  end

  defp update_document(changeset, scope) do
    with {:ok, document} <- Repo.update(changeset) do
      {:ok, document} = fetch_document(scope, document.company_id, document.id)
      {:ok, hd(document_views(scope, document.company_id, [document]))}
    end
  end

  defp require_status(%Document{status: status}, status, _refusal), do: :ok
  defp require_status(_document, _status, refusal), do: {:error, refusal}

  defp fetch_posted_bill(scope, company_id, bill_id) do
    case fetch_document(scope, company_id, bill_id) do
      {:ok, %Document{document_type: "bill", status: "posted"} = bill} -> {:ok, bill}
      {:ok, _document} -> {:error, :not_a_posted_bill}
      error -> error
    end
  end

  defp within_outstanding(scope, company_id, bill, changeset) do
    if changeset.valid? and
         exceeds?(
           scope,
           company_id,
           bill,
           Changeset.get_field(changeset, :total),
           Changeset.get_field(changeset, :document_date)
         ),
       do: {:error, :exceeds_outstanding},
       else: :ok
  end

  # A debit note posts against the account its bill posted to, and is checked
  # again when it posts: payments may have reduced what is owed on its bill
  # since it was recorded.
  defp posting_account(scope, company_id, %Document{
         document_type: "debit_note",
         corrects_document_id: bill_id,
         document_date: date,
         total: total
       }) do
    {:ok, bill} = fetch_document(scope, company_id, bill_id)

    if exceeds?(scope, company_id, bill, total, date),
      do: {:error, :exceeds_outstanding},
      else: {:ok, bill.payable_account_id}
  end

  defp posting_account(scope, company_id, _bill), do: payable_account(scope, company_id)

  # An amount taken off a bill must fit what is owed on it both now and on the
  # date of the debit note: a payment reversed after that date still counts
  # there, and one later reversed must not leave the bill owed less than nothing.
  defp exceeds?(scope, company_id, bill, total, date) do
    [
      Balances.outstanding(scope, company_id, [bill]),
      Balances.outstanding(scope, company_id, [bill], date)
    ]
    |> Enum.any?(&Decimal.lt?(Map.fetch!(&1, bill.id), total))
  end

  defp document_entry(document, payable_account_id) do
    {line_side, payable_side} =
      if document.document_type == "bill", do: {:debit, :credit}, else: {:credit, :debit}

    lines =
      Enum.map(document.lines, fn line ->
        %{
          :account_id => line.account_id,
          line_side => line.amount,
          :description => line.description
        }
      end)

    taxes =
      for tax_line <- document.tax_lines, Decimal.gt?(tax_line.tax_amount, 0) do
        %{
          :account_id => tax_line.account_id,
          line_side => tax_line.tax_amount,
          :description => "Tax #{tax_line.tax_code}"
        }
      end

    payable = %{
      :account_id => payable_account_id,
      payable_side => document.total,
      :description => document.party_name
    }

    %{
      entry_date: document.document_date,
      description: document_entry_description(document),
      reference:
        document.party_document_number && String.slice(document.party_document_number, 0, 100),
      lines: lines ++ taxes ++ [payable]
    }
  end

  defp document_entry_description(%Document{document_type: "bill"} = document),
    do: String.slice("Bill #{document.party_document_number} from #{document.party_name}", 0, 500)

  defp document_entry_description(%Document{} = document),
    do: String.slice("Debit note to #{document.party_name}", 0, 500)

  ## Payments

  defp payment_changeset(scope, company_id, book, attributes, accounts) do
    %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

    party_key =
      attributes |> fetch(:party_key) |> then(&if(is_binary(&1), do: String.trim(&1), else: &1))

    payment_date = attributes |> fetch(:payment_date) |> cast_date()

    allocations =
      attributes
      |> fetch(:allocations)
      |> List.wrap()
      |> Enum.with_index(1)
      |> Enum.map(fn {allocation, number} ->
        %Allocation{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          line_number: number
        }
        |> Allocation.changeset(
          if(is_map(allocation), do: allocation, else: %{}),
          book.minor_units
        )
      end)

    document_ids =
      allocations
      |> Enum.map(&Changeset.get_field(&1, :document_id))
      |> Enum.filter(&is_integer/1)

    bills =
      scope |> documents_query(company_id) |> where([d], d.id in ^document_ids) |> Repo.all()

    owed = Balances.outstanding(scope, company_id, bills)

    owed_on_date =
      if match?(%Date{}, payment_date),
        do: Balances.outstanding(scope, company_id, bills, payment_date),
        else: %{}

    bills = Map.new(bills, &{&1.id, &1})

    allocations =
      allocations
      |> Enum.map(&check_allocation(&1, bills, {owed, owed_on_date}, party_key, payment_date))
      |> mark_repeated_documents()

    party_name =
      allocations
      |> Enum.map(&Map.get(bills, Changeset.get_field(&1, :document_id)))
      |> Enum.reject(&is_nil/1)
      |> Enum.max_by(&{Date.to_gregorian_days(&1.document_date), &1.id}, fn -> nil end)
      |> case do
        nil -> nil
        bill -> bill.party_name
      end

    %Payment{
      tenant_id: Scope.tenant_id(scope),
      company_id: company_id,
      currency_code: book.currency_code,
      party_name: party_name,
      amount: Amount.sum(Enum.filter(allocations, & &1.valid?), :amount),
      posted_by_user_id: user_id,
      posted_by_impersonator_id: impersonator_id
    }
    |> Payment.changeset(
      Map.drop(attributes, [:allocations, "allocations", :party_name, "party_name"])
    )
    |> check_account(:paid_from_account_id, accounts, @paid_from_account_types)
    |> Changeset.put_assoc(:allocations, allocations)
    |> then(fn changeset ->
      if allocations == [],
        do: Changeset.add_error(changeset, :allocations, "needs at least one allocation"),
        else: changeset
    end)
    |> then(&{&1, bills})
  end

  defp cast_date(%Date{} = date), do: date

  defp cast_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp cast_date(_value), do: nil

  defp check_allocation(allocation, bills, {owed, owed_on_date}, party_key, payment_date) do
    document_id = Changeset.get_field(allocation, :document_id)
    amount = Changeset.get_field(allocation, :amount)

    case Map.get(bills, document_id) do
      nil when is_integer(document_id) ->
        Changeset.add_error(allocation, :document_id, "is not a document of this company")

      nil ->
        allocation

      %Document{document_type: type, status: status} when type != "bill" or status != "posted" ->
        Changeset.add_error(allocation, :document_id, "is not a posted bill")

      %Document{party_key: key} when key != party_key ->
        Changeset.add_error(allocation, :document_id, "is another party's bill")

      %Document{document_date: date} = bill ->
        cond do
          match?(%Date{}, payment_date) and Date.compare(payment_date, date) == :lt ->
            Changeset.add_error(allocation, :document_id, "is dated after the payment")

          allocation.valid? and Decimal.gt?(amount, Map.fetch!(owed, bill.id)) ->
            Changeset.add_error(allocation, :amount, "exceeds what is owed on the bill")

          allocation.valid? and Decimal.gt?(amount, Map.get(owed_on_date, bill.id, amount)) ->
            Changeset.add_error(
              allocation,
              :amount,
              "exceeds what is owed on the bill on the payment date"
            )

          true ->
            allocation
        end
    end
  end

  defp mark_repeated_documents(allocations) do
    {checked, _seen} =
      Enum.map_reduce(allocations, MapSet.new(), fn allocation, seen ->
        document_id = Changeset.get_field(allocation, :document_id)

        if is_integer(document_id) and MapSet.member?(seen, document_id),
          do: {Changeset.add_error(allocation, :document_id, "is allocated twice"), seen},
          else: {allocation, MapSet.put(seen, document_id)}
      end)

    checked
  end

  # One debit per payable account the paid bills posted to.
  defp payment_entry(changeset, bills) do
    allocations = Changeset.get_change(changeset, :allocations)
    party_name = Changeset.get_field(changeset, :party_name)

    payable =
      allocations
      |> Enum.group_by(
        &Map.fetch!(bills, Changeset.get_field(&1, :document_id)).payable_account_id,
        &Changeset.get_field(&1, :amount)
      )
      |> Enum.sort()
      |> Enum.map(fn {account_id, amounts} ->
        %{
          account_id: account_id,
          debit: Enum.reduce(amounts, &Decimal.add/2),
          description: party_name
        }
      end)

    %{
      entry_date: Changeset.get_field(changeset, :payment_date),
      description:
        changeset
        |> Changeset.get_field(:description)
        |> default_text(String.slice("Payment to #{party_name}", 0, 500)),
      reference: Changeset.get_field(changeset, :reference),
      lines:
        payable ++
          [
            %{
              account_id: Changeset.get_field(changeset, :paid_from_account_id),
              credit: Changeset.get_field(changeset, :amount),
              description: party_name
            }
          ]
    }
  end

  defp default_text(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      text -> text
    end
  end

  defp default_text(_value, default), do: default

  defp insert_payment(changeset, scope) do
    with {:ok, payment} <- Repo.insert(changeset) do
      payment = payment_with_allocations(scope, payment.company_id, payment.id)
      {:ok, payment_view(payment, %{})}
    end
  end

  defp reversible_payment(scope, company_id, payment_id) do
    case payment_with_allocations(scope, company_id, payment_id) do
      nil ->
        {:error, :payment_not_found}

      %Payment{reverses_payment_id: reversed} when not is_nil(reversed) ->
        {:error, :reversal_not_reversible}

      payment ->
        if reversed_by(scope, company_id, [payment.id]) == %{},
          do: {:ok, payment},
          else: {:error, :already_reversed}
    end
  end

  ## Queries

  defp settings(scope, company_id) when is_integer(company_id) do
    Repo.one(from(s in Tenancy.scope_query(Settings, scope), where: s.company_id == ^company_id))
  end

  defp tax_codes_query(scope, company_id) do
    from(t in Tenancy.scope_query(TaxCode, scope), where: t.company_id == ^company_id)
  end

  defp fetch_tax_code(scope, company_id, tax_code_id) when is_integer(tax_code_id) do
    case scope |> tax_codes_query(company_id) |> where([t], t.id == ^tax_code_id) |> Repo.one() do
      nil -> {:error, :tax_code_not_found}
      tax_code -> {:ok, tax_code}
    end
  end

  defp fetch_tax_code(_scope, _company_id, _tax_code_id), do: {:error, :tax_code_not_found}

  defp documents_query(scope, company_id) do
    from(d in Tenancy.scope_query(Document, scope), where: d.company_id == ^company_id)
  end

  defp document_preloads(scope),
    do: [lines: ordered(DocumentLine, scope), tax_lines: ordered(TaxLine, scope)]

  defp ordered(schema, scope),
    do: order_by(Tenancy.scope_query(schema, scope), [r], asc: r.line_number)

  defp fetch_document(scope, company_id, document_id) when is_integer(document_id) do
    scope
    |> documents_query(company_id)
    |> where([d], d.id == ^document_id)
    |> preload(^document_preloads(scope))
    |> Repo.one()
    |> case do
      nil -> {:error, :document_not_found}
      document -> {:ok, document}
    end
  end

  defp fetch_document(_scope, _company_id, _document_id), do: {:error, :document_not_found}

  defp payments_query(scope, company_id) do
    from(p in Tenancy.scope_query(Payment, scope), where: p.company_id == ^company_id)
  end

  defp payment_with_allocations(scope, company_id, payment_id) when is_integer(payment_id) do
    scope
    |> payments_query(company_id)
    |> where([p], p.id == ^payment_id)
    |> preload(allocations: ^ordered(Allocation, scope))
    |> Repo.one()
  end

  defp payment_with_allocations(_scope, _company_id, _payment_id), do: nil

  defp reversed_by(_scope, _company_id, []), do: %{}

  defp reversed_by(scope, company_id, payment_ids) do
    scope
    |> payments_query(company_id)
    |> where([p], p.reverses_payment_id in ^payment_ids)
    |> select([p], {p.reverses_payment_id, p.id})
    |> Repo.all()
    |> Map.new()
  end

  defp page_options(options) do
    limit = Keyword.get(options, :limit, @default_limit)
    from = Keyword.get(options, :from)
    to = Keyword.get(options, :to)
    cursor = Keyword.get(options, :after)

    if is_integer(limit) and limit in 1..@max_limit and optional_date?(from) and
         optional_date?(to) and valid_cursor?(cursor),
       do: {:ok, %{limit: limit, from: from, to: to, after: cursor}},
       else: {:error, :invalid_option}
  end

  defp optional_date?(value), do: is_nil(value) or match?(%Date{}, value)

  defp valid_cursor?(nil), do: true
  defp valid_cursor?({%Date{}, id}), do: is_integer(id) and id in 1..@max_bigint
  defp valid_cursor?(_cursor), do: false

  defp date_bound(query, field, %{from: from, to: to}) do
    query
    |> then(&if(from, do: where(&1, [r], field(r, ^field) >= ^from), else: &1))
    |> then(&if(to, do: where(&1, [r], field(r, ^field) <= ^to), else: &1))
  end

  defp after_cursor(query, _field, nil), do: query

  defp after_cursor(query, field, {date, id}) do
    where(
      query,
      [r],
      field(r, ^field) > ^date or (field(r, ^field) == ^date and r.id > ^id)
    )
  end

  defp fetch(attributes, key), do: Map.get(attributes, key, Map.get(attributes, to_string(key)))

  ## Views

  defp settings_view(settings), do: Map.take(settings, [:company_id, :payable_account_id])

  defp tax_code_view(tax_code),
    do: Map.take(tax_code, [:id, :code, :name, :rate, :account_id, :active])

  # A posted bill's outstanding, and every document's debit notes, so the
  # trail runs from a bill to its corrections as well as back.
  defp document_views(scope, company_id, documents) do
    outstanding = Balances.outstanding(scope, company_id, documents)
    ids = Enum.map(documents, & &1.id)

    debit_notes =
      scope
      |> documents_query(company_id)
      |> where([d], d.corrects_document_id in ^ids)
      |> order_by([d], asc: d.id)
      |> select([d], {d.corrects_document_id, d.id})
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Enum.map(documents, fn document ->
      document
      |> document_view(outstanding)
      |> Map.put(:debit_note_ids, Map.get(debit_notes, document.id, []))
    end)
  end

  defp document_view(document, outstanding) do
    document
    |> Map.take([
      :id,
      :document_type,
      :status,
      :document_number,
      :corrects_document_id,
      :party_key,
      :party_name,
      :party_tax_id,
      :party_registration_id,
      :party_address,
      :party_document_number,
      :document_date,
      :due_date,
      :currency_code,
      :description,
      :total_net,
      :total_tax,
      :total,
      :created_by_user_id,
      :created_by_impersonator_id,
      :created_at,
      :approved_by_user_id,
      :approved_by_impersonator_id,
      :approved_at,
      :posted_by_user_id,
      :posted_by_impersonator_id,
      :posted_at,
      :payable_account_id,
      :entry_id,
      :entry_number,
      :voided_by_user_id,
      :voided_by_impersonator_id,
      :voided_at,
      :void_reason
    ])
    |> Map.put(:outstanding, Map.get(outstanding, document.id))
    |> Map.put(
      :lines,
      Enum.map(
        document.lines,
        &Map.take(&1, [
          :line_number,
          :description,
          :account_id,
          :amount,
          :tax_code_id,
          :external_order_line_id
        ])
      )
    )
    |> Map.put(
      :tax_lines,
      Enum.map(
        document.tax_lines,
        &Map.take(&1, [
          :line_number,
          :tax_code_id,
          :tax_code,
          :rate,
          :account_id,
          :taxable_amount,
          :tax_amount
        ])
      )
    )
  end

  defp payment_view(payment, reversals) do
    payment
    |> Map.take([
      :id,
      :payment_number,
      :payment_date,
      :party_key,
      :party_name,
      :paid_from_account_id,
      :amount,
      :currency_code,
      :reference,
      :description,
      :reverses_payment_id,
      :entry_id,
      :entry_number,
      :posted_by_user_id,
      :posted_by_impersonator_id,
      :posted_at
    ])
    |> Map.put(:reversed_by_payment_id, Map.get(reversals, payment.id))
    |> Map.put(
      :allocations,
      Enum.map(payment.allocations, &Map.take(&1, [:line_number, :document_id, :amount]))
    )
  end
end
