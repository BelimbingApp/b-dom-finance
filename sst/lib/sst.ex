defmodule Bilimbi.Finance.Sst do
  @moduledoc """
  Malaysia's Sales and Service Tax returns (SST-02): each company's SST
  registration, kept as numbered versions; which return box each tax code
  of receivables and payables reports in; and the returns of each tax for
  each taxable period, computed from posted documents only, reconciled
  against the tax accounts' ledger postings, finalised into a stored
  snapshot that never changes, and amended by a new return for the same
  period.

  Every function takes the validated `Bilimbi.Base.Tenancy.Scope` it was
  handed and an explicit company ID. Reads authorize `finance.sst.view` and
  writes their own capability for the scope's signed-in actor and the
  target company at the moment they run, through
  `Bilimbi.Core.Company.authorize_company_target/3`: a system scope, a
  missing grant, or a sibling company without tenant-wide reach is
  `{:error, :unauthorized}`, and a company the scope cannot see is
  `{:error, :company_not_found}`. A write then holds
  `Bilimbi.Core.Company.lock_writable_company/2` for its transaction, so an
  archived company is `{:error, :company_archived}` and the company's SST
  writes run one at a time.

  Documents and ledger figures are read only through the
  `Bilimbi.Finance.Receivables`, `Bilimbi.Finance.Payables`, and
  `Bilimbi.Finance.Ledger` facades with the same scope, so a call that
  computes a return's figures or maps a tax code also needs
  `finance.receivables.view`, `finance.payables.view`, and
  `finance.ledger.view`.

  Nothing is updated or deleted; the database refuses the same things on
  its own (see the migration). Results are plain maps; the schemas stay
  private to this module.
  """

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Sst.{Export, Form, Mappings, Periods, Records, Registration}
  alias Bilimbi.Finance.Sst.{Registrations, Returns}
  alias Ecto.Changeset

  @view "finance.sst.view"
  @manage_settings "finance.sst.settings.manage"
  @prepare_returns "finance.sst.returns.sst-prepare"
  @finalise_returns "finance.sst.returns.sst-finalise"
  @amend_returns "finance.sst.returns.sst-amend"

  @type refusal :: :unauthorized | :company_not_found
  @type write_refusal :: refusal() | :company_archived

  @doc "The capability every SST read asks for."
  def view_capability, do: @view

  @doc "The capability that records the registration and maps tax codes to boxes."
  def manage_settings_capability, do: @manage_settings

  @doc "The capability that opens, adjusts, and discards returns."
  def prepare_returns_capability, do: @prepare_returns

  @doc "The capability that finalises a return."
  def finalise_returns_capability, do: @finalise_returns

  @doc "The capability that opens an amendment of a finalised return."
  def amend_returns_capability, do: @amend_returns

  @doc "The two taxes a return is filed for: `sales_tax` and `service_tax`."
  def tax_types, do: Form.tax_types()

  @doc "The boxes of a tax's SST-02 form in the form's order (see `Bilimbi.Finance.Sst.Form`)."
  def boxes(tax_type), do: Form.boxes(tax_type)

  @doc "The boxes a tax code of `source` (`receivables` or `payables`) may be mapped to."
  def mappable_boxes(source), do: Form.mappable_boxes(source)

  @doc "When service tax may be due: `payment` (when paid) or `invoice` (when invoiced)."
  def service_tax_bases, do: Registration.bases()

  ## Registration

  @doc "The current registration, the latest version, or nil before any."
  @spec get_registration(Scope.t(), term()) :: {:ok, map() | nil} | {:error, refusal()}
  def get_registration(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view),
         do: {:ok, Registrations.view(Registrations.latest(scope, company_id))}
  end

  @doc "Every version of the registration, oldest first: its history."
  @spec list_registrations(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_registrations(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view),
         do: {:ok, Enum.map(Registrations.list(scope, company_id), &Registrations.view/1)}
  end

  @doc """
  Records the next version of the registration from the current one and
  `attributes`: `sales_tax_number` and `service_tax_number` (at least one,
  each shaped `A00-0000-00000000`; blank removes one), `period_months` (1 to
  12, default 2), `period_start` (the first period's first day),
  `service_tax_basis` (`payment`, the default, or `invoice` with the
  Director General's approval), and an optional `reason`. The cycle and the
  basis change only from a `period_start` after the last finalised
  return's period; a call that changes nothing records nothing.
  """
  @spec register(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def register(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_settings, fn ->
      Registrations.record(scope, company_id, attributes)
    end)
  end

  @doc """
  Up to `count` (1 to 24, default 6) taxable periods of the current
  registration's cycle, newest first, ending with the one that contains
  `date` (default today): `%{period_start, period_end, due_date}`. Empty
  before any registration.
  """
  @spec taxable_periods(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def taxable_periods(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    date = Keyword.get(options, :date, Date.utc_today())
    count = Keyword.get(options, :count, 6)

    with :ok <- authorize(scope, company_id, @view),
         true <- (match?(%Date{}, date) and count in 1..24) || {:error, :invalid_option} do
      case Registrations.latest(scope, company_id) do
        nil ->
          {:ok, []}

        registration ->
          {:ok,
           for {start, finish} <- Periods.recent(registration, date, count) do
             %{
               period_start: start,
               period_end: finish,
               due_date: Periods.due_date(registration, finish)
             }
           end}
      end
    end
  end

  ## Mappings

  @doc """
  Every tax code of receivables and payables (`%{source, id, code, name,
  rate, account_id, active, mapping}`), with its current mapping or nil.
  Also needs `finance.receivables.view` and `finance.payables.view`.
  """
  @spec list_tax_codes(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_tax_codes(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view),
         do: Mappings.tax_codes(scope, company_id)
  end

  @doc """
  Maps a tax code of `source` (`receivables` or `payables`) with
  `tax_code_id` to `box`, one of `mappable_boxes/1`, or to nil (deliberately
  not reported), with an optional `reason`, as the code's next mapping;
  returns that last mapping alone when nothing changes. Refusals:
  `:invalid_source`, `:tax_code_not_found`, and a changeset on `box`.
  """
  @spec map_tax_code(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | atom() | Changeset.t()}
  def map_tax_code(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_settings, fn ->
      Mappings.record(scope, company_id, attributes)
    end)
  end

  @doc "Every mapping recorded, oldest first: its history. `limit` and `after` page it."
  @spec list_mappings(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_mappings(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         do: Mappings.history(scope, company_id, options)
  end

  ## Returns

  @doc """
  The figures a `tax_type` return for the period starting `period_start`
  would show now, without opening one or counting any adjustment; see
  `get_return/3` for their shape. Options `through_entry_number` and
  `through_mapping_number` pin the reading.
  """
  @spec preview_return(Scope.t(), term(), map(), keyword()) ::
          {:ok, map()} | {:error, refusal() | atom()}
  def preview_return(%Scope{} = scope, company_id, attributes, options \\ [])
      when is_map(attributes) and is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, pins} <- pins(options),
         do: Returns.preview(scope, company_id, attributes, pins)
  end

  @doc """
  Opens the return of `tax_type` for the taxable period starting on
  `period_start`, under the registration version governing that date.
  Refusals: `:invalid_tax_type`, `:not_registered`, `:not_registered_for_tax`
  (no number for that tax), `:not_a_taxable_period`, `:return_open`,
  `:return_finalised` (amend it instead), and `:period_overlaps`.
  """
  @spec open_return(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | atom() | Changeset.t()}
  def open_return(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @prepare_returns, fn ->
      with {:ok, tax_return} <- Returns.open(scope, company_id, attributes),
           do: {:ok, Returns.view(tax_return, %{})}
    end)
  end

  @doc """
  Opens an amendment of a finalised return: a new return for its tax and
  period that names it, with a `reason`, carrying its standing adjustments.
  Only the period's latest finalised return is amended, and only while no
  other return of the period is open (`:return_not_finalised`,
  `:return_superseded`, `:return_open`). The amendment is prepared and
  finalised as any return; its version follows the one it amends.
  """
  @spec amend_return(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | atom() | Changeset.t()}
  def amend_return(%Scope{} = scope, company_id, return_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @amend_returns, fn ->
      with {:ok, tax_return} <- tax_return(scope, company_id, return_id),
           {:ok, amendment} <- Returns.amend(scope, company_id, tax_return, attributes),
           do: {:ok, Returns.view(amendment, %{})}
    end)
  end

  @doc """
  Adds an adjustment to an open return: `box` (one the form lets a preparer
  adjust), `taxable_amount` and `tax_amount` (non-negative, in the book's
  minor units, a column the box does not take left out or zero),
  `description`, and an optional `reference`. An adjustment adds to its
  box; a deduction box (item 13) deducts from the tax payable.
  """
  @spec add_adjustment(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | atom() | Changeset.t()}
  def add_adjustment(%Scope{} = scope, company_id, return_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @prepare_returns, fn ->
      with {:ok, tax_return} <- tax_return(scope, company_id, return_id),
           {:ok, adjustment} <- Returns.add_adjustment(scope, company_id, tax_return, attributes),
           do: {:ok, Map.from_struct(adjustment) |> Map.delete(:__meta__)}
    end)
  end

  @doc "Withdraws a standing adjustment of an open return with a `reason`, as an appended row."
  @spec withdraw_adjustment(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | atom() | Changeset.t()}
  def withdraw_adjustment(%Scope{} = scope, company_id, adjustment_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @prepare_returns, fn ->
      case Returns.fetch_adjustment(scope, company_id, Records.id(adjustment_id) || 0) do
        nil ->
          {:error, :adjustment_not_found}

        adjustment ->
          with {:ok, withdrawal} <-
                 Returns.withdraw_adjustment(scope, company_id, adjustment, attributes),
               do: {:ok, Map.from_struct(withdrawal) |> Map.delete(:__meta__)}
      end
    end)
  end

  @doc """
  Finalises an open return: refuses one whose period has not ended
  (`:period_not_ended`), one with tax under a tax code no mapping names
  (`{:unmapped_tax_codes, rows}`), and one with a code whose rate does not
  fit its box (`{:rate_mismatch, rows}`); otherwise records the figures read
  now with the entry, mapping, and adjustment numbers they were read at,
  the source rows, and the ledger reconciliation, difference included.
  Needs the receivables, payables, and ledger view capabilities.
  """
  @spec finalise_return(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, write_refusal() | atom() | tuple() | Changeset.t()}
  def finalise_return(%Scope{} = scope, company_id, return_id) do
    write(scope, company_id, @finalise_returns, fn ->
      with {:ok, tax_return} <- tax_return(scope, company_id, return_id),
           {:ok, finalised} <- Returns.finalise(scope, company_id, tax_return),
           do: {:ok, Returns.view(finalised, %{})}
    end)
  end

  @doc "Discards an open return with a `reason`; it stays on record, numbered."
  @spec discard_return(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | atom() | Changeset.t()}
  def discard_return(%Scope{} = scope, company_id, return_id, attributes)
      when is_map(attributes) do
    write(scope, company_id, @prepare_returns, fn ->
      with {:ok, tax_return} <- tax_return(scope, company_id, return_id),
           {:ok, discarded} <- Returns.discard(scope, company_id, tax_return, attributes),
           do: {:ok, Returns.view(discarded, %{})}
    end)
  end

  @doc """
  One return: its own fields, `status` (`open`, `finalised`, or
  `discarded`), `version` (once finalised: 1 for the period's first,
  then each amendment's), `events`, `registration`, `adjustments` (each
  with its `standing` flag and any `withdrawal`), `period_ended`, and
  `figures`, unless discarded: `boxes` in the form's order (`key`, `item`,
  `label`, `taxable_amount`, `tax_amount`), `tax_payable` (item 14),
  `sources` (each source row's contribution and box), `unmapped`,
  `rate_mismatches`, `accounts` (each tax account's ledger debits and
  credits against its documents', and the `difference`, never hidden),
  `currency_code`, `minor_units`, and the `through_entry_number` and
  `through_mapping_number` read at. An open return's figures are read now;
  a finalised one's are its stored snapshot, with `posted_since`, the boxes
  documents posted after it would change (nil when the actor may not read
  the documents; the snapshot needs only `finance.sst.view`). An amendment shows `amends`,
  the amended return and the boxes that changed.
  """
  @spec get_return(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :return_not_found | atom()}
  def get_return(%Scope{} = scope, company_id, return_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, tax_return} <- tax_return(scope, company_id, return_id),
         do: Returns.report(scope, company_id, tax_return)
  end

  @doc "The company's returns, oldest first, without figures; `tax_type`, `limit`, and `after` filter and page them."
  @spec list_returns(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_returns(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         do: Returns.list(scope, company_id, options)
  end

  @doc """
  A finalised return's figures read again from the live records at the
  entry, mapping, and adjustment numbers it recorded, and `reproduced`,
  whether every box, source row, and account figure equals its snapshot.
  """
  @spec reproduce_return(Scope.t(), term(), term()) ::
          {:ok, %{figures: map(), reproduced: boolean()}}
          | {:error, refusal() | :return_not_found | :return_not_finalised | atom()}
  def reproduce_return(%Scope{} = scope, company_id, return_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, tax_return} <- tax_return(scope, company_id, return_id),
         do: Returns.reproduce(scope, company_id, tax_return)
  end

  @doc """
  The return as CSV in the SST-02 item order (`%{filename, content}`), or
  as a printable HTML page (`format: :html`): a draft until finalised.
  """
  @spec export_return(Scope.t(), term(), term(), keyword()) ::
          {:ok, %{filename: String.t(), content: String.t(), content_type: String.t()}}
          | {:error, refusal() | :return_not_found | :return_discarded | atom()}
  def export_return(%Scope{} = scope, company_id, return_id, options \\ [])
      when is_list(options) do
    with {:ok, company} <- authorize_company(scope, company_id, @view),
         {:ok, tax_return} <- tax_return(scope, company_id, return_id),
         {:ok, report} <- Returns.report(scope, company_id, tax_return) do
      Export.render(report, company, Keyword.get(options, :format, :csv))
    end
  end

  ## Lookups and authorization

  defp tax_return(scope, company_id, return_id) do
    case Returns.fetch(scope, company_id, Records.id(return_id)) do
      nil -> {:error, :return_not_found}
      tax_return -> {:ok, tax_return}
    end
  end

  defp pins(options) do
    keys = [:through_entry_number, :through_mapping_number]

    if Keyword.keys(options) -- keys == [] and
         Enum.all?(options, fn {_key, value} ->
           is_integer(value) and value in 0..Records.max_bigint()
         end),
       do: {:ok, options},
       else: {:error, :invalid_option}
  end

  # The actor's current grant and company reach decide every call.
  defp authorize(scope, company_id, capability) do
    with {:ok, _company} <- authorize_company(scope, company_id, capability), do: :ok
  end

  defp authorize_company(scope, company_id, capability) do
    case Company.authorize_company_target(scope, company_id, capability) do
      {:ok, company} -> {:ok, company}
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
