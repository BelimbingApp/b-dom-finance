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
  their credits, every line names an active account of the company, and the
  book is open. A posted entry is never edited or deleted; `reverse_entry/4`
  posts its mirror image, once. The database refuses the same things on its
  own, including adding a line to an entry posted in an earlier transaction
  (see the migration), so no other writer can break them either.

  Results are plain maps; the schemas stay private to this module.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Ledger.{Account, Book, Entry, Line}
  alias Ecto.Changeset

  @view "finance.ledger.view"
  @manage_accounts "finance.ledger.accounts.manage"
  @post_entries "finance.ledger.entries.post"

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
        %Book{tenant_id: Scope.tenant_id(scope), company_id: company_id}
        |> Book.changeset(attributes)
        |> Repo.insert()
        |> public_result(&book_view/1)
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
  same type to group it under, and `active`.
  """
  @spec create_account(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def create_account(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_accounts, fn ->
      %Account{tenant_id: Scope.tenant_id(scope), company_id: company_id}
      |> Account.create_changeset(attributes)
      |> validate_parent(scope, company_id)
      |> Repo.insert()
      |> public_result(&account_view/1)
    end)
  end

  @doc """
  Changes an account's `name`, `parent_id`, or `active` flag. Its code and
  type never change. A deactivated account takes no new postings; its
  history and reversals of it stay.
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
          |> Repo.update()
          |> public_result(&account_view/1)
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
  lines, its debits equal its credits, and every line names an active
  account of the company with one positive amount no finer than the book's
  minor units. `{:error, :book_not_open}` before the book is opened.
  """
  @spec post_entry(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :book_not_open | Changeset.t()}
  def post_entry(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @post_entries, fn ->
      with {:ok, book} <- open_book_for_write(scope, company_id) do
        lines = attributes |> fetch(:lines) |> List.wrap()

        scope
        |> entry_changeset(book, Map.drop(attributes, [:lines, "lines"]), lines)
        |> validate_accounts(scope, company_id, :active)
        |> insert_entry(scope)
      end
    end)
  end

  @doc """
  Posts the reversal of a posted entry on `entry_date` (not before the
  original's) with `description`: the same accounts and amounts with debits
  and credits swapped. An entry is reversed at most once
  (`{:error, :already_reversed}`), and a reversal is not itself reversed
  (`{:error, :reversal_not_reversible}`); post a new entry instead. Accounts
  deactivated since the original still take its reversal.
  """
  @spec reverse_entry(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :entry_not_found
             | :already_reversed
             | :reversal_not_reversible
             | Changeset.t()}
  def reverse_entry(%Scope{} = scope, company_id, entry_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @post_entries, fn ->
      with {:ok, book} <- open_book_for_write(scope, company_id),
           {:ok, original} <- reversible_entry(scope, company_id, entry_id) do
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
        |> entry_changeset(book, Map.drop(attributes, [:lines, "lines"]), lines)
        |> Changeset.put_change(:reverses_entry_id, original.id)
        |> Changeset.validate_change(:entry_date, fn :entry_date, date ->
          if Date.compare(date, original.entry_date) == :lt,
            do: [entry_date: "cannot be before the reversed entry's date"],
            else: []
        end)
        |> validate_accounts(scope, company_id, :any)
        |> insert_entry(scope)
      end
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
  A malformed option is `{:error, :invalid_option}`.
  """
  @spec list_entries(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_entries(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, limit, from, to, cursor} <- entry_options(options) do
      entries =
        scope
        |> entries_query(company_id)
        |> date_bound(:from, from)
        |> date_bound(:to, to)
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

  defp optional_date?(value), do: is_nil(value) or match?(%Date{}, value)

  defp valid_cursor?(nil), do: true
  defp valid_cursor?({%Date{}, id}), do: is_integer(id) and id in 1..@max_bigint
  defp valid_cursor?(_cursor), do: false

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

    totals =
      from(l in lines_query(scope),
        join: e in ^Tenancy.scope_query(Entry, scope),
        on: e.id == l.entry_id,
        where: l.company_id == ^company_id and e.entry_date <= ^as_of,
        where: e.entry_number <= ^through,
        group_by: l.account_id,
        select: {l.account_id, {sum(l.debit), sum(l.credit)}}
      )
      |> Repo.all()
      |> Map.new()

    rows =
      scope
      |> accounts_query(company_id)
      |> where([a], a.id in ^Map.keys(totals))
      |> order_by([a], asc: a.code)
      |> Repo.all()
      |> Enum.map(fn account ->
        {debits, credits} = Map.fetch!(totals, account.id)
        net = Decimal.sub(debits, credits)
        zero = Decimal.new(0)

        account
        |> account_view()
        |> Map.merge(%{
          debits: debits,
          credits: credits,
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
  # needs it active. The company lock serializes this with deactivation.
  defp validate_accounts(changeset, scope, company_id, requirement) do
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

    checked = Enum.map(lines, &check_account(&1, accounts, requirement))

    changeset
    |> Map.update!(:changes, &Map.put(&1, :lines, checked))
    |> Map.update!(:valid?, &(&1 and Enum.all?(checked, fn line -> line.valid? end)))
  end

  defp check_account(line, accounts, requirement) do
    account_id = Changeset.get_field(line, :account_id)

    case Map.get(accounts, account_id) do
      nil when is_integer(account_id) ->
        Changeset.add_error(line, :account_id, "is not an account of this company")

      %Account{active: false} when requirement == :active ->
        Changeset.add_error(line, :account_id, "is inactive")

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
        if reversed_by(scope, company_id, [entry.id]) == %{},
          do: {:ok, entry},
          else: {:error, :already_reversed}
    end
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

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {date, id}),
    do: where(query, [e], e.entry_date > ^date or (e.entry_date == ^date and e.id > ^id))

  defp fetch(attributes, key), do: Map.get(attributes, key, Map.get(attributes, to_string(key)))

  ## Views

  defp book_view(book), do: Map.take(book, [:company_id, :currency_code, :minor_units])

  defp account_view(account),
    do: Map.take(account, [:id, :code, :name, :account_type, :parent_id, :active])

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
      :posted_by_user_id,
      :posted_by_impersonator_id,
      :posted_at
    ])
    |> Map.put(:reversed_by_entry_id, Map.get(reversals, entry.id))
    |> Map.put(
      :lines,
      Enum.map(
        entry.lines,
        &Map.take(&1, [:line_number, :account_id, :debit, :credit, :description])
      )
    )
  end

  ## Accounts

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
