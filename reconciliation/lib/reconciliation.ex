defmodule Bilimbi.Finance.Reconciliation do
  @moduledoc """
  Bank reconciliation: a company's bank accounts, each mapped to a ledger
  account; the bank statements imported for them; the matches between
  statement lines and ledger entries; and the reconciliations that show, as
  of a statement end date, the statement balance, the book balance, what is
  unmatched on each side, and the difference.

  Every function takes the validated `Bilimbi.Base.Tenancy.Scope` it was
  handed and an explicit company ID. Reads authorize
  `finance.reconciliation.view` and writes their own capability for the
  scope's signed-in actor and the target company at the moment they run,
  through `Bilimbi.Core.Company.authorize_company_target/3`: a system scope,
  a missing grant, or a sibling company without tenant-wide reach is
  `{:error, :unauthorized}`, and a company the scope cannot see is
  `{:error, :company_not_found}`. A write then holds
  `Bilimbi.Core.Company.lock_writable_company/2` for its transaction, so an
  archived company is `{:error, :company_archived}` and the company's
  reconciliation writes run one at a time.

  The ledger is read and posted to only through `Bilimbi.Finance.Ledger`'s
  facade with the same scope, so a call that reads the chart, the book, or
  the account's entries also needs `finance.ledger.view`, and posting a
  statement line needs `finance.ledger.entries.post`.

  A statement and its lines are immutable once imported, and the same file
  or line is refused a second time. A match is undone only by an
  `unmatched` event with a reason, and never once a finalised
  reconciliation counted it. A reconciliation is finalised only when its
  difference is zero; it then keeps its figures, the items that explained
  them, and the entry, statement, and match-event numbers that reproduce
  them. Nothing is deleted; the database refuses the same things on its own
  (see the migration).

  Results are plain maps; the schemas stay private to this module.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Ledger

  alias Bilimbi.Finance.Reconciliation.{
    BankAccounts,
    Import,
    Mapping,
    Matching,
    Posting,
    Reconciliations,
    Records,
    Statement,
    StatementLine
  }

  alias Ecto.Changeset

  @view "finance.reconciliation.view"
  @manage_bank_accounts "finance.reconciliation.bank-accounts.manage"
  @import_statements "finance.reconciliation.statements.import"
  @manage_matches "finance.reconciliation.matches.manage"
  @manage_reconciliations "finance.reconciliation.reconciliations.manage"
  @finalise_reconciliations "finance.reconciliation.reconciliations.finalise"
  @post_statement_lines "finance.reconciliation.statement-lines.post"

  @type refusal :: :unauthorized | :company_not_found
  @type write_refusal :: refusal() | :company_archived

  @doc "The capability every reconciliation read asks for."
  def view_capability, do: @view

  @doc "The capability that adds and changes bank accounts."
  def manage_bank_accounts_capability, do: @manage_bank_accounts

  @doc "The capability that imports statements."
  def import_statements_capability, do: @import_statements

  @doc "The capability that matches and unmatches."
  def manage_matches_capability, do: @manage_matches

  @doc "The capability that opens and abandons reconciliations."
  def manage_reconciliations_capability, do: @manage_reconciliations

  @doc "The capability that finalises a reconciliation."
  def finalise_reconciliations_capability, do: @finalise_reconciliations

  @doc "The capability that posts a statement line as a charge or interest."
  def post_statement_lines_capability, do: @post_statement_lines

  @doc "The choices an import mapping is built from (see `Bilimbi.Finance.Reconciliation.Mapping`)."
  def mapping_choices do
    %{
      delimiters: Mapping.delimiters(),
      date_formats: Mapping.date_formats(),
      amount_signs: Mapping.amount_signs(),
      decimal_separators: Mapping.decimal_separators()
    }
  end

  @doc "The kinds a statement line is posted as: `charge` or `interest`."
  def posting_kinds, do: Posting.kinds()

  ## Bank accounts

  @doc "The company's bank accounts by name, active or not."
  @spec list_bank_accounts(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_bank_accounts(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view),
         do: {:ok, scope |> BankAccounts.list(company_id) |> Enum.map(&BankAccounts.view/1)}
  end

  @doc "One bank account."
  @spec get_bank_account(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :bank_account_not_found}
  def get_bank_account(%Scope{} = scope, company_id, bank_account_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, account} <- bank_account(scope, company_id, bank_account_id),
         do: {:ok, BankAccounts.view(account)}
  end

  @doc """
  Adds a bank account: `name`, `ledger_account_id` (an active asset account
  of the company no other bank account maps), `import_mapping` (see
  `Bilimbi.Finance.Reconciliation.Mapping`), and optionally
  `charges_account_id` (an expense account bank charges post to),
  `interest_account_id` (an income account interest posts to),
  `match_window_days` (0 to 90, default 5, how far apart a suggested match's
  dates may be), `active`, and a `reason` for the change log. Reads the
  chart through the ledger, so it also needs `finance.ledger.view`.
  """
  @spec create_bank_account(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def create_bank_account(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_bank_accounts, fn ->
      BankAccounts.create(scope, company_id, attributes)
    end)
  end

  @doc """
  Changes a bank account's `name`, `charges_account_id`,
  `interest_account_id`, `match_window_days`, `import_mapping`, or `active`,
  with an optional `reason`; its ledger account never changes. Every change
  is logged (`list_bank_account_changes/4`).
  """
  @spec update_bank_account(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :bank_account_not_found | Changeset.t()}
  def update_bank_account(%Scope{} = scope, company_id, bank_account_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_bank_accounts, fn ->
      with {:ok, account} <- bank_account(scope, company_id, bank_account_id),
           do: BankAccounts.update(scope, company_id, account, attributes)
    end)
  end

  @doc """
  The bank account's change log, oldest first: `%{id, field, old_value,
  new_value, reason, changed_by_user_id, changed_by_impersonator_id,
  changed_at}`. Options `limit` (1 to 500, default 100) and `after`, the
  last ID already read; a malformed option is `{:error, :invalid_option}`.
  """
  @spec list_bank_account_changes(Scope.t(), term(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :bank_account_not_found | :invalid_option}
  def list_bank_account_changes(%Scope{} = scope, company_id, bank_account_id, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, account} <- bank_account(scope, company_id, bank_account_id),
         do: BankAccounts.list_changes(scope, company_id, account.id, options)
  end

  ## Statements

  @doc """
  Imports a bank statement: `file_name` and `content`, the CSV file's bytes,
  read through the bank account's import mapping into a numbered,
  immutable statement with its lines. Needs `finance.ledger.view` for the
  book's currency precision.

  Refused whole with `{:error, {:duplicate_file, statement_number}}` for a
  file already imported, `{:error, {:duplicate_lines, [...]}}` naming each
  line already imported (by this file's row and the statement and line that
  hold it), `{:error, {:invalid_lines, [%{row, message}]}}` for rows the
  mapping cannot read, `{:error, {:missing_headers, [...]}}`,
  `{:error, :no_lines}`, `{:error, {:too_many_lines, max}}`,
  `{:error, {:running_balance_mismatch, row}}` when the balance column does
  not follow from the amounts in either direction, and the reader's
  `{:error, :too_large}`, `{:error, :not_utf8}`, and `{:error, {:stray_quote |
  :unterminated_quote, row}}`. A row whose amount is zero is skipped and
  counted in `skipped_count`.
  """
  @spec import_statement(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :bank_account_not_found
             | :bank_account_inactive
             | :book_not_open
             | term()}
  def import_statement(%Scope{} = scope, company_id, bank_account_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @import_statements, fn ->
      with {:ok, account} <- active_bank_account(scope, company_id, bank_account_id),
           {:ok, book} <- Ledger.get_book(scope, company_id),
           do: Import.import_statement(scope, company_id, account, book, attributes)
    end)
  end

  @doc "The bank account's statements, oldest first, without their lines; `limit` and `after` page them."
  @spec list_statements(Scope.t(), term(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :bank_account_not_found | :invalid_option}
  def list_statements(%Scope{} = scope, company_id, bank_account_id, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, account} <- bank_account(scope, company_id, bank_account_id),
         {:ok, limit, cursor} <- Records.page_options(options) do
      statements =
        Records.query(Statement, scope, company_id)
        |> where([s], s.bank_account_id == ^account.id)
        |> Records.page(limit, cursor)
        |> Repo.all()
        |> Enum.map(&Import.statement_view/1)

      {:ok, statements}
    end
  end

  @doc "One statement with its lines in line order."
  @spec get_statement(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :statement_not_found}
  def get_statement(%Scope{} = scope, company_id, statement_id) do
    with :ok <- authorize(scope, company_id, @view),
         statement when not is_nil(statement) <-
           Records.query(Statement, scope, company_id)
           |> where([s], s.id == ^(Records.id(statement_id) || 0))
           |> preload(lines: ^Import.ordered_lines(scope, company_id))
           |> Repo.one() do
      {:ok, Import.statement_view(statement)}
    else
      nil -> {:error, :statement_not_found}
      error -> error
    end
  end

  ## Matching

  @doc """
  What stands unmatched on the bank account: `lines`, its statement lines
  with no standing match (each with its `statement_number`); `entries`, the
  entries on its ledger account with none (`%{entry_id, entry_number,
  entry_date, description, reference, amount}`, the amount being the entry's
  debits less credits on that account); and `suggestions`, a map from a
  line's ID to the entry of the same amount within the account's match
  window, by reference and then nearest date, each entry suggested once.
  Option `to` keeps both sides through a date. Reads the ledger, so it also
  needs `finance.ledger.view`.
  """
  @spec unmatched_items(Scope.t(), term(), term(), keyword()) ::
          {:ok, map()} | {:error, refusal() | :bank_account_not_found | :invalid_option}
  def unmatched_items(%Scope{} = scope, company_id, bank_account_id, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, account} <- bank_account(scope, company_id, bank_account_id),
         {:ok, to} <- date_option(options, :to),
         {:ok, unmatched} <- Matching.unmatched(scope, company_id, account, to: to) do
      {:ok,
       Map.put(
         unmatched,
         :suggestions,
         Matching.suggestions(unmatched.lines, unmatched.entries, account.match_window_days)
       )}
    end
  end

  defp date_option(options, key) do
    case Keyword.get(options, key) do
      nil -> {:ok, nil}
      %Date{} = date -> {:ok, date}
      _other -> {:error, :invalid_option}
    end
  end

  @doc """
  Matches `statement_line_ids` of the bank account with `entry_ids` on its
  ledger account, one or many on each side, with an optional `note`. Both
  sides must be unmatched and sum to the same amount
  (`{:error, {:unbalanced, statement_side, ledger_side}}`); other refusals
  are `:invalid_selection`, `:statement_line_not_found`,
  `:statement_line_matched`, `:entry_not_found`, `:entry_not_on_account`,
  and `:entry_matched`. Reads the entries through the ledger, so it also
  needs `finance.ledger.view`.
  """
  @spec match(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error, write_refusal() | :bank_account_not_found | Changeset.t() | term()}
  def match(%Scope{} = scope, company_id, bank_account_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_matches, fn ->
      with {:ok, account} <- bank_account(scope, company_id, bank_account_id),
           do: Matching.match(scope, company_id, account, attributes)
    end)
  end

  @doc """
  Unmatches a standing match with a `reason`, as an appended event: its
  lines and entries are unmatched again. A match that is not standing is
  `{:error, :match_not_standing}`, and one a finalised reconciliation
  counted is kept (`{:error, :match_finalised}`).
  """
  @spec unmatch(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :match_not_found
             | :match_not_standing
             | :match_finalised
             | Changeset.t()}
  def unmatch(%Scope{} = scope, company_id, match_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_matches, fn ->
      case Matching.fetch(scope, company_id, Records.id(match_id) || 0) do
        nil -> {:error, :match_not_found}
        match -> Matching.unmatch(scope, company_id, match, attributes)
      end
    end)
  end

  @doc "One match with its `status`, `statement_line_ids`, `entries`, and `events`."
  @spec get_match(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :match_not_found}
  def get_match(%Scope{} = scope, company_id, match_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case Matching.fetch(scope, company_id, Records.id(match_id) || 0) do
        nil -> {:error, :match_not_found}
        match -> {:ok, Matching.match_view(match)}
      end
    end
  end

  @doc "The bank account's matches, standing or not, oldest first; `limit` and `after` page them."
  @spec list_matches(Scope.t(), term(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :bank_account_not_found | :invalid_option}
  def list_matches(%Scope{} = scope, company_id, bank_account_id, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, account} <- bank_account(scope, company_id, bank_account_id),
         do: Matching.list(scope, company_id, account.id, options)
  end

  @doc "The bank account's statement lines, oldest first, each with its `statement_number`; option `to` bounds the date."
  @spec list_statement_lines(Scope.t(), term(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :bank_account_not_found | :invalid_option}
  def list_statement_lines(%Scope{} = scope, company_id, bank_account_id, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, account} <- bank_account(scope, company_id, bank_account_id),
         {:ok, to} <- date_option(options, :to),
         do: {:ok, Matching.statement_lines(scope, company_id, account.id, to: to)}
  end

  ## Reconciliations

  @doc """
  The figures a reconciliation of the bank account would show as of
  `end_date` against `statement_balance`, without opening one: see
  `get_reconciliation/3` for the shape. Options pin the reading to a
  `through_entry_number`, `through_statement_number`, and
  `through_match_event_number`, which is how a finalised reconciliation's
  figures are reproduced. Needs `finance.ledger.view`.
  """
  @spec preview_reconciliation(Scope.t(), term(), term(), map(), keyword()) ::
          {:ok, map()}
          | {:error, refusal() | :bank_account_not_found | :book_not_open | :invalid_option}
  def preview_reconciliation(
        %Scope{} = scope,
        company_id,
        bank_account_id,
        attributes,
        options \\ []
      )
      when is_map(attributes) and is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, account} <- bank_account(scope, company_id, bank_account_id),
         {:ok, end_date, balance} <- figures_attributes(attributes),
         {:ok, pins} <- pins(options),
         do: Reconciliations.compute(scope, company_id, account, end_date, balance, pins)
  end

  defp figures_attributes(attributes) do
    with %Date{} = end_date <- Records.fetch(attributes, :end_date),
         {:ok, balance} <- decimal(Records.fetch(attributes, :statement_balance)) do
      {:ok, end_date, balance}
    else
      _other -> {:error, :invalid_option}
    end
  end

  defp decimal(%Decimal{} = value), do: {:ok, value}

  defp decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> {:ok, decimal}
      _other -> :error
    end
  end

  defp decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp decimal(_value), do: :error

  defp pins(options) do
    keys = [:through_entry_number, :through_statement_number, :through_match_event_number]

    if Keyword.keys(options) -- keys == [] and
         Enum.all?(options, fn {_key, value} ->
           is_integer(value) and value in 0..Records.max_bigint()
         end),
       do: {:ok, options},
       else: {:error, :invalid_option}
  end

  @doc """
  Opens a reconciliation of the bank account as of `end_date` against
  `statement_balance`, the balance the bank's statement shows on that date.
  One reconciliation of an account is open at a time, and each ends after
  the last finalised one; otherwise the changeset says so.
  """
  @spec open_reconciliation(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :bank_account_not_found
             | :bank_account_inactive
             | :book_not_open
             | Changeset.t()}
  def open_reconciliation(%Scope{} = scope, company_id, bank_account_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_reconciliations, fn ->
      with {:ok, account} <- active_bank_account(scope, company_id, bank_account_id),
           {:ok, book} <- Ledger.get_book(scope, company_id),
           do: Reconciliations.open(scope, company_id, account, book, attributes)
    end)
  end

  @doc """
  Finalises an open reconciliation once its difference is zero
  (`{:error, {:difference, amount}}` otherwise): records the figures, the
  numbers they were read at, and the items that explain them, after which
  the reconciliation is immutable and the matches it counted are kept.
  Needs `finance.ledger.view`.
  """
  @spec finalise_reconciliation(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :reconciliation_not_found
             | :reconciliation_finalised
             | :reconciliation_abandoned
             | {:difference, Decimal.t()}
             | Changeset.t()}
  def finalise_reconciliation(%Scope{} = scope, company_id, reconciliation_id) do
    write(scope, company_id, @finalise_reconciliations, fn ->
      with {:ok, reconciliation} <- reconciliation(scope, company_id, reconciliation_id),
           {:ok, account} <- bank_account(scope, company_id, reconciliation.bank_account_id),
           do: Reconciliations.finalise(scope, company_id, reconciliation, account)
    end)
  end

  @doc "Abandons an open reconciliation with a `reason`; a finalised one is kept."
  @spec abandon_reconciliation(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             write_refusal()
             | :reconciliation_not_found
             | :reconciliation_finalised
             | :reconciliation_abandoned
             | Changeset.t()}
  def abandon_reconciliation(%Scope{} = scope, company_id, reconciliation_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @manage_reconciliations, fn ->
      with {:ok, reconciliation} <- reconciliation(scope, company_id, reconciliation_id),
           do: Reconciliations.abandon(scope, company_id, reconciliation, attributes)
    end)
  end

  @doc """
  One reconciliation with its `status` (`open`, `finalised`, or
  `abandoned`), `events`, and, unless abandoned, its figures:
  `statement_balance`, `book_balance`, `difference`, `currency_code`,
  `minor_units`, the three `through_*` numbers, and `items`, each
  `%{kind, statement_line_id, entry_id, match_id, item_date, description,
  reference, amount}` where `kind` is `statement_line` (on the statement,
  not in the books), `entry` (in the books, not on the statement), or
  `timing` (matched, but cleared after the end date). An open
  reconciliation's figures are read now; a finalised one's are its stored
  snapshot. Needs `finance.ledger.view`.
  """
  @spec get_reconciliation(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :reconciliation_not_found | :book_not_open}
  def get_reconciliation(%Scope{} = scope, company_id, reconciliation_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, reconciliation} <- reconciliation(scope, company_id, reconciliation_id),
         {:ok, account} <- bank_account(scope, company_id, reconciliation.bank_account_id),
         do: Reconciliations.report(scope, company_id, reconciliation, account)
  end

  @doc "The bank account's reconciliations, oldest first, with their status and events."
  @spec list_reconciliations(Scope.t(), term(), term()) ::
          {:ok, [map()]} | {:error, refusal() | :bank_account_not_found}
  def list_reconciliations(%Scope{} = scope, company_id, bank_account_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, account} <- bank_account(scope, company_id, bank_account_id),
         do: {:ok, Reconciliations.list(scope, company_id, account.id)}
  end

  ## Posting

  @doc """
  Posts an unmatched statement line the books do not have as `kind`:
  `charge`, money out against the bank account's charges account, or
  `interest`, money in against its interest account, dated the line's date
  with the line's description unless `description` is given; then matches
  the line to the new entry. Posting goes through the ledger facade, so the
  actor also needs `finance.ledger.entries.post`, and the ledger's refusal
  (a closed period, an inactive account) is returned as its changeset with
  nothing recorded. Other refusals: `:invalid_kind`, `:no_charges_account`,
  `:no_interest_account`, `:not_a_charge` (the line is money in),
  `:not_interest` (money out), `:statement_line_matched`, and
  `:statement_line_posted` for a line that already posted an entry (the
  ledger holds that entry as this line's: match the line to it instead).
  """
  @spec post_statement_line(Scope.t(), term(), term(), map()) ::
          {:ok, %{entry: map(), match: map()}}
          | {:error,
             write_refusal()
             | :statement_line_not_found
             | :bank_account_inactive
             | :book_not_open
             | Changeset.t()
             | atom()}
  def post_statement_line(%Scope{} = scope, company_id, statement_line_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @post_statement_lines, fn ->
      with {:ok, line} <- statement_line(scope, company_id, statement_line_id),
           {:ok, account} <- active_bank_account(scope, company_id, line.bank_account_id),
           do: Posting.post_statement_line(scope, company_id, account, line, attributes)
    end)
  end

  ## Lookups

  defp bank_account(scope, company_id, bank_account_id) do
    case BankAccounts.get(scope, company_id, Records.id(bank_account_id) || 0) do
      nil -> {:error, :bank_account_not_found}
      account -> {:ok, account}
    end
  end

  defp active_bank_account(scope, company_id, bank_account_id) do
    case bank_account(scope, company_id, bank_account_id) do
      {:ok, %{active: false}} -> {:error, :bank_account_inactive}
      other -> other
    end
  end

  defp statement_line(scope, company_id, statement_line_id) do
    case Records.get(StatementLine, scope, company_id, Records.id(statement_line_id) || 0) do
      nil -> {:error, :statement_line_not_found}
      line -> {:ok, line}
    end
  end

  defp reconciliation(scope, company_id, reconciliation_id) do
    case Reconciliations.fetch(scope, company_id, Records.id(reconciliation_id) || 0) do
      nil -> {:error, :reconciliation_not_found}
      reconciliation -> {:ok, reconciliation}
    end
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
end
