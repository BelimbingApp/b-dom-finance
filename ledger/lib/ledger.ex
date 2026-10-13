defmodule Bilimbi.Finance.Ledger do
  @moduledoc """
  A company's general ledger: its book, chart of accounts, journal entries,
  and trial balance.

  Every function takes the validated `Bilimbi.Base.Tenancy.Scope` it was
  handed and an explicit company ID. Reads authorize `finance.ledger.view`
  and writes their own capability for the scope's signed-in actor and the
  target company at the moment they run, through
  `Bilimbi.Core.Company.authorize_company_target/3`: a system scope, a
  missing grant, or a sibling company without tenant-wide reach is
  `{:error, :unauthorized}`, and a company the scope cannot see is
  `{:error, :company_not_found}`. A write then holds
  `Bilimbi.Core.Company.lock_writable_company/2` for its transaction, so an
  archived company is `{:error, :company_archived}` and the company's ledger
  writes run one at a time.

  A book is opened once per company with its currency code and that
  currency's number of decimal places; both are fixed for good, because
  every posted amount is denominated in them. Amounts are decimals and are
  refused, not rounded, when they are finer than the book allows.

  The database numbers each company's entries 1, 2, 3, ... in posting
  order and stamps their posting time, so an entry's `entry_number` is never
  skipped or reused.

  An entry is posted whole: it is stored only when its lines' debits equal
  their credits, every line names an active account of the company, the
  book is open, and its date falls in an open period. A posted entry is
  never edited or deleted; `reverse_entry/4` posts its mirror image, once.
  The database refuses the same things on its own, including adding a line
  to an entry posted in an earlier transaction (see the migrations), so no
  other writer can break them either.

  An entry a module posts for a record of its own (a receivables payment,
  a payables bill, a fiscal document) carries that owner: the module's
  descriptor ID and the record, `%{module: "finance/receivables", record:
  "payment:17"}`, given as `post_entry/4`'s `owner` option. An owned record
  has one original entry, and an owned entry is corrected only through its
  owner: `reverse_entry/4` refuses it (`{:error, {:owned_by, owner}}`) and
  `reverse_owned_entry/5` posts the reversal for the owner that names
  itself, in the owner's own transaction with its own reversal record. A
  manual journal entry has no owner and is reversed directly. The database
  keeps a reversal's owner equal to its original's.

  The owner is a seam between modules, not an authorization boundary: the
  ledger cannot tell which module is calling, and `reverse_owned_entry/5`
  asks only for `finance.ledger.entries.post`. It is for the owning
  module's own correction path; a caller that passes an entry's owner from
  anywhere else reverses the entry without the owner's record, and the
  owner's control-account tie-out then shows the difference.

  A company divides its time into fiscal years of monthly periods. Periods
  close in date order and reopen in reverse; a reopen needs a reason and the
  reopen capability, and a locked period never reopens. `close_fiscal_year/4`
  posts the entry that moves the year's income and expense balances into the
  company's retained-earnings account and closes the year with its periods.
  Every close, reopen, and lock is an append-only closing event recording who
  did it, when, and why; a status is the latest event's.

  A company that is controlled (`set_controlled_bookkeeping/3`; a new
  company's book opens controlled) posts only into a fiscal period it has
  opened and left open, so the first year is opened explicitly with
  `open_fiscal_year/3`, and an entry dated after the last year is refused
  until the next one is opened. Entries are never refused for being old: an
  entry dated into an open period posts, however late. The entries recorded
  45 or more days after their dates are listed by `list_late_recordings/3`,
  and an independent reviewer records the reason for each with
  `record_late_recording_review/4`.

  A company requires separation of duties unless it turns it off: the
  person who approves a record, or whoever impersonated them, is not the
  person who prepared it. `check_approval/3` is how every Finance approval
  asks, and records what an independent reviewer should read: a same-person
  approval while separation is off, and an override of a control, such as a
  reopened period. A manual journal is submitted and posts only once
  someone approves it (`submit_journal/3`, `approve_journal/3`).

  Results are plain maps; the schemas stay private to this module.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company

  alias Bilimbi.Finance.Ledger.{
    Account,
    ApprovalException,
    Book,
    Bookkeeping,
    BookkeepingChange,
    ClosingEvent,
    Duties,
    DutySeparationChange,
    Entry,
    FiscalYear,
    Journal,
    JournalEvent,
    JournalLine,
    LateRecordings,
    Line,
    Period,
    Postings
  }

  alias Ecto.Changeset

  @view "finance.ledger.view"
  @manage_accounts "finance.ledger.accounts.manage"
  @post_entries "finance.ledger.entries.post"
  @manage_periods "finance.ledger.periods.manage"
  @reopen_periods "finance.ledger.periods.reopen"
  @lock_periods "finance.ledger.periods.lock"
  @manage_duty_separation "finance.ledger.duty-separation.manage"
  @manage_controlled_bookkeeping "finance.ledger.controlled-bookkeeping.manage"
  @review_late_recordings "finance.ledger.late-recordings.review"
  @submit_journals "finance.ledger.journals.submit"
  @approve_journals "finance.ledger.journals.approve"
  @review_exceptions "finance.ledger.approval-exceptions.review"

  # A year-end close moves these account types' balances into retained earnings.
  @closed_by_year ["income", "expense"]

  @default_entry_limit 100
  @max_entry_limit 500
  @max_bigint 9_223_372_036_854_775_807

  @type refusal :: :unauthorized | :company_not_found
  @type write_refusal :: refusal() | :company_archived

  @doc "The capability every ledger read asks for."
  def view_capability, do: @view

  @doc "The capability that opens a book and maintains the chart of accounts."
  def manage_accounts_capability, do: @manage_accounts

  @doc "The capability that posts and reverses journal entries."
  def post_entries_capability, do: @post_entries

  @doc "The capability that opens fiscal years and closes periods and years."
  def manage_periods_capability, do: @manage_periods

  @doc "The privileged capability that reopens a closed period or fiscal year."
  def reopen_periods_capability, do: @reopen_periods

  @doc "The capability that locks a closed period for good."
  def lock_periods_capability, do: @lock_periods

  @doc "The capability that turns the company's separation of duties on or off."
  def manage_duty_separation_capability, do: @manage_duty_separation

  @doc "The capability that turns the company's controlled bookkeeping on or off."
  def manage_controlled_bookkeeping_capability, do: @manage_controlled_bookkeeping

  @doc "The capability that records an independent review of an entry recorded late."
  def review_late_recordings_capability, do: @review_late_recordings

  @doc "The capability that submits a manual journal for approval."
  def submit_journals_capability, do: @submit_journals

  @doc "The capability that approves (posting it) or rejects a submitted journal."
  def approve_journals_capability, do: @approve_journals

  @doc "The capability that records an independent review of an approval exception."
  def review_exceptions_capability, do: @review_exceptions

  ## Book

  @doc """
  The company's book: `%{company_id, currency_code, minor_units}`, or
  `{:error, :book_not_open}` before `open_book/3`.
  """
  @spec get_book(Scope.t(), term()) :: {:ok, map()} | {:error, refusal() | :book_not_open}
  def get_book(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case book(scope, company_id) do
        nil -> {:error, :book_not_open}
        book -> {:ok, book_view(book)}
      end
    end
  end

  @doc """
  Opens the company's book with `currency_code` (three upper-case letters)
  and `minor_units` (the currency's decimal places, 0 to 4). A book opens
  once; a second call is `{:error, :book_already_open}`.
  """
  @spec open_book(Scope.t(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :book_already_open | Changeset.t()}
  def open_book(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_accounts, fn ->
      if book(scope, company_id) do
        {:error, :book_already_open}
      else
        # A new company is controlled from the start; see the module doc.
        with {:ok, book} <-
               %Book{tenant_id: Scope.tenant_id(scope), company_id: company_id}
               |> Book.changeset(attributes)
               |> Repo.insert(),
             {:ok, _change, :recorded} <-
               Bookkeeping.change(scope, company_id, %{controlled: true}) do
          {:ok, book_view(book)}
        end
      end
    end)
  end

  ## Chart of accounts

  @doc "The company's accounts, ordered by code."
  @spec list_accounts(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_accounts(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok,
       scope
       |> accounts_query(company_id)
       |> order_by([a], asc: a.code)
       |> Repo.all()
       |> Enum.map(&account_view/1)}
    end
  end

  @doc """
  Adds an account: `code` (unique in the company), `name`, `account_type`
  (one of `account_types/0`), and optionally `parent_id`, an account of the
  same type to group it under, `active`, and `retained_earnings`.

  `retained_earnings: true` designates an equity account as the one the
  year-end close moves profit into; designating another account later moves
  the designation.
  """
  @spec create_account(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def create_account(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_accounts, fn ->
      %Account{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> Account.create_changeset(attributes)
      |> validate_parent(scope, company_id)
      |> save_account(scope, company_id, &Repo.insert/1)
    end)
  end

  @doc """
  Changes an account's `name`, `parent_id`, `active` flag, or
  `retained_earnings` designation. Its code and type never change. A
  deactivated account takes no new postings; its history and reversals of it
  stay.

  An account is deactivated only once its balance (all its posted debits
  less all its credits) is zero: with a balance, the changeset's `active`
  error names the account and the balance, so what is still owed on or by
  an account is never left where nothing can be posted against it.
  Reactivating, and every other change, is unaffected.
  """
  @spec update_account(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :account_not_found | Changeset.t()}
  def update_account(%Scope{} = scope, company_id, account_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_accounts, fn ->
      case account(scope, company_id, account_id) do
        nil ->
          {:error, :account_not_found}

        account ->
          account
          |> Account.update_changeset(attributes)
          |> validate_parent(scope, company_id)
          |> validate_deactivation(scope, company_id)
          |> save_account(scope, company_id, &Repo.update/1)
      end
    end)
  end

  @doc "The account types a chart of accounts classifies by."
  @spec account_types() :: [String.t()]
  def account_types, do: Account.types()

  ## Journal entries

  @doc """
  Posts a journal entry: `entry_date`, `description`, an optional
  `reference`, and `lines`, each `%{account_id, debit}` or
  `%{account_id, credit}` with an optional `description`.

  The entry is refused with a changeset error unless it has at least two
  lines, its debits equal its credits, every line names an active account
  of the company with one positive amount no finer than the book's minor
  units, and `entry_date` falls in an open period, not before the company's
  first fiscal year. A controlled company (see `set_controlled_bookkeeping/3`)
  also needs a fiscal period covering the date, so a date after its last year
  is refused until the next year is opened; an uncontrolled company may post
  after its last year. `{:error, :book_not_open}` before the book is opened.

  Options:

    * `settlement_account_ids`, the settlement exception to the
      active-account rule: a list of account IDs that may be inactive in
      this entry only, for a module that settles a document it posted
      earlier (such as a payment against an invoice recorded on an account
      deactivated since). Every listed account must still be an account of
      the company, and every other line still needs an active account.
    * `owner`, `%{module: module, record: record}`: the module (its
      descriptor ID, `finance/receivables`) and the record of its own
      (`payment:17`, a kind and a positive integer) this entry recognises.
      The record has at most one original entry in the company: a second
      is refused with an `owner_record` changeset error. An owned entry is
      corrected only through `reverse_owned_entry/5`.

  Anything else in `options`, a list of anything but integers, or an owner
  of another shape is `{:error, :invalid_option}`.
  """
  @spec post_entry(Scope.t(), term(), map(), keyword()) ::
          {:ok, map()}
          | {:error, write_refusal() | :book_not_open | :invalid_option | Changeset.t()}
  def post_entry(%Scope{} = scope, company_id, attributes, options \\ [])
      when is_map(attributes) and is_list(options) do
    write(scope, company_id, @post_entries, fn ->
      with {:ok, settlement_ids, owner} <- post_options(options),
           {:ok, book} <- open_book_for_write(scope, company_id) do
        lines = attributes |> fetch(:lines) |> List.wrap()

        scope
        |> entry_changeset(book, Map.drop(attributes, [:lines, "lines"]), lines)
        |> put_owner(owner)
        |> validate_open_period(scope, company_id)
        |> validate_accounts(scope, company_id, settlement_ids)
        |> insert_entry(scope)
      end
    end)
  end

  defp post_options(options) do
    with true <- Keyword.keyword?(options),
         {:ok, validated} <- Keyword.validate(options, settlement_account_ids: [], owner: nil),
         ids = Keyword.fetch!(validated, :settlement_account_ids),
         true <- is_list(ids) and Enum.all?(ids, &is_integer/1),
         {:ok, owner} <- owner_option(Keyword.fetch!(validated, :owner)) do
      {:ok, ids, owner}
    else
      _invalid -> {:error, :invalid_option}
    end
  end

  @owner_module ~r"\A[a-z][a-z0-9_]*/[a-z][a-z0-9_]*\z"
  @owner_record ~r"\A[a-z][a-z0-9_]*:[1-9][0-9]*\z"

  defp owner_option(nil), do: {:ok, nil}

  defp owner_option(%{module: module, record: record} = owner)
       when is_binary(module) and is_binary(record) and map_size(owner) == 2 do
    if String.length(module) <= 100 and String.length(record) <= 100 and
         Regex.match?(@owner_module, module) and Regex.match?(@owner_record, record),
       do: {:ok, %{module: module, record: record}},
       else: {:error, :invalid_option}
  end

  defp owner_option(_other), do: {:error, :invalid_option}

  defp put_owner(changeset, nil), do: changeset

  defp put_owner(changeset, %{module: module, record: record}) do
    changeset
    |> Changeset.put_change(:owner_module, module)
    |> Changeset.put_change(:owner_record, record)
  end

  @doc """
  Posts the reversal of a manual entry on `entry_date` (not before the
  original's) with `description`: the same accounts and amounts with debits
  and credits swapped. An entry is reversed at most once
  (`{:error, :already_reversed}`), and a reversal is not itself reversed
  (`{:error, :reversal_not_reversible}`); post a new entry instead. Accounts
  deactivated since the original still take its reversal, but its date must
  fall in an open period, as a new entry's does. A year-end closing entry is
  reversed only by `reopen_fiscal_year/4` (`{:error, :closing_entry}`).

  An entry another module owns is `{:error, {:owned_by, %{module, record}}}`:
  correct it through that module, which records its own reversal and calls
  `reverse_owned_entry/5`, so the ledger and the owner's records agree.
  """
  @spec reverse_entry(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :entry_not_found
             | :already_reversed
             | :reversal_not_reversible
             | :closing_entry
             | {:owned_by, map()}
             | Changeset.t()}
  def reverse_entry(%Scope{} = scope, company_id, entry_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @post_entries, fn ->
      with {:ok, book} <- open_book_for_write(scope, company_id),
           {:ok, original} <- reversible_entry(scope, company_id, entry_id),
           :ok <- unowned(original) do
        scope
        |> reversal_changeset(book, original, Map.drop(attributes, [:lines, "lines"]))
        |> validate_open_period(scope, company_id)
        |> validate_accounts(scope, company_id, :any)
        |> insert_entry(scope)
      end
    end)
  end

  defp unowned(%Entry{owner_module: nil}), do: :ok

  defp unowned(%Entry{owner_module: module, owner_record: record}),
    do: {:error, {:owned_by, %{module: module, record: record}}}

  @doc """
  The owner's correction path: posts the reversal of an entry the calling
  module posted with `owner` (`post_entry/4`'s option, the same module and
  record), as `reverse_entry/4` does for a manual entry, and with the same
  refusals. The owner calls it inside the transaction that records its own
  reversal (a payment reversal, a cancellation), so both stand or neither.
  The reversal carries the same owner. An entry owned by another module or
  record is `{:error, :not_the_owner}`; a manual entry is
  `{:error, :not_owned}`, and is reversed with `reverse_entry/4`. A legacy
  entry, posted before owners were recorded and never claimed, is reversed
  by the module whose record names it, without an owner on either side.

  Only the owning module calls this, from its own correction path. The
  ledger cannot authenticate the caller: anyone holding
  `finance.ledger.entries.post` who passes an entry's owner reverses it
  without the owner's record, which the owner's control-account tie-out
  then shows as a difference. Use `reverse_entry/4` for a manual entry, and
  the owning module's own function for an owned one.
  """
  @spec reverse_owned_entry(Scope.t(), term(), term(), map(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :invalid_option
             | :entry_not_found
             | :already_reversed
             | :reversal_not_reversible
             | :closing_entry
             | :not_the_owner
             | :not_owned
             | Changeset.t()}
  def reverse_owned_entry(%Scope{} = scope, company_id, entry_id, owner, attributes)
      when is_map(attributes) do
    write(scope, company_id, @post_entries, fn ->
      with {:ok, owner} <- owner_option(owner),
           {:ok, book} <- open_book_for_write(scope, company_id),
           {:ok, original} <- reversible_entry(scope, company_id, entry_id),
           :ok <- owned_by(original, owner) do
        scope
        |> reversal_changeset(book, original, Map.drop(attributes, [:lines, "lines"]))
        |> validate_open_period(scope, company_id)
        |> validate_accounts(scope, company_id, :any)
        |> insert_entry(scope)
      end
    end)
  end

  defp owned_by(%Entry{owner_module: nil, legacy: true}, _owner), do: :ok
  defp owned_by(%Entry{owner_module: nil}, _owner), do: {:error, :not_owned}

  defp owned_by(%Entry{owner_module: module, owner_record: record}, owner) do
    if owner == %{module: module, record: record}, do: :ok, else: {:error, :not_the_owner}
  end

  # A reversal carries its original's owner; the database refuses any other.
  defp reversal_changeset(scope, book, original, attributes) do
    lines =
      Enum.map(original.lines, fn line ->
        %{
          account_id: line.account_id,
          debit: line.credit,
          credit: line.debit,
          description: line.description
        }
      end)

    scope
    |> entry_changeset(book, attributes, lines)
    |> Changeset.put_change(:reverses_entry_id, original.id)
    |> Changeset.put_change(:owner_module, original.owner_module)
    |> Changeset.put_change(:owner_record, original.owner_record)
    |> Changeset.validate_change(:entry_date, fn :entry_date, date ->
      if Date.compare(date, original.entry_date) == :lt,
        do: [entry_date: "cannot be before the reversed entry's date"],
        else: []
    end)
  end

  @doc """
  One posted entry with its lines, and `reversed_by_entry_id` when a later
  entry reversed it.
  """
  @spec get_entry(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :entry_not_found}
  def get_entry(%Scope{} = scope, company_id, entry_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case entry_with_lines(scope, company_id, entry_id) do
        nil -> {:error, :entry_not_found}
        entry -> {:ok, entry_view(entry, reversed_by(scope, company_id, [entry.id]))}
      end
    end
  end

  @doc """
  Posted entries with their lines, ordered by entry date and then ID.
  Options: `from` and `to` dates (inclusive), `limit` (an integer from 1 to
  #{@max_entry_limit}, default #{@default_entry_limit}), and
  `after`, the `{entry_date, id}` of the last entry already read, which
  returns only the entries after it, so a caller pages by passing the last
  returned entry's date and ID until fewer than `limit` entries come back.
  `account_id` keeps the entries with a line on that account,
  `through_entry_number` the entries numbered up to it, and
  `exclude_closing: true` leaves out year-end closing entries and their
  reversals, so the entries behind an `account_totals/3` figure are listed
  with the same options. A malformed option is `{:error, :invalid_option}`.
  """
  @spec list_entries(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_entries(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, limit, from, to, cursor} <- entry_options(options),
         {:ok, account_id} <- account_option(options),
         {:ok, through} <- through_option(options),
         {:ok, exclude_closing} <- exclude_closing_option(options) do
      entries =
        scope
        |> entries_query(company_id)
        |> date_bound(:from, from)
        |> date_bound(:to, to)
        |> through_bound(through)
        |> account_bound(scope, company_id, account_id)
        |> closing_bound(scope, company_id, exclude_closing)
        |> after_cursor(cursor)
        |> order_by([e], asc: e.entry_date, asc: e.id)
        |> limit(^limit)
        |> preload(lines: ^ordered_lines(scope))
        |> Repo.all()

      reversals = reversed_by(scope, company_id, Enum.map(entries, & &1.id))
      {:ok, Enum.map(entries, &entry_view(&1, reversals))}
    end
  end

  defp entry_options(options) do
    limit = Keyword.get(options, :limit, @default_entry_limit)
    from = Keyword.get(options, :from)
    to = Keyword.get(options, :to)
    cursor = Keyword.get(options, :after)

    if is_integer(limit) and limit in 1..@max_entry_limit and optional_date?(from) and
         optional_date?(to) and valid_cursor?(cursor),
       do: {:ok, limit, from, to, cursor},
       else: {:error, :invalid_option}
  end

  defp exclude_closing_option(options) do
    case Keyword.get(options, :exclude_closing, false) do
      flag when is_boolean(flag) -> {:ok, flag}
      _other -> {:error, :invalid_option}
    end
  end

  defp account_option(options) do
    case Keyword.get(options, :account_id) do
      nil -> {:ok, nil}
      id when is_integer(id) and id in 1..@max_bigint -> {:ok, id}
      _other -> {:error, :invalid_option}
    end
  end

  defp optional_date?(value), do: is_nil(value) or match?(%Date{}, value)

  defp valid_cursor?(nil), do: true
  defp valid_cursor?({%Date{}, id}), do: is_integer(id) and id in 1..@max_bigint
  defp valid_cursor?(_cursor), do: false

  ## Separation of duties

  @doc """
  The company's separation of duties: `%{required, change}`, where
  `change` is the latest change (`list_duty_separation_changes/2` shows
  one) or nil. A company that never changed it requires separation.
  """
  @spec get_duty_separation(Scope.t(), term()) :: {:ok, map()} | {:error, refusal()}
  def get_duty_separation(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok, duty_separation_view(Duties.latest_change(scope, company_id))}
    end
  end

  @doc """
  Turns the company's separation of duties on or off: `required` (a
  boolean) and a `reason`, which turning it off needs. The change is
  appended to the company's history with the actor, any impersonator, and
  the database's time; a call that changes nothing records nothing.

  While separation is off, an approval by the person who prepared the
  record is allowed and listed in the approval exceptions for an
  independent reviewer, with this change's reason.
  """
  @spec set_duty_separation(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def set_duty_separation(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_duty_separation, fn ->
      with {:ok, latest} <- Duties.change(scope, company_id, attributes) do
        {:ok, duty_separation_view(latest)}
      end
    end)
  end

  @doc "Every change of the company's separation of duties, oldest first."
  @spec list_duty_separation_changes(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_duty_separation_changes(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok, scope |> Duties.changes(company_id) |> Enum.map(&change_view/1)}
    end
  end

  @doc """
  Whether the scope's actor may approve a record, for the Finance modules
  that approve, called in the transaction that records the approval (it
  takes the same company lock), so a refusal rolls the approval back.

  `approval` describes it: `source` (the module ID, such as
  `"finance/payables"`), `action` and `subject_type` (lower-case codes),
  `subject_id`, `subject` (a label a reviewer reads), `prepared_by` (a list
  of `%{user_id, impersonator_id}`, everyone whose work is approved), and,
  for an approval that overrides a control, `override: true` with the
  approver's `reason`.

  When the approver, or whoever impersonated them, is someone in
  `prepared_by` or impersonated someone there, the approval is
  `{:error, :same_person}` while the company requires separation; while it
  does not, the approval is allowed and recorded as a same-person approval
  exception with the reason the setting was turned off. An override is
  always recorded. Anything else records nothing. The caller needs
  `finance.ledger.view`, which the exceptions are read with.
  """
  @spec check_approval(Scope.t(), term(), map()) ::
          :ok | {:error, write_refusal() | :same_person | Changeset.t()}
  def check_approval(%Scope{} = scope, company_id, approval) when is_map(approval) do
    with {:ok, _exception} <-
           write(scope, company_id, @view, fn -> Duties.check(scope, company_id, approval) end),
         do: :ok
  end

  @doc """
  The company's approval exceptions, oldest first, each with its `review`
  or nil: `exception_number`, `source`, `action`, `subject_type`,
  `subject_id`, `subject`, `same_person`, `override`, who prepared and
  approved it, `reason`, `separation_change_id`, and `recorded_at`.

  Options: `recorded_from` and `recorded_before` (`DateTime`s: from is
  inclusive and before exclusive, so a period's bounds in any time zone
  select it exactly), `reviewed` (`true` or `false`; omitted lists both),
  `limit` (default 100, at most 500), and `after`, the last
  `exception_number` of the previous page. A malformed option is
  `{:error, :invalid_option}`.
  """
  @spec list_approval_exceptions(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_approval_exceptions(%Scope{} = scope, company_id, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, filters} <- exception_options(options) do
      {:ok, scope |> Duties.exceptions(company_id, filters) |> Enum.map(&exception_view/1)}
    end
  end

  defp exception_options(options) do
    with true <- Keyword.keyword?(options),
         {:ok, filters} <-
           Keyword.validate(options,
             recorded_from: nil,
             recorded_before: nil,
             reviewed: nil,
             limit: @default_entry_limit,
             after: nil
           ),
         filters = Map.new(filters),
         true <- optional_instant?(filters.recorded_from),
         true <- optional_instant?(filters.recorded_before),
         true <- filters.reviewed in [nil, true, false],
         true <- is_integer(filters.limit) and filters.limit in 1..@max_entry_limit,
         true <- is_nil(filters.after) or (is_integer(filters.after) and filters.after >= 0) do
      {:ok, filters}
    else
      _invalid -> {:error, :invalid_option}
    end
  end

  defp optional_instant?(value), do: is_nil(value) or match?(%DateTime{}, value)

  @doc "One approval exception, as `list_approval_exceptions/3` shows it."
  @spec get_approval_exception(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :exception_not_found}
  def get_approval_exception(%Scope{} = scope, company_id, exception_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case Duties.exception(scope, company_id, exception_id) do
        nil -> {:error, :exception_not_found}
        exception -> {:ok, exception_view(exception)}
      end
    end
  end

  @doc """
  Records an independent review of an approval exception, with an optional
  `note`: the reviewer, any impersonator, and the database's time. An
  exception is reviewed once (`{:error, :already_reviewed}`), and never by
  whoever approved or prepared what it records, nor anyone impersonating
  them (`{:error, :reviewer_not_independent}`), whatever the company's
  separation setting.
  """
  @spec review_approval_exception(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :exception_not_found
             | :already_reviewed
             | :reviewer_not_independent
             | Changeset.t()}
  def review_approval_exception(%Scope{} = scope, company_id, exception_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @review_exceptions, fn ->
      with %ApprovalException{} = exception <-
             Duties.exception(scope, company_id, exception_id) ||
               {:error, :exception_not_found},
           {:ok, _review} <- Duties.review(scope, company_id, exception, attributes) do
        {:ok, exception_view(Duties.exception(scope, company_id, exception.id))}
      end
    end)
  end

  ## Manual journals

  @doc """
  Submits a manual journal for approval: `entry_date`, `description`, an
  optional `reference`, and `lines`, as `post_entry/4` takes them. It is
  checked as an entry would be (balanced, active accounts of the company,
  an open period) and kept, numbered per company, with the submitter and
  the database's time; nothing posts until `approve_journal/3`.
  """
  @spec submit_journal(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :book_not_open | Changeset.t()}
  def submit_journal(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @submit_journals, fn ->
      with {:ok, book} <- open_book_for_write(scope, company_id) do
        lines = attributes |> fetch(:lines) |> List.wrap()

        scope
        |> journal_changeset(book, Map.drop(attributes, [:lines, "lines"]), lines)
        |> validate_open_period(scope, company_id)
        |> validate_accounts(scope, company_id, [])
        |> Repo.insert()
        |> case do
          {:ok, journal} -> {:ok, journal_view(fetch_journal(scope, company_id, journal.id))}
          error -> error
        end
      end
    end)
  end

  @doc """
  Approves a submitted journal, which posts it as an entry on its date with
  its lines, by the approver, and records the `approved` event naming the
  entry. The entry is checked as `post_entry/4` checks one, now: a period
  closed or an account deactivated since submission is the ledger's
  changeset, and the journal stays submitted.

  The approver differs from the submitter (`{:error, :same_person}`)
  unless the company has turned separation of duties off, when the
  approval is recorded as an approval exception (`check_approval/3`).
  Anything but a submitted journal is `{:error, :journal_decided}`.
  """
  @spec approve_journal(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :book_not_open
             | :journal_not_found
             | :journal_decided
             | :same_person
             | Changeset.t()}
  def approve_journal(%Scope{} = scope, company_id, journal_id) do
    write(scope, company_id, @approve_journals, fn ->
      with {:ok, book} <- open_book_for_write(scope, company_id),
           {:ok, journal} <- submitted_journal(scope, company_id, journal_id),
           {:ok, _exception} <- Duties.check(scope, company_id, journal_approval(journal)),
           {:ok, entry} <- post_journal(scope, company_id, book, journal),
           {:ok, _event} <- decide_journal(scope, journal, "approved", %{}, entry.id) do
        {:ok, journal_view(fetch_journal(scope, company_id, journal.id))}
      end
    end)
  end

  @doc """
  Rejects a submitted journal with a `reason`; it never posts. Anything but
  a submitted journal is `{:error, :journal_decided}`.
  """
  @spec reject_journal(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :journal_not_found | :journal_decided | Changeset.t()}
  def reject_journal(%Scope{} = scope, company_id, journal_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @approve_journals, fn ->
      with {:ok, journal} <- submitted_journal(scope, company_id, journal_id),
           {:ok, _event} <- decide_journal(scope, journal, "rejected", attributes, nil) do
        {:ok, journal_view(fetch_journal(scope, company_id, journal.id))}
      end
    end)
  end

  @doc """
  One journal with its lines, `status` (`submitted`, `approved`, or
  `rejected`), and `decision`: who approved or rejected it, when, any
  `reason`, and the `entry_id` an approval posted.
  """
  @spec get_journal(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :journal_not_found}
  def get_journal(%Scope{} = scope, company_id, journal_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case fetch_journal(scope, company_id, journal_id) do
        nil -> {:error, :journal_not_found}
        journal -> {:ok, journal_view(journal)}
      end
    end
  end

  @doc """
  The company's journals by number, as `get_journal/3` shows them. Options:
  `status` (one of `journal_statuses/0`), `limit` (default 100, at most
  500), and `after`, the last `journal_number` of the previous page.
  """
  @spec list_journals(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_journals(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, filters} <- journal_options(options) do
      {:ok,
       scope
       |> journals_query(company_id)
       |> journal_status(scope, filters.status)
       |> then(fn query ->
         if filters.after, do: where(query, [j], j.journal_number > ^filters.after), else: query
       end)
       |> order_by([j], asc: j.journal_number)
       |> limit(^filters.limit)
       |> preload_journal(scope)
       |> Repo.all()
       |> Enum.map(&journal_view/1)}
    end
  end

  @doc "The statuses a journal moves through."
  @spec journal_statuses() :: [String.t()]
  def journal_statuses, do: Journal.statuses()

  defp journal_options(options) do
    with true <- Keyword.keyword?(options),
         {:ok, filters} <-
           Keyword.validate(options, status: nil, limit: @default_entry_limit, after: nil),
         filters = Map.new(filters),
         true <- is_nil(filters.status) or filters.status in Journal.statuses(),
         true <- is_integer(filters.limit) and filters.limit in 1..@max_entry_limit,
         true <- is_nil(filters.after) or (is_integer(filters.after) and filters.after >= 0) do
      {:ok, filters}
    else
      _invalid -> {:error, :invalid_option}
    end
  end

  defp journal_status(query, _scope, nil), do: query

  defp journal_status(query, scope, "submitted") do
    decided = select(Tenancy.scope_query(JournalEvent, scope), [e], e.journal_id)
    where(query, [j], j.id not in subquery(decided))
  end

  defp journal_status(query, scope, event) do
    decided =
      JournalEvent
      |> Tenancy.scope_query(scope)
      |> where([e], e.event == ^event)
      |> select([e], e.journal_id)

    where(query, [j], j.id in subquery(decided))
  end

  defp journal_changeset(scope, book, attributes, lines) do
    %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

    line_changesets =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, number} ->
        %JournalLine{tenant_id: book.tenant_id, company_id: book.company_id, line_number: number}
        |> Line.changeset(if(is_map(line), do: line, else: %{}), book.minor_units)
      end)

    %Journal{
      tenant_id: book.tenant_id,
      company_id: book.company_id,
      currency_code: book.currency_code,
      submitted_by_user_id: user_id,
      submitted_by_impersonator_id: impersonator_id
    }
    |> Journal.changeset(attributes)
    |> Changeset.put_assoc(:lines, line_changesets)
    |> validate_balance(line_changesets)
  end

  defp submitted_journal(scope, company_id, journal_id) do
    case fetch_journal(scope, company_id, journal_id) do
      nil -> {:error, :journal_not_found}
      %Journal{event: nil} = journal -> {:ok, journal}
      _decided -> {:error, :journal_decided}
    end
  end

  defp journal_approval(journal) do
    %{
      source: "finance/ledger",
      action: "journal_approval",
      subject_type: "journal",
      subject_id: journal.id,
      subject: "Journal #{journal.journal_number}: #{journal.description}",
      prepared_by: [
        %{
          user_id: journal.submitted_by_user_id,
          impersonator_id: journal.submitted_by_impersonator_id
        }
      ]
    }
  end

  defp post_journal(scope, company_id, book, journal) do
    lines =
      Enum.map(journal.lines, fn line ->
        Map.take(line, [:account_id, :debit, :credit, :description])
      end)

    scope
    |> entry_changeset(book, Map.take(journal, [:entry_date, :description, :reference]), lines)
    |> validate_open_period(scope, company_id)
    |> validate_accounts(scope, company_id, [])
    |> insert_entry(scope)
  end

  defp decide_journal(scope, journal, event, attributes, entry_id) do
    %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

    %JournalEvent{
      tenant_id: journal.tenant_id,
      company_id: journal.company_id,
      journal_id: journal.id,
      event: event,
      entry_id: entry_id,
      actor_user_id: user_id,
      actor_impersonator_id: impersonator_id
    }
    |> JournalEvent.changeset(attributes)
    |> Repo.insert()
  end

  defp fetch_journal(scope, company_id, journal_id) when is_integer(journal_id) do
    scope
    |> journals_query(company_id)
    |> where([j], j.id == ^journal_id)
    |> preload_journal(scope)
    |> Repo.one()
  end

  defp fetch_journal(_scope, _company_id, _journal_id), do: nil

  defp journals_query(scope, company_id),
    do: where(Tenancy.scope_query(Journal, scope), [j], j.company_id == ^company_id)

  defp preload_journal(query, scope) do
    preload(query,
      lines: ^order_by(Tenancy.scope_query(JournalLine, scope), [l], asc: l.line_number),
      event: ^Tenancy.scope_query(JournalEvent, scope)
    )
  end

  ## Controlled bookkeeping

  @doc """
  The company's controlled bookkeeping: `%{controlled, change, fiscal_years}`,
  where `change` is the latest change (`list_controlled_bookkeeping_changes/2`
  shows them all) or nil, and `fiscal_years` counts the company's fiscal
  years. A company with no change is not controlled; a new company's book
  opens controlled. A controlled company with no fiscal year has no period to
  post into until one is opened with `open_fiscal_year/3`.
  """
  @spec get_controlled_bookkeeping(Scope.t(), term()) :: {:ok, map()} | {:error, refusal()}
  def get_controlled_bookkeeping(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok, controlled_view(scope, company_id)}
    end
  end

  @doc """
  Turns the company's controlled bookkeeping on or off: `controlled` (a
  boolean) and a `reason`, which turning it off needs. The change is appended
  to the company's history with the actor, any impersonator, and the
  database's time; a call that changes nothing records nothing.

  Turning it off overrides a control, so it is listed in the approval
  exceptions for an independent reviewer, with its reason. Turning it on
  needs no reason.
  """
  @spec set_controlled_bookkeeping(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def set_controlled_bookkeeping(%Scope{} = scope, company_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_controlled_bookkeeping, fn ->
      with {:ok, change, outcome} <- Bookkeeping.change(scope, company_id, attributes),
           {:ok, _exception} <- record_controlled_off(scope, company_id, change, outcome) do
        {:ok, controlled_view(scope, company_id)}
      end
    end)
  end

  defp record_controlled_off(_scope, _company_id, _change, :unchanged), do: {:ok, nil}
  defp record_controlled_off(_scope, _company_id, %{controlled: true}, _outcome), do: {:ok, nil}

  defp record_controlled_off(scope, company_id, change, :recorded) do
    Duties.check(scope, company_id, %{
      source: "finance/ledger",
      action: "controlled_bookkeeping_off",
      subject_type: "bookkeeping",
      subject_id: change.id,
      subject: "Controlled bookkeeping of the company",
      prepared_by: [],
      override: true,
      reason: change.reason
    })
  end

  @doc "Every change of the company's controlled bookkeeping, oldest first."
  @spec list_controlled_bookkeeping_changes(Scope.t(), term()) ::
          {:ok, [map()]} | {:error, refusal()}
  def list_controlled_bookkeeping_changes(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok,
       scope
       |> Bookkeeping.changes(company_id)
       |> Enum.map(&bookkeeping_change_view/1)}
    end
  end

  ## Late recordings

  @doc """
  The thresholds of the late-recording report, in days from an entry's date
  to its recording: an entry is listed from `approaching_days`, and is late
  past `late_days`.
  """
  @spec late_recording_thresholds() :: %{
          approaching_days: pos_integer(),
          late_days: pos_integer()
        }
  def late_recording_thresholds, do: LateRecordings.thresholds()

  @doc """
  Posted entries recorded late, oldest entry number first. Each has
  `entry_number`, `entry_id`, `entry_date` (its transaction date), `posted_at`
  (when it was recorded), `days` (whole days from one to the other), `status`
  (`"approaching"` or `"late"`), `description`, `reference`, who posted it, and
  `review` (the reviewer's `reason`, `reviewed_by_user_id`,
  `reviewed_by_impersonator_id`, and `reviewed_at`) or nil.

  Options: `status` (`"approaching"` or `"late"`; omitted lists both),
  `reviewed` (`true` or `false`; omitted lists both), `limit` (default 100, at
  most 500), and `after`, the last `entry_number` of the previous page. A
  malformed option is `{:error, :invalid_option}`.
  """
  @spec list_late_recordings(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_late_recordings(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, filters} <- late_recording_options(options) do
      {:ok,
       scope
       |> LateRecordings.list(company_id, filters)
       |> Enum.map(&late_recording_view/1)}
    end
  end

  defp late_recording_options(options) do
    with true <- Keyword.keyword?(options),
         {:ok, filters} <-
           Keyword.validate(options,
             status: nil,
             reviewed: nil,
             limit: @default_entry_limit,
             after: nil
           ),
         filters = Map.new(filters),
         true <- filters.status in [nil, "approaching", "late"],
         true <- filters.reviewed in [nil, true, false],
         true <- is_integer(filters.limit) and filters.limit in 1..@max_entry_limit,
         true <- is_nil(filters.after) or (is_integer(filters.after) and filters.after >= 0) do
      {:ok, filters}
    else
      _invalid -> {:error, :invalid_option}
    end
  end

  @doc """
  Records an independent review of a late entry, with its `reason`: who
  reviewed it, any impersonator, and the database's time. An entry is reviewed
  once (`{:error, :already_reviewed}`), it must be listed
  (`{:error, :not_late_recorded}`), and never reviewed by whoever posted it or
  impersonated its poster (`{:error, :reviewer_not_independent}`).
  """
  @spec record_late_recording_review(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :entry_not_found
             | :not_late_recorded
             | :already_reviewed
             | :reviewer_not_independent
             | Changeset.t()}
  def record_late_recording_review(%Scope{} = scope, company_id, entry_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @review_late_recordings, fn ->
      case LateRecordings.entry(scope, company_id, entry_id) do
        nil -> {:error, :entry_not_found}
        entry -> LateRecordings.review(scope, company_id, entry, attributes)
      end
    end)
    |> public_result(&late_review_view/1)
  end

  ## Fiscal years and periods

  @doc """
  Opens the company's next fiscal year and divides it into calendar-month
  periods, all open. `start_date` is the first day of a month and `end_date`
  the last day of a month, one to 24 months on; `end_date` defaults to
  twelve months on. The first year may start on any month; each later year
  starts the day after the previous one ends, which is also its default.
  Once a company has a fiscal year, no entry is posted before the first.
  """
  @spec open_fiscal_year(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :book_not_open | Changeset.t()}
  def open_fiscal_year(%Scope{} = scope, company_id, attributes \\ %{})
      when is_map(attributes) do
    write(scope, company_id, @manage_periods, fn ->
      with {:ok, book} <- open_book_for_write(scope, company_id) do
        %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} =
          Scope.actor(scope)

        previous =
          scope
          |> fiscal_years_query(company_id)
          |> order_by([y], desc: y.start_date)
          |> limit(1)
          |> Repo.one()

        changeset =
          %FiscalYear{
            tenant_id: book.tenant_id,
            company_id: company_id,
            opened_by_user_id: user_id,
            opened_by_impersonator_id: impersonator_id
          }
          |> FiscalYear.changeset(attributes, previous)

        with {:ok, year} <- Repo.insert(changeset) do
          periods =
            for {number, first, last} <- FiscalYear.months(year) do
              %{
                tenant_id: year.tenant_id,
                company_id: company_id,
                fiscal_year_id: year.id,
                period_number: number,
                start_date: first,
                end_date: last
              }
            end

          Repo.insert_all(Period, periods)
          fiscal_year_result(scope, company_id, year.id)
        end
      end
    end)
  end

  @doc """
  The company's fiscal years in date order, each with its `status` (`open`
  or `closed`), `closing_entry_id` while closed, and its periods with
  theirs (`open`, `closed`, or `locked`).
  """
  @spec list_fiscal_years(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_fiscal_years(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok, closing_state(scope, company_id).years}
    end
  end

  @doc "One fiscal year, as `list_fiscal_years/2` shows it."
  @spec get_fiscal_year(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :fiscal_year_not_found}
  def get_fiscal_year(%Scope{} = scope, company_id, fiscal_year_id) do
    with :ok <- authorize(scope, company_id, @view) do
      fiscal_year_result(scope, company_id, fiscal_year_id)
    end
  end

  @doc """
  The fiscal year's closing log, oldest first: every close, reopen, and lock
  of the year (no `period_id`) and of its periods, with its `reason`, who
  recorded it, and when. The company's events are numbered 1, 2, 3, ...
  without gaps.
  """
  @spec list_closing_events(Scope.t(), term(), term()) ::
          {:ok, [map()]} | {:error, refusal() | :fiscal_year_not_found}
  def list_closing_events(%Scope{} = scope, company_id, fiscal_year_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, _year} <- fiscal_year_result(scope, company_id, fiscal_year_id) do
      {:ok,
       scope
       |> events_query(company_id)
       |> where([e], e.fiscal_year_id == ^fiscal_year_id)
       |> order_by([e], asc: e.event_number)
       |> Repo.all()
       |> Enum.map(&event_view/1)}
    end
  end

  @doc """
  Closes an open period, with an optional `reason`: no entry is posted into
  it until it reopens. Periods close in date order
  (`{:error, :earlier_period_open}`), and a year's last period closes only
  with the year, through `close_fiscal_year/4`
  (`{:error, :closes_with_fiscal_year}`).
  """
  @spec close_period(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :period_not_found
             | :period_not_open
             | :earlier_period_open
             | :closes_with_fiscal_year
             | Changeset.t()}
  def close_period(%Scope{} = scope, company_id, period_id, attributes \\ %{})
      when is_map(attributes) do
    write(scope, company_id, @manage_periods, fn ->
      state = closing_state(scope, company_id)

      with {:ok, period} <- find_period(state, period_id),
           {previous, _next} = neighbours(state, period),
           :ok <- closable(state, period, previous) do
        change_period(scope, company_id, period, "close", attributes)
      end
    end)
  end

  @doc """
  Reopens a closed period with a `reason`, so entries post into it again.
  This needs the privileged reopen capability. Periods reopen in reverse
  date order (`{:error, :later_period_closed}`); a locked period never
  reopens (`{:error, :period_locked}`), and a closed fiscal year's periods
  reopen only after `reopen_fiscal_year/4` (`{:error, :fiscal_year_closed}`).
  """
  @spec reopen_period(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :period_not_found
             | :period_not_closed
             | :period_locked
             | :fiscal_year_closed
             | :later_period_closed
             | Changeset.t()}
  def reopen_period(%Scope{} = scope, company_id, period_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @reopen_periods, fn ->
      state = closing_state(scope, company_id)

      with {:ok, period} <- find_period(state, period_id),
           {_previous, next} = neighbours(state, period),
           :ok <- reopenable(state, period, next),
           {:ok, reopened} <- change_period(scope, company_id, period, "reopen", attributes),
           {:ok, _exception} <- record_reopen(scope, company_id, "period", period, attributes) do
        {:ok, reopened}
      end
    end)
  end

  @doc """
  Locks a closed period for good, with an optional `reason`: it never
  reopens. Periods lock in date order (`{:error, :earlier_period_unlocked}`).
  """
  @spec lock_period(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :period_not_found
             | :period_not_closed
             | :period_locked
             | :earlier_period_unlocked
             | Changeset.t()}
  def lock_period(%Scope{} = scope, company_id, period_id, attributes \\ %{})
      when is_map(attributes) do
    write(scope, company_id, @lock_periods, fn ->
      state = closing_state(scope, company_id)

      with {:ok, period} <- find_period(state, period_id),
           {previous, _next} = neighbours(state, period),
           :ok <- lockable(period, previous) do
        change_period(scope, company_id, period, "lock", attributes)
      end
    end)
  end

  @doc """
  Closes a fiscal year. It posts the closing entry, dated the year's last
  day with an optional `description` and `reference`, that brings every
  income and expense account's balance for the year to zero against the
  company's retained-earnings account (`{:error,
  :no_retained_earnings_account}` until an active equity account is
  designated), then closes the year and every period of it still open. A
  year with no income or expense balance closes with no entry. The previous
  year must be closed first (`{:error, :earlier_period_open}`).

  The close posts an entry, so the caller needs the period-management
  capability and the entry-posting capability; missing either is
  `{:error, :unauthorized}`.

  Closing a closed year again returns it unchanged: the close is
  idempotent. Only `reopen_fiscal_year/4` undoes it.
  """
  @spec close_fiscal_year(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :book_not_open
             | :fiscal_year_not_found
             | :earlier_period_open
             | :no_retained_earnings_account
             | Changeset.t()}
  def close_fiscal_year(%Scope{} = scope, company_id, fiscal_year_id, attributes \\ %{})
      when is_map(attributes) do
    write(scope, company_id, [@manage_periods, @post_entries], fn ->
      state = closing_state(scope, company_id)

      with {:ok, book} <- open_book_for_write(scope, company_id),
           {:ok, year} <- find_year(state, fiscal_year_id) do
        if year.status == "closed",
          do: {:ok, year},
          else: close_year(scope, company_id, book, state, year, attributes)
      end
    end)
  end

  @doc """
  Reopens a closed fiscal year with a `reason`, which needs the privileged
  reopen capability and the entry-posting capability, because it posts the
  reversal (missing either is `{:error, :unauthorized}`): it reopens the
  year and its last period, and reverses the closing entry on the year's
  last day. The year's other periods stay closed until each is reopened. A year whose last period is locked never
  reopens (`{:error, :period_locked}`), and a year reopens only while the
  next year's periods are all open (`{:error, :later_period_closed}`).
  """
  @spec reopen_fiscal_year(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :book_not_open
             | :fiscal_year_not_found
             | :fiscal_year_not_closed
             | :period_locked
             | :later_period_closed
             | Changeset.t()}
  def reopen_fiscal_year(%Scope{} = scope, company_id, fiscal_year_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, [@reopen_periods, @post_entries], fn ->
      state = closing_state(scope, company_id)

      with {:ok, book} <- open_book_for_write(scope, company_id),
           {:ok, year} <- find_year(state, fiscal_year_id),
           last = List.last(year.periods),
           {_previous, next} = neighbours(state, last),
           :ok <- year_reopenable(year, last, next),
           {:ok, _event} <- record_event(scope, company_id, year, nil, "reopen", attributes),
           {:ok, _event} <- record_event(scope, company_id, year, last, "reopen", attributes),
           {:ok, _reversal} <- reverse_closing_entry(scope, company_id, book, year),
           {:ok, _exception} <- record_reopen(scope, company_id, "fiscal_year", year, attributes) do
        fiscal_year_result(scope, company_id, year.id)
      end
    end)
  end

  ## Closing

  defp close_year(scope, company_id, book, state, year, attributes) do
    open = Enum.filter(year.periods, &(&1.status == "open"))
    {previous, _next} = neighbours(state, hd(open))

    with :ok <- earlier_closed(previous),
         {:ok, account} <- retained_earnings_account(scope, company_id),
         {:ok, entry_id} <- post_closing_entry(scope, company_id, book, year, account, attributes),
         {:ok, _event} <-
           record_event(scope, company_id, year, nil, "close", %{},
             entry_id: entry_id,
             retained_earnings_account_id: account.id
           ),
         :ok <- close_each(scope, company_id, year, open) do
      fiscal_year_result(scope, company_id, year.id)
    end
  end

  defp earlier_closed(%{status: "open"}), do: {:error, :earlier_period_open}
  defp earlier_closed(_previous_or_none), do: :ok

  defp close_each(scope, company_id, year, periods) do
    Enum.reduce_while(periods, :ok, fn period, :ok ->
      case record_event(scope, company_id, year, period, "close", %{}) do
        {:ok, _event} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp retained_earnings_account(scope, company_id) do
    case designated_account(scope, company_id) do
      %Account{active: true} = account -> {:ok, account}
      _none_or_inactive -> {:error, :no_retained_earnings_account}
    end
  end

  # Each income and expense account's balance for the year, posted back to
  # zero, and the difference, the year's profit or loss, against retained
  # earnings. Earlier closing entries and their reversals cancel out.
  defp post_closing_entry(scope, company_id, book, year, account, attributes) do
    balances =
      from(l in lines_query(scope),
        join: e in ^Tenancy.scope_query(Entry, scope),
        on: e.id == l.entry_id,
        join: a in ^Tenancy.scope_query(Account, scope),
        on: a.id == l.account_id,
        where: l.company_id == ^company_id and a.account_type in ^@closed_by_year,
        where: e.entry_date >= ^year.start_date and e.entry_date <= ^year.end_date,
        group_by: [a.id, a.code],
        order_by: a.code,
        select: {a.id, sum(l.debit) - sum(l.credit)}
      )
      |> Repo.all()
      |> Enum.reject(fn {_id, net} -> Decimal.equal?(net, 0) end)

    if balances == [] do
      {:ok, nil}
    else
      profit_or_loss = Enum.reduce(balances, Decimal.new(0), &Decimal.add(elem(&1, 1), &2))

      lines =
        Enum.map(balances, fn {id, net} -> side(id, Decimal.negate(net)) end) ++
          if(Decimal.equal?(profit_or_loss, 0), do: [], else: [side(account.id, profit_or_loss)])

      entry = %{
        entry_date: year.end_date,
        description:
          fetch(attributes, :description) ||
            "Close fiscal year #{year.start_date} to #{year.end_date}",
        reference: fetch(attributes, :reference)
      }

      scope
      |> entry_changeset(book, entry, lines)
      |> validate_open_period(scope, company_id)
      |> validate_accounts(scope, company_id, :any)
      |> insert_entry(scope)
      |> case do
        {:ok, posted} -> {:ok, posted.id}
        error -> error
      end
    end
  end

  # A positive amount is a debit, a negative one a credit.
  defp side(account_id, amount) do
    if Decimal.gt?(amount, 0),
      do: %{account_id: account_id, debit: amount},
      else: %{account_id: account_id, credit: Decimal.negate(amount)}
  end

  defp reverse_closing_entry(_scope, _company_id, _book, %{closing_entry_id: nil}), do: {:ok, nil}

  defp reverse_closing_entry(scope, company_id, book, year) do
    original = entry_with_lines(scope, company_id, year.closing_entry_id)
    description = "Reopen fiscal year #{year.start_date} to #{year.end_date}"

    scope
    |> reversal_changeset(book, original, %{entry_date: year.end_date, description: description})
    |> validate_open_period(scope, company_id)
    |> validate_accounts(scope, company_id, :any)
    |> insert_entry(scope)
  end

  defp closable(_state, %{status: status}, _previous) when status != "open",
    do: {:error, :period_not_open}

  defp closable(_state, _period, %{status: "open"}), do: {:error, :earlier_period_open}

  defp closable(state, period, _previous) do
    year = Enum.find(state.years, &(&1.id == period.fiscal_year_id))

    if period.end_date == year.end_date and year.status != "closed",
      do: {:error, :closes_with_fiscal_year},
      else: :ok
  end

  defp reopenable(_state, %{status: "locked"}, _next), do: {:error, :period_locked}
  defp reopenable(_state, %{status: "open"}, _next), do: {:error, :period_not_closed}

  defp reopenable(state, period, next) do
    cond do
      Enum.find(state.years, &(&1.id == period.fiscal_year_id)).status == "closed" ->
        {:error, :fiscal_year_closed}

      next && next.status != "open" ->
        {:error, :later_period_closed}

      true ->
        :ok
    end
  end

  defp lockable(%{status: "locked"}, _previous), do: {:error, :period_locked}
  defp lockable(%{status: "open"}, _previous), do: {:error, :period_not_closed}

  defp lockable(_period, previous) do
    if previous && previous.status != "locked",
      do: {:error, :earlier_period_unlocked},
      else: :ok
  end

  defp year_reopenable(%{status: "open"}, _last, _next), do: {:error, :fiscal_year_not_closed}
  defp year_reopenable(_year, %{status: "locked"}, _next), do: {:error, :period_locked}

  defp year_reopenable(_year, _last, next) do
    if next && next.status != "open", do: {:error, :later_period_closed}, else: :ok
  end

  defp change_period(scope, company_id, period, action, attributes) do
    year = %{id: period.fiscal_year_id}

    with {:ok, _event} <- record_event(scope, company_id, year, period, action, attributes) do
      {:ok, Map.put(period, :status, ClosingEvent.status_after(action))}
    end
  end

  # A reopen overrides a close, so it is listed for independent review, with
  # the reason the closing log already holds.
  defp record_reopen(scope, company_id, subject_type, closed, attributes) do
    label = if subject_type == "period", do: "Period", else: "Fiscal year"

    Duties.check(scope, company_id, %{
      source: "finance/ledger",
      action: "#{subject_type}_reopen",
      subject_type: subject_type,
      subject_id: closed.id,
      subject: "#{label} #{closed.start_date} to #{closed.end_date}",
      prepared_by: [],
      override: true,
      reason: fetch(attributes, :reason)
    })
  end

  # The database numbers and stamps the event and refuses one that breaks
  # the closing rules (see the migration).
  defp record_event(scope, company_id, year, period, action, attributes, fields \\ []) do
    %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

    %ClosingEvent{
      tenant_id: Scope.tenant_id(scope),
      company_id: company_id,
      fiscal_year_id: year.id,
      period_id: period && period.id,
      action: action,
      recorded_by_user_id: user_id,
      recorded_by_impersonator_id: impersonator_id
    }
    |> struct(fields)
    |> ClosingEvent.changeset(attributes)
    |> Repo.insert()
  end

  # Every fiscal year and period of the company in date order, with the
  # statuses its closing events leave them in.
  defp closing_state(scope, company_id) do
    events =
      scope |> events_query(company_id) |> order_by([e], asc: e.event_number) |> Repo.all()

    period_statuses =
      for %ClosingEvent{period_id: id, action: action} <- events,
          id != nil,
          into: %{},
          do: {id, ClosingEvent.status_after(action)}

    year_events =
      for %ClosingEvent{period_id: nil} = e <- events, into: %{}, do: {e.fiscal_year_id, e}

    periods =
      scope
      |> periods_query(company_id)
      |> order_by([p], asc: p.start_date)
      |> Repo.all()
      |> Enum.map(&period_view(&1, Map.get(period_statuses, &1.id, "open")))

    years =
      scope
      |> fiscal_years_query(company_id)
      |> order_by([y], asc: y.start_date)
      |> Repo.all()
      |> Enum.map(fn year ->
        year_view(
          year,
          Map.get(year_events, year.id),
          Enum.filter(periods, &(&1.fiscal_year_id == year.id))
        )
      end)

    %{years: years, periods: periods}
  end

  defp neighbours(state, period) do
    index = Enum.find_index(state.periods, &(&1.id == period.id))
    previous = if index > 0, do: Enum.at(state.periods, index - 1)
    {previous, Enum.at(state.periods, index + 1)}
  end

  defp find_period(state, period_id) do
    case Enum.find(state.periods, &(&1.id == period_id)) do
      nil -> {:error, :period_not_found}
      period -> {:ok, period}
    end
  end

  defp find_year(state, fiscal_year_id) do
    case Enum.find(state.years, &(&1.id == fiscal_year_id)) do
      nil -> {:error, :fiscal_year_not_found}
      year -> {:ok, year}
    end
  end

  defp fiscal_year_result(scope, company_id, fiscal_year_id) do
    scope |> closing_state(company_id) |> find_year(fiscal_year_id)
  end

  # An entry dates into an open period. Once a company has fiscal years, never
  # before its first; a controlled company also needs a period covering the
  # date, which the database's rule checks too.
  defp validate_open_period(changeset, scope, company_id) do
    Changeset.validate_change(changeset, :entry_date, fn :entry_date, date ->
      period =
        scope
        |> periods_query(company_id)
        |> where([p], p.start_date <= ^date and p.end_date >= ^date)
        |> Repo.one()

      cond do
        period ->
          case period_status(scope, company_id, period.id) do
            "open" -> []
            status -> [entry_date: "falls in a #{status} period"]
          end

        scope
        |> periods_query(company_id)
        |> where([p], p.start_date > ^date)
        |> Repo.exists?() ->
          [entry_date: "is before the first fiscal year"]

        Bookkeeping.controlled?(scope, company_id) ->
          [entry_date: "falls in no fiscal period: open the fiscal year that covers it first"]

        true ->
          []
      end
    end)
  end

  defp period_status(scope, company_id, period_id) do
    scope
    |> events_query(company_id)
    |> where([e], e.period_id == ^period_id)
    |> order_by([e], desc: e.event_number)
    |> limit(1)
    |> select([e], e.action)
    |> Repo.one()
    |> ClosingEvent.status_after()
  end

  ## Trial balance

  @doc """
  The trial balance as of a date: every account with a posting on or before
  `as_of`, its debit and credit totals, and its balance on one side. The
  balance columns' totals are equal, because every posted entry balances.
  An account reports its own postings only; `parent_id` lets a reader group
  rows without counting a parent twice.

  The result names `through_entry_number`, the last entry number it counts.
  An entry posted later with an earlier date changes the figures for that
  date, so passing the same `as_of` and `through_entry_number: n` reproduces
  an earlier report's debit and credit figures (row totals and balances, and
  the totals) exactly: entries are numbered in posting order and never
  change. Account names, parents, and active flags are read as they are now.
  A malformed option is `{:error, :invalid_option}`.
  """
  @spec trial_balance(Scope.t(), term(), Date.t(), keyword()) ::
          {:ok, map()} | {:error, refusal() | :book_not_open | :invalid_option}
  def trial_balance(%Scope{} = scope, company_id, %Date{} = as_of, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, through} <- through_option(options) do
      case book(scope, company_id) do
        nil -> {:error, :book_not_open}
        book -> {:ok, build_trial_balance(scope, company_id, book, as_of, through)}
      end
    end
  end

  defp through_option(options) do
    case Keyword.get(options, :through_entry_number) do
      nil -> {:ok, nil}
      number when is_integer(number) and number in 0..@max_bigint -> {:ok, number}
      _other -> {:error, :invalid_option}
    end
  end

  defp build_trial_balance(scope, company_id, book, as_of, through) do
    through = through || last_entry_number(scope, company_id)

    rows =
      scope
      |> totals_by_account(company_id, nil, as_of, through)
      |> Enum.map(fn %{debits: debits, credits: credits} = row ->
        net = Decimal.sub(debits, credits)
        zero = Decimal.new(0)

        Map.merge(row, %{
          debit_balance: if(Decimal.gt?(net, 0), do: net, else: zero),
          credit_balance: if(Decimal.lt?(net, 0), do: Decimal.negate(net), else: zero)
        })
      end)

    %{
      company_id: company_id,
      as_of: as_of,
      through_entry_number: through,
      currency_code: book.currency_code,
      minor_units: book.minor_units,
      rows: rows,
      total_debit: sum(rows, :debit_balance),
      total_credit: sum(rows, :credit_balance)
    }
  end

  ## Posting notices

  @doc """
  Subscribes the calling process to the company's postings. After the
  transaction that posts an entry commits, the process receives
  `{:finance_ledger_posted, %{company_id: company_id, entry_number: number}}`
  for that entry, on every node; a rolled-back post sends nothing, and a
  post inside a caller's own transaction is announced when that transaction
  commits. A notice carries no figures: a subscriber reads them through this
  facade, which authorizes the read afresh. Subscribing twice is one
  subscription, and it ends with the process.
  """
  @spec subscribe_postings(Scope.t(), term()) :: :ok | {:error, refusal()}
  def subscribe_postings(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      Postings.subscribe(Scope.tenant_id(scope), company_id)
    end
  end

  ## Account totals

  @doc """
  Each account's debit and credit totals over the entries dated from `from`
  through `to` (both optional and inclusive): every account with a posting
  in that window, ordered by code. The sums are computed by PostgreSQL, one
  row per account, so a report never loads the lines themselves.

  Like `trial_balance/4`, the result names `through_entry_number`, the last
  entry it counts, and passing it back reproduces the same figures exactly.
  Several windows read with the same `through_entry_number` describe one
  state of the ledger, which is how a report keeps its columns consistent.
  Account names, parents, and active flags are read as they are now.

  `exclude_closing: true` leaves out every year-end closing entry
  (`close_fiscal_year/4`) and every reversal of one (`reopen_fiscal_year/4`),
  so income and expense over a window that ends a closed year show the
  year's activity rather than zero; a profit and loss reads this way, while
  a balance sheet counts them. A malformed option, or a `from` after `to`, is
  `{:error, :invalid_option}`.
  """
  @spec account_totals(Scope.t(), term(), keyword()) ::
          {:ok, map()} | {:error, refusal() | :book_not_open | :invalid_option}
  def account_totals(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, from, to} <- window_option(options),
         {:ok, through} <- through_option(options),
         {:ok, exclude_closing} <- exclude_closing_option(options) do
      case book(scope, company_id) do
        nil ->
          {:error, :book_not_open}

        book ->
          through = through || last_entry_number(scope, company_id)

          {:ok,
           %{
             company_id: company_id,
             from: from,
             to: to,
             through_entry_number: through,
             currency_code: book.currency_code,
             minor_units: book.minor_units,
             rows: totals_by_account(scope, company_id, from, to, through, exclude_closing)
           }}
      end
    end
  end

  @doc """
  `account_totals/3` split by who posted: for every account with a posting
  in the window, one row per owner module that posted to it, in account
  code order, each `account_totals/3`'s row with `owner_module` (the
  module's descriptor ID, or `nil` for entries with no owner) and `legacy`
  (true for entries posted before owners were recorded; a legacy entry a
  module claimed is that module's). The same options, and the same
  `through_entry_number` reproduces the same figures.

  A control account ties out when the owner module's rows are the whole
  account: any other row is a posting the owner's own records do not
  know, which `finance/receivables` and `finance/payables` show as a
  difference in their control-account tie-outs.
  """
  @spec account_totals_by_owner(Scope.t(), term(), keyword()) ::
          {:ok, map()} | {:error, refusal() | :book_not_open | :invalid_option}
  def account_totals_by_owner(%Scope{} = scope, company_id, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, from, to} <- window_option(options),
         {:ok, through} <- through_option(options),
         {:ok, exclude_closing} <- exclude_closing_option(options) do
      case book(scope, company_id) do
        nil ->
          {:error, :book_not_open}

        book ->
          through = through || last_entry_number(scope, company_id)

          {:ok,
           %{
             company_id: company_id,
             from: from,
             to: to,
             through_entry_number: through,
             currency_code: book.currency_code,
             minor_units: book.minor_units,
             rows: totals_by_owner(scope, company_id, from, to, through, exclude_closing)
           }}
      end
    end
  end

  defp window_option(options) do
    from = Keyword.get(options, :from)
    to = Keyword.get(options, :to)

    cond do
      not (optional_date?(from) and optional_date?(to)) -> {:error, :invalid_option}
      from && to && Date.compare(from, to) == :gt -> {:error, :invalid_option}
      true -> {:ok, from, to}
    end
  end

  # Sums per account in the database, joined through the entries' date and
  # number; the lines' (company_id, account_id) and (entry_id, line_number)
  # indexes and the entries' date index serve it.
  defp totals_by_account(scope, company_id, from, to, through, exclude_closing \\ false) do
    entries =
      scope
      |> entries_query(company_id)
      |> date_bound(:from, from)
      |> date_bound(:to, to)
      |> through_bound(through)
      |> closing_bound(scope, company_id, exclude_closing)

    totals =
      from(l in lines_query(scope),
        join: e in subquery(select(entries, [e], %{id: e.id})),
        on: e.id == l.entry_id,
        where: l.company_id == ^company_id,
        group_by: l.account_id,
        select: {l.account_id, {sum(l.debit), sum(l.credit)}}
      )
      |> Repo.all()
      |> Map.new()

    scope
    |> accounts_query(company_id)
    |> where([a], a.id in ^Map.keys(totals))
    |> order_by([a], asc: a.code)
    |> Repo.all()
    |> Enum.map(fn account ->
      {debits, credits} = Map.fetch!(totals, account.id)
      account |> account_view() |> Map.merge(%{debits: debits, credits: credits})
    end)
  end

  # The same sums, grouped by the entries' owner module and legacy flag.
  defp totals_by_owner(scope, company_id, from, to, through, exclude_closing) do
    entries =
      scope
      |> entries_query(company_id)
      |> date_bound(:from, from)
      |> date_bound(:to, to)
      |> through_bound(through)
      |> closing_bound(scope, company_id, exclude_closing)

    totals =
      from(l in lines_query(scope),
        join:
          e in subquery(
            select(entries, [e], %{id: e.id, owner_module: e.owner_module, legacy: e.legacy})
          ),
        on: e.id == l.entry_id,
        where: l.company_id == ^company_id,
        group_by: [l.account_id, e.owner_module, e.legacy],
        select: {l.account_id, {e.owner_module, e.legacy, sum(l.debit), sum(l.credit)}}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    scope
    |> accounts_query(company_id)
    |> where([a], a.id in ^Map.keys(totals))
    |> order_by([a], asc: a.code)
    |> Repo.all()
    |> Enum.flat_map(fn account ->
      totals
      |> Map.fetch!(account.id)
      |> Enum.sort_by(fn {module, legacy, _debits, _credits} -> {module || "", legacy} end)
      |> Enum.map(fn {module, legacy, debits, credits} ->
        account
        |> account_view()
        |> Map.merge(%{owner_module: module, legacy: legacy, debits: debits, credits: credits})
      end)
    end)
  end

  defp last_entry_number(scope, company_id) do
    scope
    |> entries_query(company_id)
    |> select([e], coalesce(max(e.entry_number), 0))
    |> Repo.one()
  end

  defp sum(rows, field),
    do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(Map.fetch!(&1, field), &2))

  ## Authorization and writes

  # The actor's current grant and company reach decide every call.
  defp authorize(scope, company_id, capability) do
    case Company.authorize_company_target(scope, company_id, capability) do
      {:ok, _company} -> :ok
      {:error, :not_found} -> {:error, :company_not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  defp authorize_all(scope, company_id, capabilities) do
    Enum.reduce_while(capabilities, :ok, fn capability, :ok ->
      case authorize(scope, company_id, capability) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp write(scope, company_id, capabilities, fun) do
    with :ok <- authorize_all(scope, company_id, List.wrap(capabilities)) do
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

  ## Entries

  defp open_book_for_write(scope, company_id) do
    case book(scope, company_id) do
      nil -> {:error, :book_not_open}
      book -> {:ok, book}
    end
  end

  defp entry_changeset(scope, book, attributes, lines) do
    %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

    line_changesets =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, number} ->
        %Line{
          tenant_id: book.tenant_id,
          company_id: book.company_id,
          line_number: number
        }
        |> Line.changeset(if(is_map(line), do: line, else: %{}), book.minor_units)
      end)

    %Entry{
      tenant_id: book.tenant_id,
      company_id: book.company_id,
      currency_code: book.currency_code,
      posted_by_user_id: user_id,
      posted_by_impersonator_id: impersonator_id
    }
    |> Entry.changeset(attributes)
    |> Changeset.put_assoc(:lines, line_changesets)
    |> validate_balance(line_changesets)
  end

  defp validate_balance(changeset, lines) do
    cond do
      length(lines) < 2 ->
        Changeset.add_error(changeset, :lines, "needs at least two lines")

      not Enum.all?(lines, & &1.valid?) ->
        changeset

      Decimal.equal?(line_total(lines, :debit), line_total(lines, :credit)) ->
        changeset

      true ->
        Changeset.add_error(changeset, :lines, "debits and credits do not balance")
    end
  end

  defp line_total(lines, field) do
    Enum.reduce(lines, Decimal.new(0), &Decimal.add(Changeset.get_field(&1, field), &2))
  end

  # Every line must name an account of this company; a new posting also
  # needs it active, except the accounts `inactive_ok` lists (`:any` for a
  # reversal or a closing entry). The company lock serializes this with
  # deactivation.
  defp validate_accounts(changeset, scope, company_id, inactive_ok) do
    lines = Changeset.get_change(changeset, :lines, [])

    ids =
      lines
      |> Enum.map(&Changeset.get_field(&1, :account_id))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    accounts =
      scope
      |> accounts_query(company_id)
      |> where([a], a.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    checked = Enum.map(lines, &check_account(&1, accounts, inactive_ok))

    changeset
    |> Map.update!(:changes, &Map.put(&1, :lines, checked))
    |> Map.update!(:valid?, &(&1 and Enum.all?(checked, fn line -> line.valid? end)))
  end

  defp check_account(line, accounts, inactive_ok) do
    account_id = Changeset.get_field(line, :account_id)

    case Map.get(accounts, account_id) do
      nil when is_integer(account_id) ->
        Changeset.add_error(line, :account_id, "is not an account of this company")

      %Account{active: false} ->
        if inactive_ok == :any or account_id in inactive_ok,
          do: line,
          else: Changeset.add_error(line, :account_id, "is inactive")

      _account ->
        line
    end
  end

  # Read back what PostgreSQL stored, so the result equals `get_entry/3`'s.
  defp insert_entry(changeset, scope) do
    with {:ok, entry} <- Repo.insert(changeset) do
      {:ok, entry_view(entry_with_lines(scope, entry.company_id, entry.id), %{})}
    end
  end

  defp reversible_entry(scope, company_id, entry_id) do
    case entry_with_lines(scope, company_id, entry_id) do
      nil ->
        {:error, :entry_not_found}

      %Entry{reverses_entry_id: reversed} when not is_nil(reversed) ->
        {:error, :reversal_not_reversible}

      entry ->
        cond do
          reversed_by(scope, company_id, [entry.id]) != %{} -> {:error, :already_reversed}
          closing_entry?(scope, company_id, entry.id) -> {:error, :closing_entry}
          true -> {:ok, entry}
        end
    end
  end

  defp closing_entry?(scope, company_id, entry_id) do
    scope |> events_query(company_id) |> where([e], e.entry_id == ^entry_id) |> Repo.exists?()
  end

  ## Queries

  defp book(scope, company_id) when is_integer(company_id) do
    Repo.one(from(b in Tenancy.scope_query(Book, scope), where: b.company_id == ^company_id))
  end

  defp accounts_query(scope, company_id) do
    from(a in Tenancy.scope_query(Account, scope), where: a.company_id == ^company_id)
  end

  defp account(scope, company_id, account_id) when is_integer(account_id) do
    scope |> accounts_query(company_id) |> where([a], a.id == ^account_id) |> Repo.one()
  end

  defp account(_scope, _company_id, _account_id), do: nil

  defp entries_query(scope, company_id) do
    from(e in Tenancy.scope_query(Entry, scope), where: e.company_id == ^company_id)
  end

  defp lines_query(scope), do: Tenancy.scope_query(Line, scope)

  defp fiscal_years_query(scope, company_id) do
    from(y in Tenancy.scope_query(FiscalYear, scope), where: y.company_id == ^company_id)
  end

  defp periods_query(scope, company_id) do
    from(p in Tenancy.scope_query(Period, scope), where: p.company_id == ^company_id)
  end

  defp events_query(scope, company_id) do
    from(e in Tenancy.scope_query(ClosingEvent, scope), where: e.company_id == ^company_id)
  end

  defp ordered_lines(scope), do: order_by(lines_query(scope), [l], asc: l.line_number)

  defp entry_with_lines(scope, company_id, entry_id) when is_integer(entry_id) do
    scope
    |> entries_query(company_id)
    |> where([e], e.id == ^entry_id)
    |> preload(lines: ^ordered_lines(scope))
    |> Repo.one()
  end

  defp entry_with_lines(_scope, _company_id, _entry_id), do: nil

  defp reversed_by(_scope, _company_id, []), do: %{}

  defp reversed_by(scope, company_id, entry_ids) do
    scope
    |> entries_query(company_id)
    |> where([e], e.reverses_entry_id in ^entry_ids)
    |> select([e], {e.reverses_entry_id, e.id})
    |> Repo.all()
    |> Map.new()
  end

  defp date_bound(query, _bound, nil), do: query
  defp date_bound(query, :from, %Date{} = date), do: where(query, [e], e.entry_date >= ^date)
  defp date_bound(query, :to, %Date{} = date), do: where(query, [e], e.entry_date <= ^date)

  defp through_bound(query, nil), do: query
  defp through_bound(query, through), do: where(query, [e], e.entry_number <= ^through)

  defp account_bound(query, _scope, _company_id, nil), do: query

  # The lines' (company_id, account_id) index finds the account's entries.
  defp account_bound(query, scope, company_id, account_id) do
    entry_ids =
      scope
      |> lines_query()
      |> where([l], l.company_id == ^company_id and l.account_id == ^account_id)
      |> select([l], l.entry_id)

    where(query, [e], e.id in subquery(entry_ids))
  end

  defp closing_bound(query, _scope, _company_id, false), do: query

  # A year's close event names its closing entry in the same transaction that
  # posts it, so the set is the same at any `through_entry_number`; a reopen
  # posts the entry's reversal, which names it in `reverses_entry_id`.
  defp closing_bound(query, scope, company_id, true) do
    closing_ids =
      from(c in Tenancy.scope_query(ClosingEvent, scope),
        where: c.company_id == ^company_id and not is_nil(c.entry_id),
        select: c.entry_id
      )

    where(
      query,
      [e],
      e.id not in subquery(closing_ids) and
        (is_nil(e.reverses_entry_id) or e.reverses_entry_id not in subquery(closing_ids))
    )
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {date, id}),
    do: where(query, [e], e.entry_date > ^date or (e.entry_date == ^date and e.id > ^id))

  defp fetch(attributes, key), do: Map.get(attributes, key, Map.get(attributes, to_string(key)))

  ## Views

  defp book_view(book), do: Map.take(book, [:company_id, :currency_code, :minor_units])

  defp account_view(account),
    do:
      Map.take(account, [
        :id,
        :code,
        :name,
        :account_type,
        :parent_id,
        :active,
        :retained_earnings
      ])

  defp entry_view(entry, reversals) do
    entry
    |> Map.take([
      :id,
      :entry_number,
      :entry_date,
      :description,
      :reference,
      :currency_code,
      :reverses_entry_id,
      :legacy,
      :posted_by_user_id,
      :posted_by_impersonator_id,
      :posted_at
    ])
    |> Map.put(:owner, owner_view(entry))
    |> Map.put(:reversed_by_entry_id, Map.get(reversals, entry.id))
    |> Map.put(
      :lines,
      Enum.map(
        entry.lines,
        &Map.take(&1, [:line_number, :account_id, :debit, :credit, :description])
      )
    )
  end

  defp owner_view(%{owner_module: nil}), do: nil

  defp owner_view(%{owner_module: module, owner_record: record}),
    do: %{module: module, record: record}

  defp year_view(year, latest_event, periods) do
    closed = match?(%ClosingEvent{action: "close"}, latest_event)

    year
    |> Map.take([
      :id,
      :start_date,
      :end_date,
      :opened_by_user_id,
      :opened_by_impersonator_id,
      :opened_at
    ])
    |> Map.merge(%{
      status: if(closed, do: "closed", else: "open"),
      closing_entry_id: if(closed, do: latest_event.entry_id),
      periods: periods
    })
  end

  defp period_view(period, status) do
    period
    |> Map.take([:id, :fiscal_year_id, :period_number, :start_date, :end_date])
    |> Map.put(:status, status)
  end

  defp controlled_view(scope, company_id) do
    latest = Bookkeeping.latest_change(scope, company_id)

    %{
      controlled: BookkeepingChange.controlled?(latest),
      change: latest && bookkeeping_change_view(latest),
      fiscal_years: length(closing_state(scope, company_id).years)
    }
  end

  defp bookkeeping_change_view(change) do
    Map.take(change, [
      :id,
      :change_number,
      :controlled,
      :reason,
      :changed_by_user_id,
      :changed_by_impersonator_id,
      :changed_at
    ])
  end

  defp late_recording_view(%{entry: entry, review: review}) do
    days = LateRecordings.days(entry)

    entry
    |> Map.take([
      :entry_number,
      :entry_date,
      :description,
      :reference,
      :posted_by_user_id,
      :posted_by_impersonator_id,
      :posted_at
    ])
    |> Map.merge(%{
      entry_id: entry.id,
      days: days,
      status: LateRecordings.status(days),
      review: review && late_review_view(review)
    })
  end

  defp late_review_view(review) do
    Map.take(review, [
      :id,
      :entry_id,
      :reason,
      :reviewed_by_user_id,
      :reviewed_by_impersonator_id,
      :reviewed_at
    ])
  end

  defp duty_separation_view(latest) do
    %{
      required: DutySeparationChange.required?(latest),
      change: latest && change_view(latest)
    }
  end

  defp change_view(change) do
    Map.take(change, [
      :id,
      :change_number,
      :required,
      :reason,
      :changed_by_user_id,
      :changed_by_impersonator_id,
      :changed_at
    ])
  end

  defp exception_view(exception) do
    exception
    |> Map.take([
      :id,
      :exception_number,
      :source,
      :action,
      :subject_type,
      :subject_id,
      :subject,
      :same_person,
      :override,
      :prepared_by_user_id,
      :prepared_by_impersonator_id,
      :approved_by_user_id,
      :approved_by_impersonator_id,
      :reason,
      :separation_change_id,
      :recorded_at
    ])
    |> Map.put(
      :review,
      exception.review &&
        Map.take(exception.review, [
          :note,
          :reviewed_by_user_id,
          :reviewed_by_impersonator_id,
          :reviewed_at
        ])
    )
  end

  defp journal_view(journal) do
    journal
    |> Map.take([
      :id,
      :journal_number,
      :entry_date,
      :description,
      :reference,
      :currency_code,
      :submitted_by_user_id,
      :submitted_by_impersonator_id,
      :submitted_at
    ])
    |> Map.merge(%{
      status: Journal.status(journal),
      decision:
        journal.event &&
          Map.take(journal.event, [
            :event,
            :reason,
            :entry_id,
            :actor_user_id,
            :actor_impersonator_id,
            :occurred_at
          ]),
      lines:
        Enum.map(
          journal.lines,
          &Map.take(&1, [:line_number, :account_id, :debit, :credit, :description])
        )
    })
  end

  defp event_view(event) do
    Map.take(event, [
      :event_number,
      :fiscal_year_id,
      :period_id,
      :action,
      :reason,
      :entry_id,
      :retained_earnings_account_id,
      :recorded_by_user_id,
      :recorded_by_impersonator_id,
      :recorded_at
    ])
  end

  ## Accounts

  defp validate_deactivation(changeset, scope, company_id) do
    with false <- Changeset.get_change(changeset, :active),
         balance = account_balance(scope, company_id, changeset.data.id),
         false <- Decimal.eq?(balance, 0) do
      %Book{minor_units: minor_units} = book(scope, company_id)
      shown = balance |> Decimal.abs() |> Decimal.round(minor_units) |> Decimal.to_string(:normal)

      Changeset.add_error(
        changeset,
        :active,
        "account #{changeset.data.code} has a balance of #{shown}; " <>
          "it can be deactivated once its balance is zero"
      )
    else
      _no_problem -> changeset
    end
  end

  defp account_balance(scope, company_id, account_id) do
    {debits, credits} =
      from(l in lines_query(scope),
        where: l.company_id == ^company_id and l.account_id == ^account_id,
        select:
          {type(coalesce(sum(l.debit), 0), :decimal), type(coalesce(sum(l.credit), 0), :decimal)}
      )
      |> Repo.one()

    Decimal.sub(debits, credits)
  end

  # One account carries the retained-earnings designation: designating
  # another releases the current one first, in the same transaction.
  defp save_account(changeset, scope, company_id, save) do
    with :ok <- release_designation(changeset, scope, company_id) do
      changeset |> save.() |> public_result(&account_view/1)
    end
  end

  defp release_designation(changeset, scope, company_id) do
    current = if changeset.valid?, do: designated_account(scope, company_id)

    cond do
      Changeset.get_change(changeset, :retained_earnings) != true -> :ok
      is_nil(current) or current.id == changeset.data.id -> :ok
      true -> current |> Changeset.change(retained_earnings: false) |> Repo.update() |> ok()
    end
  end

  defp designated_account(scope, company_id) do
    scope |> accounts_query(company_id) |> where([a], a.retained_earnings) |> Repo.one()
  end

  defp ok({:ok, _result}), do: :ok
  defp ok(error), do: error

  # A parent groups accounts of its own type, in this company, without a cycle.
  defp validate_parent(changeset, scope, company_id) do
    Changeset.validate_change(changeset, :parent_id, fn :parent_id, parent_id ->
      type = Changeset.get_field(changeset, :account_type)

      case account(scope, company_id, parent_id) do
        nil ->
          [parent_id: "is not an account of this company"]

        %Account{account_type: ^type} = parent ->
          if cycle?(scope, company_id, parent, changeset.data.id),
            do: [parent_id: "would place the account under itself"],
            else: []

        %Account{} ->
          [parent_id: "must have the same account type"]
      end
    end)
  end

  defp cycle?(_scope, _company_id, _parent, nil), do: false
  defp cycle?(_scope, _company_id, %Account{id: id}, id), do: true
  defp cycle?(_scope, _company_id, %Account{parent_id: nil}, _id), do: false

  defp cycle?(scope, company_id, %Account{parent_id: parent_id}, id),
    do: cycle?(scope, company_id, account(scope, company_id, parent_id), id)
end
