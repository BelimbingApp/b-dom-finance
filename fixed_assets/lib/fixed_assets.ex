defmodule Bilimbi.Finance.FixedAssets do
  @moduledoc """
  Immutable company asset register, category revisions, monthly depreciation,
  disposal, voided acquisitions and reversing entries. All data calls
  reauthorize the supplied scope; all writes hold the writable-company lock.
  Ledger and Payables are consumed only through their facades. Acquisition cost
  comes from one posted cost-account debit, never caller arithmetic. Nothing
  can be deleted or edited.

  Reports carry category, asset, event and ledger watermarks: pass all four back to
  reproduce a prior read even after backdated acquisitions or reversals.
  Category accounts and depreciation assumptions are frozen at acquisition.
  Reconciliation also includes unregistered balances on configured category
  accounts, bounded by through_category_revision_id for reproducibility.
  """
  import Ecto.Query
  import Ecto.Changeset
  alias Bilimbi.Base.{Repo, Tenancy}
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.{Ledger, Payables}
  alias Bilimbi.Finance.FixedAssets.Ownership

  alias Bilimbi.Finance.FixedAssets.{
    Asset,
    Category,
    CategoryRevision,
    Contributions,
    Event,
    Run,
    RunException,
    RunItem,
    Schedule
  }

  @view "finance.fixed-assets.view"
  @configure "finance.fixed-assets.finance-asset-configure"
  @acquire "finance.fixed-assets.finance-asset-acquire"
  @depreciate "finance.fixed-assets.finance-asset-depreciate"
  @reverse "finance.fixed-assets.finance-asset-reverse"
  @dispose "finance.fixed-assets.finance-asset-dispose"
  @void "finance.fixed-assets.finance-asset-void"
  @defaults ~w(cost_account_id accumulated_account_id expense_account_id gain_account_id loss_account_id method life_months annual_rate)a
  @account_types %{
    cost_account_id: "asset",
    accumulated_account_id: "asset",
    expense_account_id: "expense",
    gain_account_id: "income",
    loss_account_id: "expense"
  }

  def view_capability, do: @view
  def configure_capability, do: @configure
  def acquire_capability, do: @acquire
  def depreciate_capability, do: @depreciate
  def reverse_capability, do: @reverse
  def dispose_capability, do: @dispose
  def void_capability, do: @void
  def capabilities, do: Contributions.capabilities()

  @doc "Creates a category and its first immutable revision; reason is required."
  def create_category(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    write(scope, company_id, @configure, fn ->
      with {:ok, accounts} <- Ledger.list_accounts(scope, company_id),
           cs = revision_changeset(identity(CategoryRevision, scope, company_id), attrs, accounts),
           true <- cs.valid? || {:error, cs},
           {:ok, category} <-
             identity(Category, scope, company_id)
             |> cast(params(attrs), [:name])
             |> trim(:name)
             |> validate_required([:name])
             |> validate_length(:name, max: 200)
             |> unique_constraint(:name, name: :finance_fixed_assets_categories_name)
             |> Repo.insert(),
           {:ok, revision} <- cs |> put_change(:category_id, category.id) |> Repo.insert() do
        {:ok, Map.put(public(revision), :name, category.name)}
      end
    end)
  end

  @doc "Adds a complete category revision. Existing assets keep their acquisition revision."
  def revise_category(%Scope{} = scope, company_id, category_id, attrs) when is_map(attrs) do
    write(scope, company_id, @configure, fn ->
      with {:ok, category} <- fetch(Category, scope, company_id, category_id),
           {:ok, accounts} <- Ledger.list_accounts(scope, company_id),
           {:ok, revision} <-
             identity(CategoryRevision, scope, company_id)
             |> Map.put(:category_id, category.id)
             |> revision_changeset(attrs, accounts)
             |> Repo.insert() do
        {:ok, Map.put(public(revision), :name, category.name)}
      end
    end)
  end

  def list_categories(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      categories = query(Category, scope, company_id) |> order_by([c], c.name) |> Repo.all()
      revisions = query(CategoryRevision, scope, company_id) |> order_by([r], r.id) |> Repo.all()

      {:ok,
       Enum.map(categories, fn category ->
         history = Enum.filter(revisions, &(&1.category_id == category.id)) |> Enum.map(&public/1)
         %{id: category.id, name: category.name, revision: List.last(history), revisions: history}
       end)}
    end
  end

  @doc "Registers one posted supplier bill line, deriving its cost and acquisition entry."
  def acquire_from_bill(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    write(scope, company_id, @acquire, fn ->
      input =
        identity(Asset, scope, company_id)
        |> cast(params(attrs), [:bill_id, :bill_line_number])
        |> validate_required([:bill_id, :bill_line_number])
        |> validate_number(:bill_id, greater_than: 0)
        |> validate_number(:bill_line_number, greater_than: 0)

      with true <- input.valid? || {:error, input},
           {:ok, bill} <- Payables.get_document(scope, company_id, get_field(input, :bill_id)),
           true <-
             (bill.document_type == "bill" and bill.status == "posted") ||
               {:error, :bill_not_posted},
           line when not is_nil(line) <-
             Enum.find(bill.lines, &(&1.line_number == get_field(input, :bill_line_number))),
           {:ok, entry} <- Ledger.get_entry(scope, company_id, bill.entry_id) do
        register(scope, company_id, attrs, entry, line.line_number, %{
          bill_id: bill.id,
          bill_line_number: line.line_number
        })
      else
        nil -> {:error, :bill_line_not_found}
        error -> error
      end
    end)
  end

  @doc "Registers one debit from a manually posted acquisition journal entry."
  def acquire_from_entry(%Scope{} = scope, company_id, attrs) when is_map(attrs) do
    write(scope, company_id, @acquire, fn ->
      input =
        identity(Asset, scope, company_id)
        |> cast(params(attrs), [:entry_id, :entry_line_number])
        |> validate_required([:entry_id, :entry_line_number])
        |> validate_number(:entry_id, greater_than: 0)
        |> validate_number(:entry_line_number, greater_than: 0)

      with true <- input.valid? || {:error, input},
           {:ok, entry} <- Ledger.get_entry(scope, company_id, get_field(input, :entry_id)) do
        register(scope, company_id, attrs, entry, get_field(input, :entry_line_number), %{})
      end
    end)
  end

  defp register(scope, company_id, attrs, entry, line_number, source) do
    input =
      identity(Asset, scope, company_id)
      |> cast(params(attrs), [:category_revision_id])
      |> validate_required([:category_revision_id])

    with true <- input.valid? || {:error, input},
         {:ok, revision} <-
           fetch(CategoryRevision, scope, company_id, get_field(input, :category_revision_id)),
         {:ok, book} <- Ledger.get_book(scope, company_id),
         :ok <- live_entry(entry),
         line when not is_nil(line) <- Enum.find(entry.lines, &(&1.line_number == line_number)),
         true <-
           (line.account_id == revision.cost_account_id and Decimal.gt?(line.debit, 0) and
              Decimal.eq?(line.credit, 0)) || {:error, :not_acquisition_debit} do
      base =
        identity(Asset, scope, company_id)
        |> Map.merge(source)
        |> Map.merge(%{
          category_revision_id: revision.id,
          acquisition_date: entry.entry_date,
          cost: line.debit,
          entry_id: entry.id,
          entry_number: entry.entry_number,
          entry_line_number: line_number,
          residual_value: Decimal.new(0),
          method: revision.method,
          life_months: revision.life_months,
          annual_rate: revision.annual_rate
        })

      cs =
        base
        |> cast(params(attrs), [
          :description,
          :in_service_date,
          :residual_value,
          :method,
          :life_months,
          :annual_rate
        ])
        |> trim(:description)
        |> validate_required([:description, :in_service_date, :residual_value])
        |> validate_length(:description, max: 500)
        |> method_changeset()
        |> money(:residual_value, book.minor_units)
        |> validate_number(:residual_value, less_than_or_equal_to: line.debit)
        |> validate_change(:in_service_date, fn _, date ->
          if Date.compare(date, entry.entry_date) == :lt,
            do: [in_service_date: "cannot precede acquisition"],
            else: []
        end)
        |> unique_constraint(:entry_id, name: :finance_fixed_assets_assets_source)

      with {:ok, asset} <- Repo.insert(cs), do: {:ok, public(asset)}
    else
      nil -> {:error, :entry_line_not_found}
      error -> error
    end
  end

  @doc """
  Posts one balanced entry for a calendar month. Repeating the period returns its stored run.
  An asset whose acquisition entry was reversed is skipped and recorded as the run's exception
  until `void_acquisition/4` retires it; the remaining assets are still charged.
  """
  def depreciate(%Scope{} = scope, company_id, %Date{} = period) do
    write(scope, company_id, @depreciate, fn ->
      with :ok <- month(period) do
        case query(Run, scope, company_id) |> where([r], r.period == ^period) |> Repo.one() do
          nil -> post_run(scope, company_id, period)
          run -> {:ok, run_view(scope, company_id, run)}
        end
      end
    end)
  end

  defp post_run(scope, company_id, period) do
    date = Date.end_of_month(period)

    with :ok <- open_period(scope, company_id, period),
         :ok <- chronological(scope, company_id, date),
         {:ok, report} <- register_report(scope, company_id, date) do
      candidates =
        for row <- report.rows,
            not row.disposed?,
            not row.voided?,
            Decimal.gt?(row.scheduled_depreciation, row.accumulated) do
          %{
            asset: row.asset,
            revision: row.revision,
            amount: Decimal.sub(row.scheduled_depreciation, row.accumulated)
          }
        end

      # The run takes its ID now: the entry names it as its owner, and the
      # run names the entry, in one transaction.
      run_id = Ownership.next_id(Run)

      with {:ok, {items, excepted}} <- split_by_source(scope, company_id, candidates),
           total = sum(items, :amount),
           {:ok, entry} <-
             post_or_empty(
               scope,
               company_id,
               total,
               %{
                 entry_date: date,
                 description: "Asset depreciation #{period}",
                 lines:
                   Enum.flat_map(items, fn i ->
                     [
                       %{account_id: i.revision.expense_account_id, debit: i.amount},
                       %{account_id: i.revision.accumulated_account_id, credit: i.amount}
                     ]
                   end)
               },
               Ownership.owner(:run, run_id)
             ),
           {:ok, run} <-
             identity(Run, scope, company_id)
             |> Map.put(:id, run_id)
             |> change(%{
               period: period,
               total: total,
               entry_id: entry && entry.id,
               entry_number: entry && entry.entry_number
             })
             |> unique_constraint(:period, name: :finance_fixed_assets_runs_period)
             |> Repo.insert(),
           :ok <- insert_items(scope, company_id, run, items),
           :ok <- insert_exceptions(scope, company_id, run, excepted) do
        {:ok, run_view(scope, company_id, run)}
      end
    end
  end

  @doc """
  Reverses the latest nonempty run; later runs or standing disposals must be reversed first.
  Charges of voided acquisitions were already reversed by their void and are left out.
  """
  def reverse_run(%Scope{} = scope, company_id, run_id, attrs) when is_map(attrs) do
    write(scope, company_id, @reverse, fn ->
      with {:ok, run} <- fetch(Run, scope, company_id, run_id),
           true <- not is_nil(run.entry_id) || {:error, :empty_run},
           false <- reversed_run?(scope, company_id, run.id),
           items = run_items(scope, company_id, run.id),
           voided = voided_asset_ids(all(Event, scope, company_id)),
           live = Enum.reject(items, &(&1.asset_id in voided)),
           true <- live != [] || {:error, :empty_run},
           {:ok, event} <-
             event_changeset(scope, company_id, attrs, "run_reversed", %{run_id: run.id})
             |> apply_action(:insert),
           event = %{event | id: Ownership.next_id(Event)},
           :ok <- reversal_dependencies(scope, company_id, run, event.effective_date),
           {:ok, entry} <- reverse_charges(scope, company_id, run, items, live, event),
           {:ok, saved} <-
             event
             |> change(entry_id: entry.id, entry_number: entry.entry_number)
             |> Repo.insert() do
        {:ok, public(saved)}
      else
        true -> {:error, :already_reversed}
        error -> error
      end
    end)
  end

  @doc "Disposes an asset by sale (proceeds and settlement account) or write-off (zero proceeds)."
  def dispose(%Scope{} = scope, company_id, asset_id, attrs) when is_map(attrs) do
    write(scope, company_id, @dispose, fn ->
      with {:ok, asset} <- fetch(Asset, scope, company_id, asset_id),
           true <- not voided?(all(Event, scope, company_id), asset.id) || {:error, :asset_voided},
           {:ok, revision} <-
             fetch(CategoryRevision, scope, company_id, asset.category_revision_id),
           {:ok, book} <- Ledger.get_book(scope, company_id),
           {:ok, event} <-
             event_changeset(scope, company_id, attrs, "disposed", %{asset_id: asset.id})
             |> cast(params(attrs), [:proceeds])
             |> validate_required([:proceeds])
             |> money(:proceeds, book.minor_units)
             |> apply_action(:insert),
           true <-
             Date.compare(event.effective_date, asset.acquisition_date) != :lt ||
               {:error, :before_acquisition},
           :ok <- chronological(scope, company_id, event.effective_date),
           {:ok, source} <- Ledger.get_entry(scope, company_id, asset.entry_id),
           :ok <- live_entry(source),
           {:ok, report} <- register_report(scope, company_id, event.effective_date),
           row = Enum.find(report.rows, &(&1.asset.id == asset.id)),
           true <- not row.disposed? || {:error, :already_disposed},
           true <-
             Decimal.eq?(row.scheduled_depreciation, row.accumulated) ||
               {:error, :depreciation_required},
           {:ok, settlement} <- settlement_account(scope, company_id, attrs, event.proceeds),
           event = %{event | id: Ownership.next_id(Event)},
           {:ok, entry} <-
             Ledger.post_entry(
               scope,
               company_id,
               %{
                 entry_date: event.effective_date,
                 description: event.reason,
                 lines: disposal_lines(asset, revision, row.accumulated, event.proceeds, settlement)
               },
               owner: Ownership.owner(:event, event.id)
             ),
           {:ok, saved} <-
             event
             |> change(
               accumulated: row.accumulated,
               entry_id: entry.id,
               entry_number: entry.entry_number
             )
             |> Repo.insert() do
        {:ok, public(saved)}
      end
    end)
  end

  @doc """
  Retires an asset whose acquisition entry was reversed. Its unreversed depreciation is
  mirrored in one entry that leaves every other asset's postings alone, and the asset
  then drops out of runs and reconciliation. The event is permanent, so its date must fall
  in an open fiscal period even when no entry is posted; a standing disposal must be
  reversed first.
  """
  def void_acquisition(%Scope{} = scope, company_id, asset_id, attrs) when is_map(attrs) do
    write(scope, company_id, @void, fn ->
      with {:ok, asset} <- fetch(Asset, scope, company_id, asset_id),
           events = all(Event, scope, company_id),
           true <- not voided?(events, asset.id) || {:error, :already_voided},
           true <- is_nil(standing_disposal(events, asset.id)) || {:error, :disposal_standing},
           {:ok, source} <- Ledger.get_entry(scope, company_id, asset.entry_id),
           true <- live_entry(source) != :ok || {:error, :acquisition_not_reversed},
           {:ok, event} <-
             event_changeset(scope, company_id, attrs, "acquisition_voided", %{asset_id: asset.id})
             |> apply_action(:insert),
           :ok <- open_period(scope, company_id, Date.beginning_of_month(event.effective_date)),
           :ok <- chronological(scope, company_id, event.effective_date),
           reversed = reversed_run_ids(events),
           charges =
             asset_items(scope, company_id, asset.id) |> Enum.reject(&(&1.run_id in reversed)),
           event = %{event | id: Ownership.next_id(Event)},
           {:ok, entry} <-
             mirror_charges(
               scope,
               company_id,
               charges,
               event.effective_date,
               event.reason,
               Ownership.owner(:event, event.id)
             ),
           {:ok, saved} <-
             event
             |> change(
               accumulated: sum(charges, :amount),
               entry_id: entry && entry.id,
               entry_number: entry && entry.entry_number
             )
             |> Repo.insert() do
        {:ok, public(saved)}
      end
    end)
  end

  @doc "Reverses a standing disposal, retaining both the disposal and its mirror entry."
  def reverse_disposal(%Scope{} = scope, company_id, asset_id, attrs) when is_map(attrs) do
    write(scope, company_id, @reverse, fn ->
      with {:ok, _asset} <- fetch(Asset, scope, company_id, asset_id),
           original when not is_nil(original) <-
             standing_disposal(all(Event, scope, company_id), asset_id),
           {:ok, event} <-
             event_changeset(scope, company_id, attrs, "disposal_reversed", %{
               asset_id: asset_id,
               reverses_event_id: original.id
             })
             |> apply_action(:insert),
           :ok <- chronological(scope, company_id, event.effective_date),
           {:ok, entry} <-
             Ledger.reverse_owned_entry(
               scope,
               company_id,
               original.entry_id,
               Ownership.owner(:event, original.id),
               %{entry_date: event.effective_date, description: event.reason}
             ),
           {:ok, saved} <-
             event
             |> change(entry_id: entry.id, entry_number: entry.entry_number)
             |> Repo.insert() do
        {:ok, public(saved)}
      else
        nil -> {:error, :not_disposed}
        error -> error
      end
    end)
  end

  def list_runs(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok, all(Run, scope, company_id) |> Enum.map(&run_view(scope, company_id, &1))}
    end
  end

  @doc "Asset, its immutable assumptions, complete projected schedule and recorded audit events."
  def get_asset(%Scope{} = scope, company_id, asset_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, asset} <- fetch(Asset, scope, company_id, asset_id),
         {:ok, book} <- Ledger.get_book(scope, company_id),
         {:ok, revision} <- fetch(CategoryRevision, scope, company_id, asset.category_revision_id) do
      events = all(Event, scope, company_id)

      {:ok,
       %{
         asset: public(asset),
         voided?: voided?(events, asset.id),
         revision: public(revision),
         schedule: Schedule.rows(asset, book.minor_units),
         events: events |> Enum.filter(&(&1.asset_id == asset.id)) |> Enum.map(&public/1),
         charges: asset_charges(scope, company_id, asset.id)
       }}
    end
  end

  @doc """
  Register and schedule as of a date with ledger reconciliation. Pass returned
  through_category_revision_id, through_asset_number, through_event_number and
  through_entry_number together
  to reproduce it. Differences expose unregistered assets or external postings
  on category accounts instead of silently asserting the books agree.
  """
  def register_report(%Scope{} = scope, company_id, %Date{} = date, options \\ []) do
    with :ok <- authorize(scope, company_id, @view),
         :ok <- report_options(options),
         {:ok, totals} <-
           Ledger.account_totals(scope, company_id,
             to: date,
             through_entry_number: Keyword.get(options, :through_entry_number)
           ),
         {:ok, flows} <-
           Ledger.account_totals(scope, company_id,
             to: date,
             through_entry_number: totals.through_entry_number,
             exclude_closing: true
           ) do
      assets = all(Asset, scope, company_id)
      events = all(Event, scope, company_id)

      asset_through =
        Keyword.get(options, :through_asset_number, max_number(assets, :asset_number))

      event_through =
        Keyword.get(options, :through_event_number, max_number(events, :event_number))

      events =
        Enum.filter(
          events,
          &(&1.event_number <= event_through and
              (is_nil(&1.entry_number) or &1.entry_number <= totals.through_entry_number) and
              Date.compare(&1.effective_date, date) != :gt)
        )

      runs =
        all(Run, scope, company_id)
        |> Enum.filter(
          &(Date.compare(Date.end_of_month(&1.period), date) != :gt and
              (is_nil(&1.entry_number) or &1.entry_number <= totals.through_entry_number))
        )

      run_map = Map.new(runs, &{&1.id, &1})
      items = all(RunItem, scope, company_id) |> Enum.filter(&Map.has_key?(run_map, &1.run_id))
      revisions = all(CategoryRevision, scope, company_id)

      category_through =
        Keyword.get(options, :through_category_revision_id, max_number(revisions, :id))

      revisions = Enum.filter(revisions, &(&1.id <= category_through)) |> Map.new(&{&1.id, &1})

      rows =
        for asset <- assets,
            asset.asset_number <= asset_through,
            asset.entry_number <= totals.through_entry_number,
            Map.has_key?(revisions, asset.category_revision_id),
            Date.compare(asset.acquisition_date, date) != :gt do
          voided? = voided?(events, asset.id)

          accumulated =
            items
            |> Enum.filter(
              &(&1.asset_id == asset.id and not voided? and
                  not Enum.any?(events, fn e ->
                    e.run_id == &1.run_id and e.action == "run_reversed"
                  end))
            )
            |> sum(:amount)

          disposed = standing_disposal(events, asset.id)

          %{
            asset: public(asset),
            revision: public(Map.fetch!(revisions, asset.category_revision_id)),
            accumulated: accumulated,
            scheduled_depreciation:
              if(voided?,
                do: Decimal.new(0),
                else: Schedule.cumulative(asset, date, totals.minor_units)
              ),
            carrying_value:
              if(disposed || voided?,
                do: Decimal.new(0),
                else: Decimal.sub(asset.cost, accumulated)
              ),
            disposed?: not is_nil(disposed),
            voided?: voided?,
            disposal_gain:
              if(disposed,
                do: Decimal.sub(disposed.proceeds, Decimal.sub(asset.cost, disposed.accumulated)),
                else: Decimal.new(0)
              ),
            schedule: Schedule.rows(asset, totals.minor_units)
          }
        end

      {:ok,
       %{
         company_id: company_id,
         as_of: date,
         currency_code: totals.currency_code,
         minor_units: totals.minor_units,
         through_category_revision_id: category_through,
         through_asset_number: asset_through,
         through_event_number: event_through,
         through_entry_number: totals.through_entry_number,
         rows: rows,
         reconciliation: reconcile(rows, totals.rows, flows.rows, Map.values(revisions))
       }}
    end
  end

  @doc "The reproducible register report, including each asset's projected monthly schedule."
  def depreciation_schedule_report(%Scope{} = scope, company_id, %Date{} = date, options \\ []) do
    with :ok <- authorize(scope, company_id, @view) do
      register_report(scope, company_id, date, options)
    end
  end

  defp reconcile(rows, totals, flows, revisions) do
    expected =
      Enum.reduce(Enum.reject(rows, & &1.voided?), %{}, fn row, balances ->
        balances = add_balance(balances, row.revision.expense_account_id, row.accumulated)

        balances =
          if row.disposed? do
            if Decimal.gt?(row.disposal_gain, 0),
              do:
                add_balance(
                  balances,
                  row.revision.gain_account_id,
                  Decimal.negate(row.disposal_gain)
                ),
              else:
                add_balance(
                  balances,
                  row.revision.loss_account_id,
                  Decimal.negate(row.disposal_gain)
                )
          else
            balances
            |> add_balance(row.revision.cost_account_id, row.asset.cost)
            |> add_balance(row.revision.accumulated_account_id, Decimal.negate(row.accumulated))
          end

        balances
      end)

    stock_ids =
      revisions |> Enum.flat_map(&[&1.cost_account_id, &1.accumulated_account_id]) |> Enum.uniq()

    flow_ids =
      revisions
      |> Enum.flat_map(&[&1.expense_account_id, &1.gain_account_id, &1.loss_account_id])
      |> Enum.uniq()

    Enum.map(stock_ids ++ flow_ids, fn id ->
      kind = if id in stock_ids, do: :balance, else: :activity
      source = if kind == :balance, do: totals, else: flows

      ledger =
        Enum.find(source, %{debits: Decimal.new(0), credits: Decimal.new(0)}, &(&1.id == id))

      actual = Decimal.sub(ledger.debits, ledger.credits)
      registered = Map.get(expected, id, Decimal.new(0))

      %{
        account_id: id,
        kind: kind,
        ledger_balance: actual,
        register_balance: registered,
        difference: Decimal.sub(actual, registered)
      }
    end)
  end

  defp add_balance(map, id, amount), do: Map.update(map, id, amount, &Decimal.add(&1, amount))

  defp report_options(options) do
    if Keyword.keyword?(options) and
         Enum.all?(options, fn {k, v} ->
           k in [
             :through_entry_number,
             :through_asset_number,
             :through_event_number,
             :through_category_revision_id
           ] and is_integer(v) and v >= 0
         end), do: :ok, else: {:error, :invalid_option}
  end

  defp reversal_dependencies(scope, company_id, run, date) do
    events = all(Event, scope, company_id)

    voided = voided_asset_ids(events)
    items = all(RunItem, scope, company_id)

    later =
      all(Run, scope, company_id)
      |> Enum.any?(fn later_run ->
        Date.compare(later_run.period, run.period) == :gt and
          Enum.any?(items, &(&1.run_id == later_run.id and &1.asset_id not in voided)) and
          not reversed_run?(scope, company_id, later_run.id)
      end)

    disposed = all(Asset, scope, company_id) |> Enum.any?(&standing_disposal(events, &1.id))

    cond do
      later or disposed -> {:error, :dependent_postings}
      Date.compare(date, Date.end_of_month(run.period)) == :lt -> {:error, :before_original}
      true -> chronological(scope, company_id, date)
    end
  end

  defp chronological(scope, company_id, date) do
    later_run =
      all(Run, scope, company_id)
      |> Enum.any?(&(Date.compare(Date.end_of_month(&1.period), date) == :gt))

    later_event =
      all(Event, scope, company_id) |> Enum.any?(&(Date.compare(&1.effective_date, date) == :gt))

    if later_run or later_event, do: {:error, :later_activity}, else: :ok
  end

  defp open_period(scope, company_id, period) do
    with {:ok, years} <- Ledger.list_fiscal_years(scope, company_id) do
      case years |> Enum.flat_map(& &1.periods) |> Enum.find(&(&1.start_date == period)) do
        %{status: "open"} -> :ok
        nil -> {:error, :period_not_found}
        _closed -> {:error, :period_closed}
      end
    end
  end

  defp month(%Date{day: 1}), do: :ok
  defp month(_date), do: {:error, :invalid_period}
  defp live_entry(%{reversed_by_entry_id: nil, reverses_entry_id: nil}), do: :ok
  defp live_entry(_entry), do: {:error, :acquisition_reversed}

  defp split_by_source(scope, company_id, candidates) do
    Enum.reduce_while(candidates, {:ok, {[], []}}, fn item, {:ok, {live, excepted}} ->
      case Ledger.get_entry(scope, company_id, item.asset.entry_id) do
        {:ok, entry} ->
          case live_entry(entry) do
            :ok -> {:cont, {:ok, {[item | live], excepted}}}
            _reversed -> {:cont, {:ok, {live, [item | excepted]}}}
          end

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, {live, excepted}} -> {:ok, {Enum.reverse(live), Enum.reverse(excepted)}}
      error -> error
    end
  end

  defp post_or_empty(scope, company, total, attrs, owner) do
    if Decimal.eq?(total, 0),
      do: {:ok, nil},
      else: Ledger.post_entry(scope, company, attrs, owner: owner)
  end

  defp insert_items(scope, company_id, run, items) do
    insert_each(items, fn item ->
      identity(RunItem, scope, company_id)
      |> change(run_id: run.id, asset_id: item.asset.id, amount: item.amount)
      |> Repo.insert()
    end)
  end

  defp insert_exceptions(scope, company_id, run, excepted) do
    insert_each(excepted, fn item ->
      identity(RunException, scope, company_id)
      |> change(run_id: run.id, asset_id: item.asset.id)
      |> Repo.insert()
    end)
  end

  defp insert_each(rows, insert) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case insert.(row) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A whole run is reversed through the ledger's owner path, as the run's
  # owner; a run with voided assets is mirrored for the live ones, as the
  # reversal event's own entry.
  defp reverse_charges(scope, company_id, run, items, live, event)
       when length(items) == length(live),
       do:
         Ledger.reverse_owned_entry(
           scope,
           company_id,
           run.entry_id,
           Ownership.owner(:run, run.id),
           %{entry_date: event.effective_date, description: event.reason}
         )

  defp reverse_charges(scope, company_id, _run, _items, live, event),
    do:
      mirror_charges(
        scope,
        company_id,
        live,
        event.effective_date,
        event.reason,
        Ownership.owner(:event, event.id)
      )

  defp mirror_charges(_scope, _company_id, [], _date, _description, _owner), do: {:ok, nil}

  defp mirror_charges(scope, company_id, charges, date, description, owner) do
    assets = all(Asset, scope, company_id) |> Map.new(&{&1.id, &1})
    revisions = all(CategoryRevision, scope, company_id) |> Map.new(&{&1.id, &1})

    lines =
      Enum.flat_map(charges, fn charge ->
        revision = Map.fetch!(revisions, Map.fetch!(assets, charge.asset_id).category_revision_id)

        [
          %{account_id: revision.accumulated_account_id, debit: charge.amount},
          %{account_id: revision.expense_account_id, credit: charge.amount}
        ]
      end)

    Ledger.post_entry(
      scope,
      company_id,
      %{entry_date: date, description: description, lines: lines},
      owner: owner
    )
  end

  defp run_items(scope, company_id, run_id),
    do: query(RunItem, scope, company_id) |> where([i], i.run_id == ^run_id) |> Repo.all()

  defp asset_items(scope, company_id, asset_id),
    do: query(RunItem, scope, company_id) |> where([i], i.asset_id == ^asset_id) |> Repo.all()

  defp voided?(events, asset_id),
    do: Enum.any?(events, &(&1.asset_id == asset_id and &1.action == "acquisition_voided"))

  defp voided_asset_ids(events),
    do: for(%{action: "acquisition_voided"} = e <- events, into: MapSet.new(), do: e.asset_id)

  defp reversed_run_ids(events),
    do: for(%{action: "run_reversed"} = e <- events, into: MapSet.new(), do: e.run_id)

  defp settlement_account(scope, company_id, attrs, proceeds) do
    if Decimal.eq?(proceeds, 0) do
      {:ok, nil}
    else
      cs =
        {%{}, %{settlement_account_id: :integer}}
        |> cast(params(attrs), [:settlement_account_id])
        |> validate_required([:settlement_account_id])

      with true <- cs.valid? || {:error, cs},
           {:ok, accounts} <- Ledger.list_accounts(scope, company_id) do
        case Enum.find(
               accounts,
               &(&1.id == get_field(cs, :settlement_account_id) and &1.active and
                   &1.account_type == "asset")
             ) do
          nil -> {:error, :invalid_settlement_account}
          account -> {:ok, account.id}
        end
      end
    end
  end

  defp disposal_lines(asset, revision, accumulated, proceeds, settlement) do
    net = Decimal.sub(asset.cost, accumulated)
    gain = Decimal.sub(proceeds, net)

    [
      %{account_id: revision.cost_account_id, credit: asset.cost},
      %{account_id: revision.accumulated_account_id, debit: accumulated},
      %{account_id: settlement, debit: proceeds},
      if(Decimal.gt?(gain, 0),
        do: %{account_id: revision.gain_account_id, credit: gain},
        else: %{account_id: revision.loss_account_id, debit: Decimal.negate(gain)}
      )
    ]
    |> Enum.filter(fn line -> Decimal.gt?(Map.get(line, :debit, Map.get(line, :credit)), 0) end)
  end

  defp event_changeset(scope, company_id, attrs, action, extra) do
    identity(Event, scope, company_id)
    |> Map.merge(extra)
    |> Map.put(:action, action)
    |> cast(params(attrs), [:effective_date, :reason])
    |> trim(:reason)
    |> validate_required([:effective_date, :reason])
    |> validate_length(:reason, max: 500)
  end

  defp revision_changeset(revision, attrs, accounts) do
    revision
    |> cast(params(attrs), @defaults ++ [:reason])
    |> trim(:reason)
    |> validate_required(@defaults -- ([:annual_rate] ++ [:reason]))
    |> validate_length(:reason, max: 500)
    |> method_changeset()
    |> then(fn cs ->
      Enum.reduce(@account_types, cs, fn {field, type}, cs ->
        id = get_field(cs, field)

        if Enum.any?(accounts, &(&1.id == id and &1.active and &1.account_type == type)),
          do: cs,
          else: add_error(cs, field, "must be an active company #{type} account")
      end)
    end)
    |> then(fn cs ->
      if get_field(cs, :cost_account_id) == get_field(cs, :accumulated_account_id),
        do: add_error(cs, :accumulated_account_id, "must differ from the cost account"),
        else: cs
    end)
  end

  defp method_changeset(cs) do
    cs =
      cs
      |> validate_required([:method, :life_months])
      |> validate_inclusion(:method, ["straight_line", "reducing_balance"])
      |> validate_number(:life_months, greater_than: 0, less_than_or_equal_to: 1200)

    if get_field(cs, :method) == "straight_line",
      do: put_change(cs, :annual_rate, nil),
      else:
        cs
        |> validate_required([:annual_rate])
        |> validate_number(:annual_rate, greater_than: 0, less_than_or_equal_to: 100)
        |> validate_change(:annual_rate, fn _, rate ->
          if Decimal.eq?(rate, Decimal.round(rate, 4)),
            do: [],
            else: [annual_rate: "has more than four decimal places"]
        end)
  end

  defp money(cs, field, precision) do
    cs
    |> validate_number(field, greater_than_or_equal_to: 0, less_than: Decimal.new("1E16"))
    |> validate_change(field, fn _, value ->
      if Decimal.eq?(value, Decimal.round(value, precision)),
        do: [],
        else: [{field, "has more than #{precision} decimal places"}]
    end)
  end

  defp params(attrs),
    do:
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.reject(fn {k, v} -> k == "residual_value" and v == "" end)

  defp trim(cs, field), do: update_change(cs, field, &String.trim/1)

  defp sum(rows, field),
    do: Enum.reduce(rows, Decimal.new(0), &Decimal.add(Map.fetch!(&1, field), &2))

  defp max_number([], _field), do: 0
  defp max_number(rows, field), do: rows |> Enum.map(&Map.fetch!(&1, field)) |> Enum.max()

  defp identity(module, scope, company_id) do
    actor = Scope.actor(scope)

    struct(module,
      tenant_id: Scope.tenant_id(scope),
      company_id: company_id,
      recorded_by_user_id: actor.user_id,
      recorded_by_impersonator_id: actor.impersonator_id
    )
  end

  defp public(record) do
    record
    |> Map.from_struct()
    |> Map.drop([:__meta__, :tenant_id, :company_id])
    |> Map.new(fn
      {key, %Decimal{} = amount} -> {key, Decimal.normalize(amount)}
      pair -> pair
    end)
  end

  defp query(module, scope, company_id),
    do: from(r in Tenancy.scope_query(module, scope), where: r.company_id == ^company_id)

  defp all(module, scope, company_id),
    do: query(module, scope, company_id) |> order_by([r], r.id) |> Repo.all()

  defp fetch(module, scope, company_id, id) when is_integer(id) do
    case query(module, scope, company_id) |> where([r], r.id == ^id) |> Repo.one() do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp fetch(_module, _scope, _company_id, _id), do: {:error, :not_found}

  defp standing_disposal(events, asset_id) do
    events
    |> Enum.filter(&(&1.asset_id == asset_id))
    |> Enum.reverse()
    |> Enum.find(&(&1.action in ["disposed", "disposal_reversed"]))
    |> case do
      %{action: "disposed"} = event -> event
      _ -> nil
    end
  end

  defp asset_charges(scope, company_id, asset_id) do
    runs = all(Run, scope, company_id) |> Map.new(&{&1.id, &1})

    events = all(Event, scope, company_id)

    reversals =
      events
      |> Enum.filter(&(&1.action == "run_reversed"))
      |> Map.new(&{&1.run_id, public(&1)})

    void =
      events
      |> Enum.find(&(&1.asset_id == asset_id and &1.action == "acquisition_voided"))
      |> then(&(&1 && public(&1)))

    query(RunItem, scope, company_id)
    |> where([i], i.asset_id == ^asset_id)
    |> Repo.all()
    |> Enum.map(fn item ->
      run = Map.fetch!(runs, item.run_id)

      %{
        amount: Decimal.normalize(item.amount),
        run_id: run.id,
        period: run.period,
        entry_number: run.entry_number,
        recorded_by_user_id: run.recorded_by_user_id,
        recorded_by_impersonator_id: run.recorded_by_impersonator_id,
        recorded_at: run.recorded_at,
        reversal: charge_reversal(Map.get(reversals, run.id), void)
      }
    end)
  end

  defp charge_reversal(nil, void), do: void
  defp charge_reversal(reversal, nil), do: reversal
  defp charge_reversal(reversal, void), do: Enum.min_by([reversal, void], & &1.event_number)

  defp reversed_run?(scope, company_id, id),
    do:
      query(Event, scope, company_id)
      |> where([e], e.run_id == ^id and e.action == "run_reversed")
      |> Repo.exists?()

  defp run_view(scope, company_id, run) do
    public(run)
    |> Map.put(:reversed?, reversed_run?(scope, company_id, run.id))
    |> Map.put(
      :exceptions,
      query(Asset, scope, company_id)
      |> where(
        [a],
        a.id in subquery(
          query(RunException, scope, company_id)
          |> where([x], x.run_id == ^run.id)
          |> select([x], x.asset_id)
        )
      )
      |> order_by([a], a.asset_number)
      |> select([a], %{
        asset_id: a.id,
        asset_number: a.asset_number,
        description: a.description
      })
      |> Repo.all()
      |> Enum.map(&Map.put(&1, :reason, :acquisition_reversed))
    )
    |> Map.put(
      :items,
      query(RunItem, scope, company_id)
      |> where([i], i.run_id == ^run.id)
      |> Repo.all()
      |> Enum.map(&public/1)
    )
  end

  defp authorize(scope, company_id, capability) do
    case Company.authorize_company_target(scope, company_id, capability) do
      {:ok, _} -> :ok
      {:error, :not_found} -> {:error, :company_not_found}
      error -> error
    end
  end

  # Roll back the entire accounting operation before returning any Ledger
  # refusal. No audit or status row is recorded after a failed joined write.
  defp write(scope, company_id, capability, fun) do
    with :ok <- authorize(scope, company_id, capability) do
      Repo.transaction(fn ->
        with {:ok, _} <- Company.lock_writable_company(scope, company_id),
             {:ok, result} <- fun.() do
          result
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end
end
