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
  is submitted with its allocations to bills, posted when someone approves
  it, and corrected by its reversal.
  Nothing is deleted; the database refuses the same things on its own (see
  the migration). A change to the payable account, the match tolerances, or
  a tax code is recorded with who made it, why, and the values before and
  after, and never altered (`list_settings_changes/2`,
  `list_tax_code_changes/2`).

  A bill line may name a purchase order line of the installed order source
  (`Bilimbi.Finance.Payables.OrderSource`; Supply Chain purchasing and
  receiving when mounted) with the quantity billed against it. Posting such a
  bill is a three-way match: the billed quantity and unit price are compared
  with what was ordered and with what was received and not yet billed,
  within the company's tolerances. A bill within tolerance posts as any
  other; one outside is `held` instead, with the exceptions recorded, and
  posts only after a user holding `finance.payables.match.approve` approves
  them with a reason (`approve_match_exception/4`). Every attempt is an
  append-only match event with the figures it compared. A bill naming no
  order line is never matched, and when no order source is installed a line
  cannot name one.

  Approving a document, approving a held bill's match exceptions, and
  approving a payment ask the ledger's separation of duties
  (`Bilimbi.Finance.Ledger.check_approval/3`): while the company requires
  it, the approver is not the person who recorded the document or
  submitted the payment (nor whoever impersonated them), and an exception
  approver is also not whoever tried to post the held bill, else
  `{:error, :same_person}`; while it does not, the approval is allowed and
  listed in the ledger's approval exceptions. An approved match exception is
  always listed there as an override. Each asks `finance.ledger.view`.

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
  alias Bilimbi.Finance.Payables.MatchEvent
  alias Bilimbi.Finance.Payables.MatchException
  alias Bilimbi.Finance.Payables.MatchLine
  alias Bilimbi.Finance.Payables.Matching
  alias Bilimbi.Finance.Payables.OrderSource
  alias Bilimbi.Finance.Payables.Ownership
  alias Bilimbi.Finance.Payables.Payment
  alias Bilimbi.Finance.Payables.PaymentRequest
  alias Bilimbi.Finance.Payables.PaymentRequestAllocation
  alias Bilimbi.Finance.Payables.PaymentRequestEvent
  alias Bilimbi.Finance.Payables.Settings
  alias Bilimbi.Finance.Payables.SettingsChange
  alias Bilimbi.Finance.Payables.TaxCode
  alias Bilimbi.Finance.Payables.TaxCodeChange
  alias Bilimbi.Finance.Payables.TaxLine
  alias Bilimbi.Finance.Payables.TaxReport
  alias Bilimbi.Finance.Payables.TieOut
  alias Ecto.Changeset

  @view "finance.payables.view"
  @manage_settings "finance.payables.settings.manage"
  @create_documents "finance.payables.documents.create"
  @approve_documents "finance.payables.documents.approve"
  @post_documents "finance.payables.documents.post"
  @submit_payments "finance.payables.payments.submit"
  @post_payments "finance.payables.payments.post"
  @approve_match_exceptions "finance.payables.match.approve"

  @match_statuses ~w(pending held exception_approved matched posted_with_exceptions)
  @page_sizes [25, 50, 100]

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

  @doc "The capability that submits a payment for approval."
  def submit_payments_capability, do: @submit_payments

  @doc "The capability that approves (posting it) or rejects a payment, and reverses payments."
  def post_payments_capability, do: @post_payments

  @doc "The capability that approves a held bill's match exceptions."
  def approve_match_exceptions_capability, do: @approve_match_exceptions

  @doc "The document types: a party's bill, and our debit note against one."
  @spec document_types() :: [String.t()]
  def document_types, do: Document.types()

  @doc "The statuses a document moves through."
  @spec document_statuses() :: [String.t()]
  def document_statuses, do: Document.statuses()

  @doc """
  The match statuses a bill naming order lines shows as `match_status`:
  `pending` until it is first posted, `held` with unapproved exceptions,
  `exception_approved` once they are approved and it awaits posting,
  `matched` when it posted within tolerance, and `posted_with_exceptions`
  when it posted on approved exceptions. A bill naming no order line, or a
  debit note, shows `nil`.
  """
  @spec match_statuses() :: [String.t()]
  def match_statuses, do: @match_statuses

  @doc "The codes a match exception carries; see `approve_match_exception/4`."
  @spec match_exception_codes() :: [String.t()]
  def match_exception_codes, do: Matching.exception_codes()

  @doc "The page sizes `page_documents/3` accepts."
  def page_sizes, do: @page_sizes

  @doc "Evidence datasets available to the company-authorized auditor export."
  def evidence_datasets, do: Bilimbi.Finance.Payables.Evidence.datasets()

  @doc """
  One ID-ordered evidence page with explicit fields, rows and next cursor.
  Requires this module's view grant. Consume all pages in one repeatable-read
  transaction for a consistent export; individual pages are live reads.
  """
  def evidence_page(%Scope{} = scope, company_id, dataset, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view) do
      Bilimbi.Finance.Payables.Evidence.page(scope, company_id, dataset, options)
    end
  end

  ## Settings

  @doc """
  The company's payables settings: `company_id`, `payable_account_id`, and
  the match tolerances `quantity_tolerance_kind`, `quantity_tolerance`,
  `price_tolerance_kind`, and `price_tolerance` (nil until set: an exact
  match), or `{:error, :payables_not_configured}` before `put_settings/3`.
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
  credits, and the three-way match tolerances: `quantity_tolerance_kind`
  and `price_tolerance_kind`, each `percent` (of the ordered quantity or
  unit price) or `amount` (units of quantity, or currency per unit), with
  `quantity_tolerance` and `price_tolerance` (zero or more, up to four
  decimal places); a kind and its value come together, and nil means an
  exact match. A change applies to documents posted afterwards; each posted
  document keeps the account it posted to, and each match record the
  tolerances it was checked against. An optional `reason` is kept with the
  change in `list_settings_changes/2`.
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
  The changes made to the settings, oldest first: the `old_` and `new_`
  values of the payable account and of each tolerance kind and value (the
  `old_` ones nil the first time), the optional `reason`, who made it
  (`changed_by_user_id`, `changed_by_impersonator_id`), and `changed_at`,
  the database's time.
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
       |> Enum.map(&Map.take(&1, SettingsChange.fields()))}
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

  A line may name a purchase order line of the installed order source with
  `order_line_id` and the `quantity` billed against it (positive, up to four
  decimal places); the two come together. The line must exist in the
  source, read with this scope, so the actor also holds the source's view
  capabilities; with no source installed a line cannot name one. The match
  itself runs when the bill posts (`post_document/3`). A refusal from the
  source other than a missing line is `{:error, {:order_source, reason}}`.
  """
  @spec create_bill(Scope.t(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :book_not_open | {:order_source, term()} | Changeset.t()}
  def create_bill(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @create_documents, fn ->
      with {:ok, book} <- Ledger.get_book(scope, company_id),
           {:ok, accounts} <- ledger_accounts(scope, company_id),
           {:ok, changeset} <-
             scope
             |> document_changeset(book, "bill", attributes, accounts)
             |> check_order_lines(scope, company_id) do
        insert_document(changeset, scope)
      end
    end)
  end

  @doc """
  Records a debit note against a posted bill as a draft: what the party
  credits back, taken off what the company owes on that bill. Attributes
  are `create_bill/3`'s without the party, which is copied from the bill;
  `party_document_number` is optional. Its date is not before the bill's,
  and its total cannot exceed the least that is owed on the bill on any date
  from the debit note's date on, counting each later payment, reversal, and
  debit note date and now (`{:error, :exceeds_outstanding}`, checked again
  when it posts).

  A debit note line may name an order line the bill's lines name, with the
  `quantity` the party credits back, which is taken off what this module
  counts as billed against that order line once the note posts. With the
  bill's earlier posted debit notes, that quantity fits what the bill billed
  on the line (checked again when it posts: `{:error,
  :exceeds_billed_quantity}`).
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
          |> check_note_order_lines(scope, company_id, bill)

        with :ok <- within_outstanding(scope, company_id, bill, changeset) do
          insert_document(changeset, scope)
        end
      end
    end)
  end

  @doc """
  Approves a draft document. Anything else is `{:error, :not_draft}`. The
  approver differs from whoever recorded it (`{:error, :same_person}`)
  unless the company has turned separation of duties off, when the approval
  is listed in the ledger's approval exceptions.
  """
  @spec approve_document(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error, write_refusal() | :document_not_found | :not_draft | :same_person}
  def approve_document(%Scope{} = scope, company_id, document_id) do
    write(scope, company_id, @approve_documents, fn ->
      with {:ok, document} <- fetch_document(scope, company_id, document_id),
           :ok <- require_status(document, "draft", :not_draft),
           :ok <-
             Ledger.check_approval(scope, company_id, %{
               source: "finance/payables",
               action: "document_approval",
               subject_type: document.document_type,
               subject_id: document.id,
               subject: document_label(document),
               prepared_by: [document_creator(document)]
             }) do
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
  Voids a draft, approved, or held document with a `void_reason`; it stays
  on record and frees its party document number. A posted or voided
  document is `{:error, :not_voidable}`: correct a posted bill with a debit
  note.
  """
  @spec void_document(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :document_not_found | :not_voidable | Changeset.t()}
  def void_document(%Scope{} = scope, company_id, document_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @approve_documents, fn ->
      with {:ok, document} <- fetch_document(scope, company_id, document_id) do
        if document.status in ["draft", "approved", "held"] do
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
  Posts an approved or held document to the ledger on its document date and
  numbers it. A bill debits each line's account and each tax line's account
  and credits the payable account from the settings with its total; a debit
  note posts the opposite. Anything but an approved or held document is
  `{:error, :not_approved}`; `{:error, :payables_not_configured}` before
  `put_settings/3`. A refusal from the ledger, such as an account deactivated
  since the document was recorded, is the ledger's changeset.

  A bill whose lines name order lines is matched first (the three-way match
  in the moduledoc), with the source read under this scope, so the actor
  also holds the source's view capabilities; the source refusing is
  `{:error, {:order_source, reason}}`. Every line within tolerance, or every
  exception found covered by an approval (`approve_match_exception/4`) of
  the bill's last hold, with figures no worse than that hold recorded, posts the bill and records a `posted` match event
  with the figures compared. Otherwise the bill is not posted: it becomes
  (or stays) `held`, a `held` event records each line's figures and
  exceptions, and the result is `{:ok, document}` with `status` `held` and
  `match_status` `held`, for the caller to read. Posting a held bill matches
  it afresh, so goods received since may clear a hold on their own.

  A debit note naming order lines is checked against its bill's billed
  quantities again (`{:error, :exceeds_billed_quantity}`).
  """
  @spec post_document(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :document_not_found
             | :not_approved
             | :payables_not_configured
             | :exceeds_outstanding
             | :exceeds_billed_quantity
             | {:order_source, term()}
             | Changeset.t()}
  def post_document(%Scope{} = scope, company_id, document_id) do
    write(scope, company_id, @post_documents, fn ->
      with {:ok, document} <- fetch_document(scope, company_id, document_id),
           :ok <- require_postable(document),
           {:ok, match} <- match_for_posting(scope, company_id, document) do
        case match do
          {:hold, lines} -> hold_document(scope, document, lines)
          {:post, lines} -> post_now(scope, company_id, document, lines)
        end
      end
    end)
  end

  defp require_postable(%Document{status: status}) when status in ["approved", "held"], do: :ok
  defp require_postable(_document), do: {:error, :not_approved}

  # A bill naming order lines is matched; the decision is to post or to hold.
  defp match_for_posting(scope, company_id, %Document{document_type: "bill"} = document) do
    if Enum.any?(document.lines, & &1.order_line_id) do
      with {:ok, settings} <- fetch_settings(scope, company_id),
           {:ok, book} <- Ledger.get_book(scope, company_id),
           {:ok, lines} <- Matching.evaluate(scope, company_id, document, settings, book) do
        cond do
          Enum.all?(lines, &(&1.exceptions == [])) ->
            {:ok, {:post, lines}}

          Matching.covered?(approved_lines(scope, company_id, document), lines) ->
            {:ok, {:post, lines}}

          true ->
            {:ok, {:hold, lines}}
        end
      end
    else
      {:ok, {:post, nil}}
    end
  end

  defp match_for_posting(_scope, _company_id, _debit_note), do: {:ok, {:post, nil}}

  # The lines of the hold the bill's latest approval covers, with the figures
  # the approver saw, or none when the latest event is not an approval.
  defp approved_lines(scope, company_id, document) do
    events = scope |> match_events(company_id, [document.id]) |> Map.get(document.id, [])

    case Enum.reverse(events) do
      [%MatchEvent{event: "exception_approved"}, %MatchEvent{event: "held"} = held | _earlier] ->
        held.lines

      _other ->
        []
    end
  end

  defp hold_document(scope, document, lines) do
    with {:ok, _event} <- record_match_event(scope, document, "held", lines, %{}) do
      if document.status == "held" do
        {:ok, document} = fetch_document(scope, document.company_id, document.id)
        {:ok, hd(document_views(scope, document.company_id, [document]))}
      else
        document
        |> Changeset.change(status: "held")
        |> update_document(scope)
      end
    end
  end

  # The entry names this document as its owner: the ledger refuses a second
  # entry for it and a reversal from anywhere but this module.
  defp post_now(scope, company_id, document, lines) do
    with {:ok, payable_account_id} <- posting_account(scope, company_id, document),
         {:ok, entry} <-
           Ledger.post_entry(scope, company_id, document_entry(document, payable_account_id),
             owner: Ownership.owner(:document, document.id)
           ),
         {:ok, _event} <- record_posting_match(scope, document, lines) do
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
  end

  defp record_posting_match(_scope, _document, nil), do: {:ok, nil}

  defp record_posting_match(scope, document, lines),
    do: record_match_event(scope, document, "posted", lines, %{})

  @doc """
  Approves a held bill's match exceptions with a `reason` and the
  `held_event_id` of the hold the approver saw (both required; the hold's
  `id` in `match_events`): the exceptions that hold recorded may then be
  posted over. A hold recorded since is `{:error, :stale_hold}`. The bill
  stays held until `post_document/3` posts it, matching afresh; an exception the
  approval does not cover, or one whose figures are worse than the hold the
  approver saw (more billed over the order, less received, a wider price
  gap), holds it again, for a new approval. Anything but a held bill is
  `{:error, :not_held}`; one whose last hold is already approved is
  `{:error, :already_approved}`. The approval is a match event
  naming the approver, with any impersonator, the hold, and the database's
  time, and it is listed in the ledger's approval exceptions as an override.
  The approver differs from whoever recorded the bill and whoever tried to
  post it into the hold (`{:error, :same_person}`) unless the company has
  turned separation of duties off.
  """
  @spec approve_match_exception(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :document_not_found
             | :not_held
             | :already_approved
             | :stale_hold
             | :same_person
             | Changeset.t()}
  def approve_match_exception(%Scope{} = scope, company_id, document_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @approve_match_exceptions, fn ->
      with {:ok, document} <- fetch_document(scope, company_id, document_id),
           :ok <- require_status(document, "held", :not_held),
           {:ok, held} <- latest_hold(scope, company_id, document),
           :ok <- require_seen_hold(held, attributes),
           {:ok, _event} <-
             record_match_event(
               scope,
               document,
               "exception_approved",
               [],
               Map.take(attributes, [:reason, "reason", :held_event_id, "held_event_id"])
             ),
           :ok <-
             Ledger.check_approval(scope, company_id, %{
               source: "finance/payables",
               action: "match_override",
               subject_type: "bill",
               subject_id: document.id,
               subject: document_label(document),
               prepared_by: [
                 document_creator(document),
                 %{user_id: held.actor_user_id, impersonator_id: held.actor_impersonator_id}
               ],
               override: true,
               reason: fetch(attributes, :reason)
             }) do
        {:ok, hd(document_views(scope, company_id, [document]))}
      end
    end)
  end

  defp document_creator(document),
    do: %{
      user_id: document.created_by_user_id,
      impersonator_id: document.created_by_impersonator_id
    }

  # What a reviewer of the approval exceptions reads; a draft has no number.
  defp document_label(%Document{document_type: "bill"} = document),
    do:
      "Bill #{document.party_document_number} from #{document.party_name}, " <>
        "#{amount_label(document.total)} #{document.currency_code}"

  defp document_label(document),
    do:
      "Debit note to #{document.party_name}, " <>
        "#{amount_label(document.total)} #{document.currency_code}"

  defp amount_label(amount), do: amount |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp latest_hold(scope, company_id, document) do
    events = scope |> match_events(company_id, [document.id]) |> Map.get(document.id, [])

    case List.last(events) do
      %MatchEvent{event: "held"} = held -> {:ok, held}
      _other -> {:error, :already_approved}
    end
  end

  # A missing or malformed id is left to the event's changeset to refuse.
  defp require_seen_hold(held, attributes) do
    seen = Map.get(attributes, :held_event_id, Map.get(attributes, "held_event_id"))

    case Ecto.Type.cast(:integer, seen) do
      {:ok, id} when is_integer(id) and id != held.id -> {:error, :stale_hold}
      _seen -> :ok
    end
  end

  # One match event with its lines and their exceptions, in the transaction
  # that decides it; the database stamps the time and checks the status.
  defp record_match_event(scope, document, event, lines, attributes) do
    %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)
    owner = %{tenant_id: document.tenant_id, company_id: document.company_id}

    match_lines =
      Enum.map(lines, fn line ->
        exceptions =
          Enum.map(line.exceptions, fn exception ->
            struct(MatchException, Map.merge(owner, Map.take(exception, [:code, :detail])))
          end)

        struct(
          MatchLine,
          owner
          |> Map.merge(Map.take(line, MatchLine.fields()))
          |> Map.merge(%{document_id: document.id, exceptions: exceptions})
        )
      end)

    match_event =
      struct(
        MatchEvent,
        Map.merge(owner, %{
          document_id: document.id,
          event: event,
          actor_user_id: user_id,
          actor_impersonator_id: impersonator_id
        })
      )

    match_event
    |> MatchEvent.changeset(attributes)
    |> Changeset.put_assoc(:lines, match_lines)
    |> Repo.insert()
  end

  @doc """
  One document with its lines and tax lines, and `debit_note_ids`, the
  debit notes recorded against it. A posted bill also shows `outstanding`,
  what is still owed on it now; `list_payments/3` with `document_id` lists
  the payments allocated to it. A bill naming order lines shows
  `match_status` (`match_statuses/0`) and `match_events`, oldest first,
  each with its `event`, `reason`, actor, `occurred_at`, and `lines`: the
  figures compared for each bill line and the `exceptions` found
  (`%{code, detail}`); other documents show `nil` and `[]`.
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
  A page of documents for a list, newest first: `page` (from 1) and
  `page_size` (one of `page_sizes/0`), with optional `document_type`,
  `status`, and `search`, which matches the party's name or the party's
  document number. The result is `%{entries, page, page_size, total_entries,
  total_pages, has_prev?, has_next?}`, each entry as `get_document/3`
  shows it; a page past the end is the last page. A malformed option is
  `{:error, :invalid_option}`.
  """
  @spec page_documents(Scope.t(), term(), keyword()) ::
          {:ok, map()} | {:error, refusal() | :invalid_option}
  def page_documents(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    page = Keyword.get(options, :page, 1)
    page_size = Keyword.get(options, :page_size, hd(@page_sizes))
    search = Keyword.get(options, :search)

    with :ok <- authorize(scope, company_id, @view),
         {:ok, filters} <- document_filters(Keyword.take(options, [:document_type, :status])),
         true <-
           (is_integer(page) and page > 0 and page_size in @page_sizes and
              (is_nil(search) or is_binary(search))) || {:error, :invalid_option} do
      query =
        scope
        |> documents_query(company_id)
        |> where(^filters)
        |> search_documents(search)

      total = Repo.aggregate(query, :count)
      total_pages = ceil(total / page_size)
      page = if total_pages == 0, do: 1, else: min(page, total_pages)

      documents =
        query
        |> order_by([d], desc: d.document_date, desc: d.id)
        |> offset(^((page - 1) * page_size))
        |> limit(^page_size)
        |> preload(^document_preloads(scope))
        |> Repo.all()

      {:ok,
       %{
         entries: document_views(scope, company_id, documents),
         page: page,
         page_size: page_size,
         total_entries: total,
         total_pages: total_pages,
         has_prev?: total_pages > 0 and page > 1,
         has_next?: total_pages > 0 and page < total_pages
       }}
    end
  end

  defp search_documents(query, search) when is_binary(search) and search != "" do
    pattern = "%" <> escape_like(search) <> "%"

    where(
      query,
      [d],
      ilike(d.party_name, ^pattern) or ilike(d.party_document_number, ^pattern)
    )
  end

  defp search_documents(query, _search), do: query

  defp escape_like(text), do: Regex.replace(~r/[\\%_]/, text, &("\\" <> &1))

  @doc """
  The quantity billed against each of the order lines, by ID: the
  quantities of posted bill lines naming it, less those of posted debit
  note lines, in the company. An order line nothing posted names is absent.
  This is this module's own record of billed quantities, the figure the
  match takes off what was received.
  """
  @spec billed_quantities(Scope.t(), term(), [term()]) ::
          {:ok, %{optional(integer()) => Decimal.t()}} | {:error, refusal() | :invalid_option}
  def billed_quantities(%Scope{} = scope, company_id, order_line_ids)
      when is_list(order_line_ids) do
    with :ok <- authorize(scope, company_id, @view),
         true <-
           Enum.all?(order_line_ids, &(is_integer(&1) and &1 in 1..@max_bigint)) ||
             {:error, :invalid_option} do
      {:ok, Matching.billed_quantities(scope, company_id, order_line_ids, nil)}
    end
  end

  @doc """
  The tax on posted documents, summed by PostgreSQL per `document_type`,
  tax code, rate, and tax account: `%{document_type, tax_code_id,
  tax_code, rate, account_id, document_count, taxable_amount,
  tax_amount}`, each amount as the document carries it (a debit note's
  positive). Options: `from` and `to`, document dates (inclusive), and
  `through_entry_number`, which counts only documents whose ledger entry
  is numbered up to it, so a reading pinned to a ledger entry number
  reproduces exactly. A module reporting tax to an authority reads it; a
  malformed option is `{:error, :invalid_option}`.
  """
  @spec tax_totals(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def tax_totals(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         do: TaxReport.totals(scope, company_id, options)
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
  Submits a payment to one party for approval: `payment_date`,
  `party_key`, `paid_from_account_id` (an active asset or liability
  account, such as a bank account), optional `reference` and
  `description`, and `allocations`, each `%{document_id, amount}` naming a
  posted bill of that party dated on or before the payment. The payment's
  amount is the allocations' total; an allocation cannot exceed what is
  still owed on its bill, so a bill may be paid in parts. An allocation
  fits the least that is owed on its bill on any date from `payment_date`
  on (see `create_debit_note/4`), so a payment dated before a payment that
  is later reversed cannot leave the bill owed less than nothing.

  The request is kept, numbered per company, with the submitter and the
  database's time; nothing posts until `approve_payment/3`.
  """
  @spec submit_payment(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :book_not_open | Changeset.t()}
  def submit_payment(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @submit_payments, fn ->
      with {:ok, book} <- Ledger.get_book(scope, company_id),
           {:ok, accounts} <- ledger_accounts(scope, company_id) do
        {changeset, _bills} = payment_changeset(scope, company_id, book, attributes, accounts)

        with {:ok, changeset} <- valid(changeset),
             {:ok, request} <- changeset |> payment_request(scope) |> Repo.insert() do
          {:ok, payment_request_view(fetch_payment_request(scope, company_id, request.id))}
        end
      end
    end)
  end

  @doc """
  Approves a submitted payment request, which posts the payment: every
  check `submit_payment/3` made is made again now, so a bill paid or
  corrected since is the payment changeset's error and the request stays
  submitted. The ledger entry debits each bill's payable account and
  credits the paid-from account; the payment is posted by the approver, and
  the request records the `posted` event naming it. The result is the
  payment, as `get_payment/3` shows it.

  The approver differs from the submitter (`{:error, :same_person}`) unless
  the company has turned separation of duties off, when the approval is
  listed in the ledger's approval exceptions. Anything but a submitted
  request is `{:error, :payment_request_decided}`.
  """
  @spec approve_payment(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :book_not_open
             | :payment_request_not_found
             | :payment_request_decided
             | :same_person
             | Changeset.t()}
  def approve_payment(%Scope{} = scope, company_id, request_id) do
    write(scope, company_id, @post_payments, fn ->
      with {:ok, request} <- submitted_payment_request(scope, company_id, request_id),
           :ok <- Ledger.check_approval(scope, company_id, payment_approval(request)),
           {:ok, book} <- Ledger.get_book(scope, company_id),
           {:ok, accounts} <- ledger_accounts(scope, company_id) do
        {changeset, bills} =
          payment_changeset(scope, company_id, book, requested_payment(request), accounts)

        with {:ok, changeset} <- valid(changeset),
             # The payment takes its ID now: the entry names it as its owner, and
             # the payment names the entry, in one transaction.
             {:ok, entry} <-
               Ledger.post_entry(scope, company_id, payment_entry(changeset, bills),
                 owner: Ownership.owner(:payment, changeset.data.id)
               ),
             {:ok, payment} <-
               changeset
               |> Changeset.put_change(:entry_id, entry.id)
               |> Changeset.put_change(:entry_number, entry.entry_number)
               |> insert_payment(scope),
             {:ok, _event} <- decide_payment_request(scope, request, "posted", %{}, payment.id) do
          {:ok, payment}
        end
      end
    end)
  end

  @doc """
  Rejects a submitted payment request with a `reason`; it never posts.
  Anything but a submitted request is `{:error, :payment_request_decided}`.
  """
  @spec reject_payment(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :payment_request_not_found
             | :payment_request_decided
             | Changeset.t()}
  def reject_payment(%Scope{} = scope, company_id, request_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @post_payments, fn ->
      with {:ok, request} <- submitted_payment_request(scope, company_id, request_id),
           {:ok, _event} <-
             decide_payment_request(scope, request, "rejected", attributes, nil) do
        {:ok, payment_request_view(fetch_payment_request(scope, company_id, request.id))}
      end
    end)
  end

  @doc """
  One payment request with its allocations, `status` (`submitted`,
  `posted`, or `rejected`), and `decision`: who posted or rejected it,
  when, any `reason`, and the `payment_id` an approval posted.
  """
  @spec get_payment_request(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :payment_request_not_found}
  def get_payment_request(%Scope{} = scope, company_id, request_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case fetch_payment_request(scope, company_id, request_id) do
        nil -> {:error, :payment_request_not_found}
        request -> {:ok, payment_request_view(request)}
      end
    end
  end

  @doc """
  The company's payment requests by number, as `get_payment_request/3`
  shows them. Options: `status` (one of `payment_request_statuses/0`),
  `limit` (default 100, at most 500), and `after`, the last
  `request_number` of the previous page.
  """
  @spec list_payment_requests(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_payment_requests(%Scope{} = scope, company_id, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, filters} <- request_options(options) do
      {:ok,
       scope
       |> payment_requests_query(company_id)
       |> request_status(scope, filters.status)
       |> then(fn query ->
         if filters.after,
           do: where(query, [r], r.request_number > ^filters.after),
           else: query
       end)
       |> order_by([r], asc: r.request_number)
       |> limit(^filters.limit)
       |> preload_payment_request(scope)
       |> Repo.all()
       |> Enum.map(&payment_request_view/1)}
    end
  end

  @doc "The statuses a payment request moves through."
  def payment_request_statuses, do: PaymentRequest.statuses()

  @doc """
  Posts the reversal of a payment on `payment_date` (not before the
  original's) with an optional `description`: the ledger reverses its entry
  through the owner's path (`Ledger.reverse_owned_entry/5`, as this module
  for that payment), and its bills are owed again from that date, both in
  one transaction. A payment is reversed at most once
  (`{:error, :already_reversed}`), and a reversal is not itself reversed
  (`{:error, :reversal_not_reversible}`).
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
               Ledger.reverse_owned_entry(
                 scope,
                 company_id,
                 original.entry_id,
                 Ownership.owner(:payment, original.id),
                 %{
                   entry_date: Changeset.get_field(changeset, :payment_date),
                   description: Changeset.get_field(changeset, :description)
                 }
               ) do
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
  refuses any debit note or payment that would leave a bill owed less than
  nothing on any date, so the list is empty unless another writer made it so.
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

  @doc """
  The control-account tie-out as of a date: for each payable account (every
  one a posted bill recorded, and the settings'), what this module's records
  say is still owed on it (`subledger_balance`, the aged payables' total for
  the account, exceptions included), what the ledger holds on it
  (`ledger_balance`, credits less debits over every entry dated through
  `as_of`), the part of that this module posted (`owned_balance`), and
  every other posting on the account (`other_postings`, one per owner
  module, `nil` for an entry with no owner, with `legacy` for one posted
  before owners were recorded), each with its balance. `difference` is
  `subledger_balance` less `ledger_balance`, and `tied_out?` whether every
  account's is zero: an entry reversed outside this module, a manual
  journal on the account, a purchase posted by another module as well, each
  shows here as a difference with its posting, never netted away.

  All figures are read at one ledger entry number, named
  `through_entry_number`; passing it back reproduces the tie-out exactly.
  Reads the ledger, so it also needs `finance.ledger.view`. A malformed
  option is `{:error, :invalid_option}`.
  """
  @spec tie_out_control_accounts(Scope.t(), term(), Date.t(), keyword()) ::
          {:ok, map()} | {:error, refusal() | :book_not_open | :invalid_option}
  def tie_out_control_accounts(%Scope{} = scope, company_id, %Date{} = as_of, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         true <-
           Keyword.keys(options) -- [:through_entry_number] == [] || {:error, :invalid_option},
         {:ok, through} <- through_option(options) do
      TieOut.report(scope, company_id, as_of, through)
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

      values =
        for field <- [:payable_account_id | Settings.tolerance_fields()], into: %{} do
          {{:"old_#{field}", previous && Map.fetch!(previous, field)},
           {:"new_#{field}", Map.fetch!(settings, field)}}
        end
        |> Enum.flat_map(&Tuple.to_list/1)
        |> Map.new()

      change =
        struct(
          SettingsChange,
          Map.merge(values, %{
            tenant_id: settings.tenant_id,
            company_id: settings.company_id,
            changed_by_user_id: user_id,
            changed_by_impersonator_id: impersonator_id
          })
        )

      change
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
    with {:ok, settings} <- fetch_settings(scope, company_id),
         do: {:ok, settings.payable_account_id}
  end

  defp fetch_settings(scope, company_id) do
    case settings(scope, company_id) do
      nil -> {:error, :payables_not_configured}
      settings -> {:ok, settings}
    end
  end

  ## Order lines

  # Each bill line naming an order line names one the installed source
  # knows; with no source installed, none may.
  defp check_order_lines(changeset, scope, company_id) do
    lines = Changeset.get_change(changeset, :lines, [])
    named = Enum.filter(lines, &Changeset.get_field(&1, :order_line_id))

    cond do
      named == [] or not changeset.valid? ->
        {:ok, changeset}

      not OrderSource.available?() ->
        {:ok,
         put_line_errors(changeset, lines, fn line ->
           if Changeset.get_field(line, :order_line_id),
             do: Changeset.add_error(line, :order_line_id, "names no installed order source"),
             else: line
         end)}

      true ->
        named
        |> Enum.map(&Changeset.get_field(&1, :order_line_id))
        |> Enum.uniq()
        |> Enum.reduce_while({:ok, MapSet.new()}, fn id, {:ok, missing} ->
          case OrderSource.order_line(scope, company_id, id) do
            {:ok, _line} -> {:cont, {:ok, missing}}
            {:error, :line_not_found} -> {:cont, {:ok, MapSet.put(missing, id)}}
            {:error, reason} -> {:halt, {:error, {:order_source, reason}}}
          end
        end)
        |> case do
          {:ok, missing} ->
            {:ok,
             put_line_errors(changeset, lines, fn line ->
               if MapSet.member?(missing, Changeset.get_field(line, :order_line_id)),
                 do:
                   Changeset.add_error(
                     line,
                     :order_line_id,
                     "is not an order line of this company in the order source"
                   ),
                 else: line
             end)}

          error ->
            error
        end
    end
  end

  # A debit note's order lines are the corrected bill's, within what it billed.
  defp check_note_order_lines(changeset, scope, company_id, bill) do
    lines = Changeset.get_change(changeset, :lines, [])

    if changeset.valid? and Enum.any?(lines, &Changeset.get_field(&1, :order_line_id)) do
      fields =
        Enum.map(
          lines,
          &Map.new([:line_number, :order_line_id, :quantity], fn f ->
            {f, Changeset.get_field(&1, f)}
          end)
        )

      case Matching.within_billed(scope, company_id, bill, fields, nil) do
        :ok ->
          changeset

        {:error, {line_number, field, message}} ->
          put_line_errors(changeset, lines, fn line ->
            if Changeset.get_field(line, :line_number) == line_number,
              do: Changeset.add_error(line, field, message),
              else: line
          end)
      end
    else
      changeset
    end
  end

  # Replaces the lines with the checked ones; the changeset is invalid once
  # a line is.
  defp put_line_errors(changeset, lines, check) do
    checked = Enum.map(lines, check)

    if Enum.all?(checked, & &1.valid?) and Enum.all?(lines, & &1.valid?),
      do: changeset,
      else: changeset |> Changeset.put_assoc(:lines, checked) |> Map.put(:valid?, false)
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
  # since it was recorded, and other debit notes what it billed on an order
  # line.
  defp posting_account(
         scope,
         company_id,
         %Document{
           document_type: "debit_note",
           corrects_document_id: bill_id,
           document_date: date,
           total: total
         } = note
       ) do
    {:ok, bill} = fetch_document(scope, company_id, bill_id)

    cond do
      exceeds?(scope, company_id, bill, total, date) ->
        {:error, :exceeds_outstanding}

      Matching.within_billed(scope, company_id, bill, note.lines, note.id) != :ok ->
        {:error, :exceeds_billed_quantity}

      true ->
        {:ok, bill.payable_account_id}
    end
  end

  defp posting_account(scope, company_id, _bill), do: payable_account(scope, company_id)

  defp exceeds?(scope, company_id, bill, total, date) do
    owed = Map.fetch!(Balances.lowest_outstanding(scope, company_id, [bill], date), bill.id)
    Decimal.lt?(owed, total)
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
    payment_id = Ownership.next_id(Payment)

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

    owed =
      if match?(%Date{}, payment_date),
        do: Balances.lowest_outstanding(scope, company_id, bills, payment_date),
        else: Balances.outstanding(scope, company_id, bills)

    bills = Map.new(bills, &{&1.id, &1})

    allocations =
      allocations
      |> Enum.map(&check_allocation(&1, bills, owed, party_key, payment_date))
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
      id: payment_id,
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

  defp check_allocation(allocation, bills, owed, party_key, payment_date) do
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

  ## Payment requests

  # A valid payment changeset, kept as the request it was submitted as.
  defp payment_request(changeset, scope) do
    %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)
    field = &Changeset.get_field(changeset, &1)

    %PaymentRequest{
      tenant_id: field.(:tenant_id),
      company_id: field.(:company_id),
      payment_date: field.(:payment_date),
      party_key: field.(:party_key),
      party_name: field.(:party_name),
      paid_from_account_id: field.(:paid_from_account_id),
      amount: field.(:amount),
      currency_code: field.(:currency_code),
      reference: field.(:reference),
      description: field.(:description),
      submitted_by_user_id: user_id,
      submitted_by_impersonator_id: impersonator_id,
      allocations:
        changeset
        |> Changeset.get_change(:allocations)
        |> Enum.map(fn allocation ->
          struct(
            PaymentRequestAllocation,
            Map.take(Changeset.apply_changes(allocation), [
              :tenant_id,
              :company_id,
              :line_number,
              :document_id,
              :amount
            ])
          )
        end)
    }
  end

  # The attributes the request was submitted with, for its approval to
  # check and post afresh.
  defp requested_payment(request) do
    request
    |> Map.take([:payment_date, :party_key, :paid_from_account_id, :reference, :description])
    |> Map.put(
      :allocations,
      Enum.map(request.allocations, &Map.take(&1, [:document_id, :amount]))
    )
  end

  defp payment_approval(request) do
    %{
      source: "finance/payables",
      action: "payment_approval",
      subject_type: "payment_request",
      subject_id: request.id,
      subject:
        "Payment request #{request.request_number} to #{request.party_name}, " <>
          "#{amount_label(request.amount)} #{request.currency_code}",
      prepared_by: [
        %{
          user_id: request.submitted_by_user_id,
          impersonator_id: request.submitted_by_impersonator_id
        }
      ]
    }
  end

  defp submitted_payment_request(scope, company_id, request_id) do
    case fetch_payment_request(scope, company_id, request_id) do
      nil -> {:error, :payment_request_not_found}
      %PaymentRequest{event: nil} = request -> {:ok, request}
      _decided -> {:error, :payment_request_decided}
    end
  end

  defp decide_payment_request(scope, request, event, attributes, payment_id) do
    %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

    %PaymentRequestEvent{
      tenant_id: request.tenant_id,
      company_id: request.company_id,
      request_id: request.id,
      event: event,
      payment_id: payment_id,
      actor_user_id: user_id,
      actor_impersonator_id: impersonator_id
    }
    |> PaymentRequestEvent.changeset(attributes)
    |> Repo.insert()
  end

  defp fetch_payment_request(scope, company_id, request_id) when is_integer(request_id) do
    scope
    |> payment_requests_query(company_id)
    |> where([r], r.id == ^request_id)
    |> preload_payment_request(scope)
    |> Repo.one()
  end

  defp fetch_payment_request(_scope, _company_id, _request_id), do: nil

  defp payment_requests_query(scope, company_id),
    do: where(Tenancy.scope_query(PaymentRequest, scope), [r], r.company_id == ^company_id)

  defp preload_payment_request(query, scope) do
    preload(query,
      allocations:
        ^order_by(Tenancy.scope_query(PaymentRequestAllocation, scope), [a], asc: a.line_number),
      event: ^Tenancy.scope_query(PaymentRequestEvent, scope)
    )
  end

  defp request_options(options) do
    with true <- Keyword.keyword?(options),
         {:ok, filters} <-
           Keyword.validate(options, status: nil, limit: @default_limit, after: nil),
         filters = Map.new(filters),
         true <- is_nil(filters.status) or filters.status in PaymentRequest.statuses(),
         true <- is_integer(filters.limit) and filters.limit in 1..@max_limit,
         true <- is_nil(filters.after) or (is_integer(filters.after) and filters.after >= 0) do
      {:ok, filters}
    else
      _invalid -> {:error, :invalid_option}
    end
  end

  defp request_status(query, _scope, nil), do: query

  defp request_status(query, scope, "submitted") do
    decided = select(Tenancy.scope_query(PaymentRequestEvent, scope), [e], e.request_id)
    where(query, [r], r.id not in subquery(decided))
  end

  defp request_status(query, scope, event) do
    decided =
      PaymentRequestEvent
      |> Tenancy.scope_query(scope)
      |> where([e], e.event == ^event)
      |> select([e], e.request_id)

    where(query, [r], r.id in subquery(decided))
  end

  defp payment_request_view(request) do
    request
    |> Map.take([
      :id,
      :request_number,
      :payment_date,
      :party_key,
      :party_name,
      :paid_from_account_id,
      :amount,
      :currency_code,
      :reference,
      :description,
      :submitted_by_user_id,
      :submitted_by_impersonator_id,
      :submitted_at
    ])
    |> Map.merge(%{
      status: PaymentRequest.status(request),
      decision:
        request.event &&
          Map.take(request.event, [
            :event,
            :reason,
            :payment_id,
            :actor_user_id,
            :actor_impersonator_id,
            :occurred_at
          ]),
      allocations:
        Enum.map(request.allocations, &Map.take(&1, [:line_number, :document_id, :amount]))
    })
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

  # Each document's match events, oldest first, with their lines and
  # exceptions in line order.
  defp match_events(_scope, _company_id, []), do: %{}

  defp match_events(scope, company_id, document_ids) do
    exceptions = order_by(Tenancy.scope_query(MatchException, scope), [x], asc: x.id)
    lines = from(l in Tenancy.scope_query(MatchLine, scope), order_by: [asc: l.line_number])

    from(e in Tenancy.scope_query(MatchEvent, scope),
      where: e.company_id == ^company_id and e.document_id in ^document_ids,
      order_by: [asc: e.id],
      preload: [lines: ^{lines, exceptions: exceptions}]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.document_id)
  end

  ## Views

  defp settings_view(settings),
    do: Map.take(settings, [:company_id, :payable_account_id | Settings.tolerance_fields()])

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

    events = match_events(scope, company_id, ids)

    Enum.map(documents, fn document ->
      document_events = Map.get(events, document.id, [])

      document
      |> document_view(outstanding)
      |> Map.put(:debit_note_ids, Map.get(debit_notes, document.id, []))
      |> Map.put(:match_status, match_status(document, document_events))
      |> Map.put(:match_events, Enum.map(document_events, &match_event_view/1))
    end)
  end

  # Nil unless a bill names an order line; else what its latest match event
  # says, or pending before any.
  defp match_status(%Document{document_type: "bill", status: status} = document, events)
       when status != "voided" do
    if Enum.any?(document.lines, & &1.order_line_id) do
      case List.last(events) do
        nil -> "pending"
        %MatchEvent{event: "held"} -> "held"
        %MatchEvent{event: "exception_approved"} -> "exception_approved"
        %MatchEvent{event: "posted"} = posted -> posted_match_status(posted)
      end
    end
  end

  defp match_status(_document, _events), do: nil

  defp posted_match_status(%MatchEvent{lines: lines}) do
    if Enum.any?(lines, &(&1.exceptions != [])),
      do: "posted_with_exceptions",
      else: "matched"
  end

  defp match_event_view(event) do
    event
    |> Map.take([
      :id,
      :event,
      :reason,
      :held_event_id,
      :actor_user_id,
      :actor_impersonator_id,
      :occurred_at
    ])
    |> Map.put(
      :lines,
      Enum.map(event.lines, fn line ->
        line
        |> Map.take(MatchLine.fields())
        |> Map.put(:exceptions, Enum.map(line.exceptions, &Map.take(&1, [:code, :detail])))
      end)
    )
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
          :external_order_line_id,
          :order_line_id,
          :quantity
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
