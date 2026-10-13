defmodule Bilimbi.Finance.Payroll.PeopleSource do
  @moduledoc """
  The seam to the payroll runs and staff claims this module posts, in an
  optional Domain this module never names.

  Finance builds and runs without People. `installed/0` finds the source
  among the module descriptors Base Module Registry recorded for the
  loaded applications, by the descriptor IDs `people/payroll` and
  `people/claims`, the stable logical IDs the composition model names
  modules by, and calls their facades by the namespace each descriptor
  declares. Nothing here aliases a `Bilimbi.People` module: the descriptor
  is the contract, Bilimbi's `graph_edges` gate refuses an undeclared
  alias, and declaring the edge would make Finance fail to compose without
  People. When either module is not loaded the source is `:unavailable`:
  nothing can be listed or posted, and what was posted is still read from
  this module's own events.

  Every read takes the scope the payroll call was handed, so the actor also
  holds the source's own capabilities (for People, `people.payroll.view`
  to read runs and `people.claims.approve` to read other employees'
  claims); the source refuses otherwise, as any facade does.

  The behaviour is what the source answers, in meta-terms:

    * `payroll_runs/2` lists the company's runs, each `%{id, reference,
      pay_date, currency_code, status, finalised, components}`, and
      `payroll_run/3` is one of them or `{:error, :not_found}`. `finalised`
      is true once the run's figures are final and approved; `components`
      are its lines summed per pay item `code` and `direction` (`earning`,
      `deduction`, or `employer`), each `%{code, direction, amount}`.
    * `claims/2` lists the company's approved claims (reimbursed ones
      included: they were approved first), each `%{id, reference,
      approved_on, currency_code, amount, category_code, claim_type_code,
      status}`, and `claim/3` is one of them or `{:error, :not_found}`.

  A test substitutes a source through the `:people_source` key of this
  module's application environment.
  """

  alias Bilimbi.Base.Tenancy.Scope

  @payroll_id "people/payroll"
  @claims_id "people/claims"

  @type run :: %{
          id: pos_integer(),
          reference: String.t(),
          pay_date: Date.t(),
          currency_code: String.t(),
          status: String.t(),
          finalised: boolean(),
          components: [%{code: String.t(), direction: String.t(), amount: Decimal.t()}]
        }

  @type claim :: %{
          id: pos_integer(),
          reference: String.t(),
          approved_on: Date.t(),
          currency_code: String.t(),
          amount: Decimal.t(),
          category_code: String.t() | nil,
          claim_type_code: String.t() | nil,
          status: String.t()
        }

  @callback payroll_runs(Scope.t(), term()) :: {:ok, [run()]} | {:error, term()}
  @callback payroll_run(Scope.t(), term(), term()) :: {:ok, run()} | {:error, term()}
  @callback claims(Scope.t(), term()) :: {:ok, [claim()]} | {:error, term()}
  @callback claim(Scope.t(), term(), term()) :: {:ok, claim()} | {:error, term()}

  @doc "The source in use: the test substitute, else the installed one, else `:unavailable`."
  @spec source() :: module() | :unavailable
  def source do
    case Application.get_env(:bilimbi_finance_payroll, :people_source) do
      nil -> installed()
      module when is_atom(module) -> module
    end
  end

  @doc "Whether a source is installed, so runs and claims can be listed and posted."
  @spec available?() :: boolean()
  def available?, do: source() != :unavailable

  @doc "The company's payroll runs, through the source in use."
  @spec payroll_runs(Scope.t(), term()) :: {:ok, [run()]} | {:error, term()}
  def payroll_runs(%Scope{} = scope, company_id), do: call(:payroll_runs, [scope, company_id])

  @doc "One payroll run, through the source in use."
  @spec payroll_run(Scope.t(), term(), term()) :: {:ok, run()} | {:error, term()}
  def payroll_run(%Scope{} = scope, company_id, run_id),
    do: call(:payroll_run, [scope, company_id, run_id])

  @doc "The company's approved claims, through the source in use."
  @spec claims(Scope.t(), term()) :: {:ok, [claim()]} | {:error, term()}
  def claims(%Scope{} = scope, company_id), do: call(:claims, [scope, company_id])

  @doc "One approved claim, through the source in use."
  @spec claim(Scope.t(), term(), term()) :: {:ok, claim()} | {:error, term()}
  def claim(%Scope{} = scope, company_id, claim_id),
    do: call(:claim, [scope, company_id, claim_id])

  defp call(function, arguments) do
    case source() do
      :unavailable -> {:error, :people_unavailable}
      module -> apply(module, function, arguments)
    end
  end

  @doc """
  The installed source: this module's own implementation over the payroll
  and claims facades when both are loaded, else `:unavailable`.
  """
  @spec installed() :: module() | :unavailable
  def installed do
    case facades() do
      {:ok, _facades} -> __MODULE__.Installed
      :unavailable -> :unavailable
    end
  end

  @doc false
  # The two facades' modules, from the descriptors of the applications this
  # runtime loaded: Mix records each module's descriptor as the `:bilimbi_module`
  # key of its application environment (`module_discovery.exs`). The
  # registry's `installed_modules!/0` would validate the whole graph's order,
  # which a package-local Domain runtime cannot satisfy; the host validated
  # it at boot, and here only the two IDs and their namespaces are read.
  def facades do
    namespaces =
      for {app, _description, _version} <- Application.loaded_applications(),
          descriptor <- [Application.get_env(app, :bilimbi_module)],
          is_map(descriptor) and Map.get(descriptor, :id) in [@payroll_id, @claims_id],
          into: %{},
          do: {descriptor.id, descriptor.namespace}

    with %{@payroll_id => payroll, @claims_id => claims} <- namespaces,
         true <- Code.ensure_loaded?(payroll) and Code.ensure_loaded?(claims) do
      {:ok, %{payroll: payroll, claims: claims}}
    else
      _missing -> :unavailable
    end
  end
end
