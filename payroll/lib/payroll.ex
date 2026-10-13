defmodule Bilimbi.Finance.Payroll do
  @moduledoc """
  Payroll and staff claims in the books: each company's mapping of payroll
  components and claim categories to ledger accounts, the postings of its
  finalised payroll runs and approved claims through the ledger, their
  reversals, and the record of every attempt.

  Every function takes the validated `Bilimbi.Base.Tenancy.Scope` it was
  handed and an explicit company ID. Reads authorize `finance.payroll.view`
  and writes their own capability for the scope's signed-in actor and the
  target company at the moment they run, through
  `Bilimbi.Core.Company.authorize_company_target/3`: a system scope, a
  missing grant, or a sibling company without tenant-wide reach is
  `{:error, :unauthorized}`, and a company the scope cannot see is
  `{:error, :company_not_found}`. A write then holds
  `Bilimbi.Core.Company.lock_writable_company/2` for its transaction, so an
  archived company is `{:error, :company_archived}` and the company's
  payroll writes run one at a time.

  The runs and claims come from the installed source
  (`Bilimbi.Finance.Payroll.PeopleSource`; People's payroll and claims when
  mounted), read with the same scope, so a call that lists or posts them
  also needs the source's own read capabilities. Posting goes through the
  `Bilimbi.Finance.Ledger` facade with the same scope, so it also needs
  `finance.ledger.view` and `finance.ledger.entries.post`. Without the
  source nothing is listed or posted, and `people_available?/0` says so;
  what was posted is still read from this module's own events.

  A run or claim posts once: its `posted` event names the entry, the
  database refuses a second, and a posting is undone only by a reversal
  entry recorded as a `reversed` event with its reason. A failed attempt is
  a `posting_failed` or `reversal_failed` event with its reason. Nothing is
  deleted; the database refuses the same things on its own (see the
  migration). A change to the settings or a mapping is recorded with who
  made it, why, and the values before and after, and never altered.

  Results are plain maps; the schemas stay private to this module.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Payroll.CompanyTime
  alias Bilimbi.Finance.Payroll.Events
  alias Bilimbi.Finance.Payroll.Mapping
  alias Bilimbi.Finance.Payroll.MappingChange
  alias Bilimbi.Finance.Payroll.PeopleSource
  alias Bilimbi.Finance.Payroll.Posting
  alias Bilimbi.Finance.Payroll.Reason
  alias Bilimbi.Finance.Payroll.Settings
  alias Bilimbi.Finance.Payroll.SettingsChange
  alias Ecto.Changeset

  @view "finance.payroll.view"
  @manage_settings "finance.payroll.settings.manage"
  @post_postings "finance.payroll.postings.post"

  @run_kind "payroll_run"
  @claim_kind "claim"

  @expense_account_types ~w(asset expense)
  @liability_account_types ~w(liability)

  @max_bigint 9_223_372_036_854_775_807

  @type refusal :: :unauthorized | :company_not_found
  @type write_refusal :: refusal() | :company_archived

  @doc "The capability every payroll read asks for."
  def view_capability, do: @view

  @doc "The capability that sets the posting accounts and the mappings."
  def manage_settings_capability, do: @manage_settings

  @doc "The capability that posts runs and claims and reverses postings."
  def post_postings_capability, do: @post_postings

  @doc "The mapping kinds: `component` (a payroll pay item) and `claim_category`."
  def mapping_kinds, do: Mapping.kinds()

  @doc "The directions a payroll component is mapped by: `earning`, `deduction`, `employer`."
  def component_directions, do: Mapping.component_directions()

  @doc "Whether a source of runs and claims is installed."
  @spec people_available?() :: boolean()
  def people_available?, do: PeopleSource.available?()

  ## Settings

  @doc """
  The company's posting accounts: `company_id`, `net_pay_account_id` (the
  liability a run's net pay is owed on), and `claims_payable_account_id`
  (the liability an approved claim is owed on), or
  `{:error, :payroll_not_configured}` before `put_settings/3`.
  """
  @spec get_settings(Scope.t(), term()) ::
          {:ok, map()} | {:error, refusal() | :payroll_not_configured}
  def get_settings(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case settings(scope, company_id) do
        nil -> {:error, :payroll_not_configured}
        settings -> {:ok, settings_view(settings)}
      end
    end
  end

  @doc """
  Sets `net_pay_account_id` and `claims_payable_account_id`, each an active
  liability account of the company's chart. A change applies to postings
  made afterwards; each posting keeps the entry it made. An optional
  `reason` is kept with the change in `list_settings_changes/2`.
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
          |> check_account(:net_pay_account_id, accounts, @liability_account_types)
          |> check_account(:claims_payable_account_id, accounts, @liability_account_types)

        changeset
        |> Repo.insert_or_update()
        |> record_settings_change(scope, previous, changeset, attributes)
        |> public_result(&settings_view/1)
      end
    end)
  end

  @doc """
  The changes made to the settings, oldest first: the `old_` and `new_`
  values of each account (the `old_` ones nil the first time), the optional
  `reason`, who made it (`changed_by_user_id`, `changed_by_impersonator_id`),
  and `changed_at`, the database's time.
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

  ## Mappings

  @doc """
  The company's mappings, ordered by kind, code, and direction: each
  `%{id, kind, code, direction, expense_account_id, liability_account_id}`.
  A `component` mapping is a payroll pay item `code` with the `direction`
  its lines carry (`earning`, `deduction`, `employer`); a `claim_category`
  mapping is a claim category `code` with direction `claim`.
  """
  @spec list_mappings(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_mappings(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view),
         do: {:ok, scope |> mappings(company_id) |> Enum.map(&mapping_view/1)}
  end

  @doc """
  Adds or changes the mapping of `kind`, `code`, and `direction`: an
  earning or a claim category names `expense_account_id` (an active asset
  or expense account); a deduction names `liability_account_id` (an active
  liability account); an employer contribution names both. The key of an
  existing mapping is kept and its accounts change. An optional `reason` is
  kept with the change in `list_mapping_changes/2`.
  """
  @spec put_mapping(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | Changeset.t()}
  def put_mapping(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_settings, fn ->
      with {:ok, accounts} <- ledger_accounts(scope, company_id) do
        key_changeset =
          %Mapping{tenant_id: Scope.tenant_id(scope), company_id: company_id}
          |> Mapping.changeset(attributes)

        previous = key_changeset.valid? && mapping(scope, company_id, key_changeset)

        changeset =
          if previous,
            do: Mapping.account_changeset(previous, attributes),
            else: key_changeset

        changeset =
          changeset
          |> check_account(:expense_account_id, accounts, @expense_account_types)
          |> check_account(:liability_account_id, accounts, @liability_account_types)

        changeset
        |> Repo.insert_or_update()
        |> record_mapping_change(scope, previous || nil, changeset, attributes)
        |> public_result(&mapping_view/1)
      end
    end)
  end

  @doc """
  The changes made to the mappings, oldest first: `mapping_id`, the `old_`
  and `new_` account IDs (the `old_` ones nil the first time), the optional
  `reason`, who made it, and `changed_at`, the database's time.
  """
  @spec list_mapping_changes(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_mapping_changes(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok,
       from(c in Tenancy.scope_query(MappingChange, scope),
         where: c.company_id == ^company_id,
         order_by: [asc: c.id]
       )
       |> Repo.all()
       |> Enum.map(&Map.take(&1, MappingChange.fields()))}
    end
  end

  ## Runs and claims

  @doc """
  The company's payroll runs as the source lists them, oldest first, each
  with `posting` (the posting view when it posted, else nil) and
  `last_failure` (the latest failed attempt since, else nil). Without a
  source, `{:error, :people_unavailable}`; a source refusal (the actor
  lacks its read capability) is passed through.
  """
  @spec list_payroll_runs(Scope.t(), term()) ::
          {:ok, [map()]} | {:error, refusal() | :people_unavailable | term()}
  def list_payroll_runs(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, runs} <- PeopleSource.payroll_runs(scope, company_id) do
      standings = Events.standings(scope, company_id)
      {:ok, Enum.map(runs, &with_standing(&1, @run_kind, standings))}
    end
  end

  @doc "The company's approved claims as the source lists them, as `list_payroll_runs/2` shows runs."
  @spec list_claims(Scope.t(), term()) ::
          {:ok, [map()]} | {:error, refusal() | :people_unavailable | term()}
  def list_claims(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, claims} <- PeopleSource.claims(scope, company_id) do
      standings = Events.standings(scope, company_id)
      {:ok, Enum.map(claims, &with_standing(&1, @claim_kind, standings))}
    end
  end

  ## Postings

  @doc """
  Every posting of the company, newest first, from this module's own
  events, so it reads without the source: `%{id, source_kind, source_id,
  source_reference, entry_id, entry_number, entry_date, total,
  currency_code, posted_by_user_id, posted_by_impersonator_id, posted_at,
  reversal}`, where `reversal` is nil or `%{entry_id, entry_number,
  entry_date, reason, reversed_by_user_id, reversed_by_impersonator_id,
  reversed_at}`, and `last_failure` as `list_payroll_runs/2` shows it.
  """
  @spec list_postings(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_postings(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok,
       scope
       |> Events.standings(company_id)
       |> Map.values()
       |> Enum.filter(& &1.posting)
       |> Enum.map(&Map.put(&1.posting, :last_failure, &1.last_failure))
       |> Enum.sort_by(& &1.id, :desc)}
    end
  end

  @doc "One posting, as `list_postings/2` shows it, by the ID of its `posted` event."
  @spec get_posting(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :posting_not_found}
  def get_posting(%Scope{} = scope, company_id, posting_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, posting_id} <- positive_id(posting_id),
         %{} = posted <- Events.posted_by_id(scope, company_id, posting_id) do
      standing =
        scope
        |> Events.for_source(company_id, posted.source_kind, posted.source_id)
        |> Events.standing()

      {:ok, Map.put(standing.posting, :last_failure, standing.last_failure)}
    else
      nil -> {:error, :posting_not_found}
      :error -> {:error, :posting_not_found}
      error -> error
    end
  end

  @doc """
  Every posting event of the company, oldest first: `posted`,
  `posting_failed`, `reversed`, and `reversal_failed`, each with its
  source, entry (when it has one), reason, actor, and database-stamped time.
  """
  @spec list_posting_events(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_posting_events(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view),
         do: {:ok, scope |> Events.list(company_id) |> Enum.map(&Events.event_view/1)}
  end

  @doc """
  Posts the finalised payroll run's entry, dated its pay date, and records
  the outcome. Refused without an attempt when the source is not installed
  (`:people_unavailable`), the run is unknown (`:source_not_found`) or not
  finalised (`:not_finalised`), or it posted already (`:already_posted`).
  An attempt the ledger or the configuration refuses is recorded as a
  `posting_failed` event and returned as `{:error, {:failed, reason}}`;
  `list_payroll_runs/2` shows it as the run's `last_failure` until a retry
  succeeds. See `Bilimbi.Finance.Payroll.Posting` for the entry's lines.
  """
  @spec post_payroll_run(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error,
             refusal()
             | :people_unavailable
             | :source_not_found
             | :not_finalised
             | :already_posted
             | {:failed, String.t()}}
  def post_payroll_run(%Scope{} = scope, company_id, run_id) do
    with :ok <- authorize(scope, company_id, @post_postings),
         {:ok, run_id} <- positive_id(run_id),
         {:ok, run} <- source(PeopleSource.payroll_run(scope, company_id, run_id)),
         true <- run.finalised || {:error, :not_finalised} do
      Posting.post_run(
        scope,
        company_id,
        run_id,
        fn -> PeopleSource.payroll_run(scope, company_id, run_id) end,
        fn -> configuration(scope, company_id) end
      )
    else
      :error -> {:error, :source_not_found}
      error -> error
    end
  end

  @doc """
  Posts the approved claim's entry, dated the company's local date of its
  approval, and records the outcome, as `post_payroll_run/3` does for a run.
  """
  @spec post_claim(Scope.t(), term(), term()) ::
          {:ok, map()}
          | {:error,
             refusal()
             | :people_unavailable
             | :source_not_found
             | :already_posted
             | {:failed, String.t()}}
  def post_claim(%Scope{} = scope, company_id, claim_id) do
    with {:ok, [{_claim_id, outcome}]} <- post_claims(scope, company_id, [claim_id]),
         do: outcome
  end

  @doc """
  Posts each of the claims `claim_ids` names, as `post_claim/3` does, and
  returns `{:ok, [{claim_id, outcome}]}` in the order given. The source's
  claims are read once for the whole batch and every claim is posted from
  that read, so a batch costs one read, not one per claim; a claim already
  posted is refused under the company's lock whatever the read says. A
  refusal that holds for the whole batch (`:unauthorized`,
  `:people_unavailable`, ...) is returned alone.
  """
  @spec post_claims(Scope.t(), term(), [term()]) ::
          {:ok, [{term(), {:ok, map()} | {:error, term()}}]}
          | {:error, refusal() | :people_unavailable | term()}
  def post_claims(%Scope{} = scope, company_id, claim_ids) when is_list(claim_ids) do
    with :ok <- authorize(scope, company_id, @post_postings),
         {:ok, claims} <- PeopleSource.claims(scope, company_id) do
      by_id = Map.new(claims, &{&1.id, &1})

      {:ok,
       for claim_id <- claim_ids do
         {claim_id, post_listed_claim(scope, company_id, by_id, claim_id)}
       end}
    end
  end

  defp post_listed_claim(scope, company_id, by_id, claim_id) do
    with {:ok, id} <- positive_id(claim_id),
         {:ok, claim} <- Map.fetch(by_id, id) do
      Posting.post_claim(scope, company_id, id, fn -> {:ok, claim} end, fn ->
        configuration(scope, company_id)
      end)
    else
      _unknown -> {:error, :source_not_found}
    end
  end

  @doc """
  Reverses a posting's entry with `reason` (required, at most 500
  characters) on `entry_date` (the company's local today unless given; not before the
  original's, and in an open period), through `Ledger.reverse_entry/4`, and
  records it as a `reversed` event. A posting is reversed once
  (`:already_reversed`); a refused attempt is recorded as a
  `reversal_failed` event and returned as `{:error, {:failed, reason}}`.
  A reversed source is not posted again: its correction is a new entry in
  the ledger.
  """
  @spec reverse_posting(Scope.t(), term(), term(), map()) ::
          {:ok, map()}
          | {:error,
             refusal()
             | :posting_not_found
             | :already_reversed
             | Changeset.t()
             | {:failed, String.t()}}
  def reverse_posting(%Scope{} = scope, company_id, posting_id, attributes)
      when is_map(attributes) do
    with :ok <- authorize(scope, company_id, @post_postings),
         {:ok, posting_id} <- positive_id(posting_id),
         {:ok, attributes} <- reversal_attributes(scope, company_id, attributes) do
      Posting.reverse(scope, company_id, %{id: posting_id}, attributes)
    else
      :error -> {:error, :posting_not_found}
      error -> error
    end
  end

  defp reversal_attributes(scope, company_id, attributes) do
    types = %{reason: :string, entry_date: :date}

    changeset =
      {%{}, types}
      |> Changeset.cast(attributes, Map.keys(types))
      |> Changeset.update_change(:reason, &Reason.trim/1)
      |> Changeset.validate_required([:reason])
      |> Changeset.validate_length(:reason, max: 500)

    if changeset.valid? do
      values = Changeset.apply_changes(changeset)
      {:ok, Map.put_new(values, :entry_date, CompanyTime.today(scope, company_id))}
    else
      {:error, changeset}
    end
  end

  defp source({:ok, source}), do: {:ok, source}
  defp source({:error, :not_found}), do: {:error, :source_not_found}
  defp source({:error, reason}), do: {:error, reason}

  defp configuration(scope, company_id) do
    %{
      settings: settings(scope, company_id),
      mappings: scope |> mappings(company_id) |> Map.new(&{{&1.kind, &1.code, &1.direction}, &1})
    }
  end

  defp with_standing(source, kind, standings) do
    standing = Map.get(standings, {kind, source.id}, %{posting: nil, last_failure: nil})
    Map.merge(source, standing)
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

  defp positive_id(id) when is_integer(id) and id in 1..@max_bigint, do: {:ok, id}

  defp positive_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> positive_id(value)
      _other -> :error
    end
  end

  defp positive_id(_id), do: :error

  # A change is kept in the transaction that makes it; a call that changes
  # nothing keeps nothing.
  defp record_settings_change({:ok, settings} = saved, scope, previous, changeset, attributes) do
    if previous && changeset.changes == %{} do
      saved
    else
      %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

      values =
        for field <- Settings.account_fields(), into: %{} do
          {{:"old_#{field}", previous && Map.fetch!(previous, field)},
           {:"new_#{field}", Map.fetch!(settings, field)}}
        end
        |> Enum.flat_map(&Tuple.to_list/1)
        |> Map.new()

      struct(
        SettingsChange,
        Map.merge(values, %{
          tenant_id: settings.tenant_id,
          company_id: settings.company_id,
          changed_by_user_id: user_id,
          changed_by_impersonator_id: impersonator_id
        })
      )
      |> SettingsChange.changeset(Map.take(attributes, [:reason, "reason"]))
      |> Repo.insert()
      |> kept(saved)
    end
  end

  defp record_settings_change(error, _scope, _previous, _changeset, _attributes), do: error

  defp record_mapping_change({:ok, mapping} = saved, scope, previous, changeset, attributes) do
    if previous && changeset.changes == %{} do
      saved
    else
      %Actor{user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)

      %MappingChange{
        tenant_id: mapping.tenant_id,
        company_id: mapping.company_id,
        mapping_id: mapping.id,
        old_expense_account_id: previous && previous.expense_account_id,
        new_expense_account_id: mapping.expense_account_id,
        old_liability_account_id: previous && previous.liability_account_id,
        new_liability_account_id: mapping.liability_account_id,
        changed_by_user_id: user_id,
        changed_by_impersonator_id: impersonator_id
      }
      |> MappingChange.changeset(Map.take(attributes, [:reason, "reason"]))
      |> Repo.insert()
      |> kept(saved)
    end
  end

  defp record_mapping_change(error, _scope, _previous, _changeset, _attributes), do: error

  defp kept({:ok, _change}, saved), do: saved
  defp kept({:error, _changeset} = error, _saved), do: error

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

      %{account_type: type} ->
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

  ## Queries

  defp settings(scope, company_id) do
    from(s in Tenancy.scope_query(Settings, scope), where: s.company_id == ^company_id)
    |> Repo.one()
  end

  defp mappings(scope, company_id) do
    from(m in Tenancy.scope_query(Mapping, scope),
      where: m.company_id == ^company_id,
      order_by: [asc: m.kind, asc: m.code, asc: m.direction]
    )
    |> Repo.all()
  end

  defp mapping(scope, company_id, changeset) do
    kind = Changeset.get_field(changeset, :kind)
    code = Changeset.get_field(changeset, :code)
    direction = Changeset.get_field(changeset, :direction)

    from(m in Tenancy.scope_query(Mapping, scope),
      where: m.company_id == ^company_id,
      where: m.kind == ^kind and m.code == ^code and m.direction == ^direction
    )
    |> Repo.one()
  end

  ## Views

  defp settings_view(settings),
    do: Map.take(settings, [:company_id | Settings.account_fields()])

  defp mapping_view(mapping),
    do: Map.take(mapping, [:id | Mapping.key_fields() ++ Mapping.account_fields()])
end
