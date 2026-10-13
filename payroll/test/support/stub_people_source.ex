defmodule Bilimbi.Finance.Payroll.StubPeopleSource do
  @moduledoc """
  A source of runs and claims for module tests, which run without People:
  it answers from the runs and claims a test `put_run!/1`s and
  `put_claim!/1`s, in the shape the real source answers, so a posting is
  proved on what it is given. Installed with `install!/0` through the
  `:people_source` application environment that
  `Bilimbi.Finance.Payroll.PeopleSource` reads; `uninstall!/0` removes it.
  """
  @behaviour Bilimbi.Finance.Payroll.PeopleSource

  alias Bilimbi.Base.Tenancy.Scope

  @env :bilimbi_finance_payroll
  @runs :stub_payroll_runs
  @claims :stub_claims

  @doc "Routes `PeopleSource` here for the rest of the test; the test's `on_exit` uninstalls it."
  def install!, do: Application.put_env(@env, :people_source, __MODULE__)

  def uninstall! do
    Application.delete_env(@env, :people_source)
    Application.delete_env(@env, @runs)
    Application.delete_env(@env, @claims)
    Application.delete_env(@env, :stub_refused_user)
    Application.delete_env(@env, :stub_claims_reads)
  end

  @doc "How many times `claims/2` has been read since the stub was installed."
  def claims_reads, do: Application.get_env(@env, :stub_claims_reads, 0)

  @doc """
  Puts one run: `id`, and optionally `company_id` (default 73), `reference`,
  `pay_date`, `currency_code` (default "XTS"), `status` and `finalised`
  (default "approved" and true), and `components`, each `%{code, direction,
  amount}` with the amount as a string. A later call for the same ID
  replaces it.
  """
  def put_run!(run) when is_map(run) do
    run =
      Map.merge(
        %{
          company_id: 73,
          reference: "2026-09 XTS",
          pay_date: ~D[2026-09-30],
          currency_code: "XTS",
          status: "approved",
          finalised: true,
          components: []
        },
        run
      )
      |> Map.update!(:components, fn components ->
        Enum.map(components, &Map.update!(&1, :amount, fn amount -> Decimal.new(amount) end))
      end)

    Application.put_env(@env, @runs, Map.put(runs(), run.id, run))
    run
  end

  @doc """
  Puts one approved claim: `id`, and optionally `company_id` (default 73),
  `reference`, `approved_on`, `currency_code` (default "XTS"), `amount` (a
  string), `category_code`, `claim_type_code`, and `status` (default
  "approved").
  """
  def put_claim!(claim) when is_map(claim) do
    claim =
      Map.merge(
        %{
          company_id: 73,
          reference: "claim #{claim.id} travel",
          approved_on: ~D[2026-09-15],
          currency_code: "XTS",
          amount: "25.00",
          category_code: "travel",
          claim_type_code: "mileage",
          status: "approved"
        },
        claim
      )
      |> Map.update!(:amount, &Decimal.new/1)

    Application.put_env(@env, @claims, Map.put(claims(), claim.id, claim))
    claim
  end

  @doc "The actor refused by name: every read for this scope's user is `{:error, :unauthorized}`."
  def refuse!(user_id), do: Application.put_env(@env, :stub_refused_user, user_id)

  defp runs, do: Application.get_env(@env, @runs, %{})
  defp claims, do: Application.get_env(@env, @claims, %{})

  @impl true
  def payroll_runs(%Scope{} = scope, company_id) do
    with :ok <- allowed(scope) do
      {:ok, runs() |> Map.values() |> of_company(company_id)}
    end
  end

  @impl true
  def payroll_run(%Scope{} = scope, company_id, run_id) do
    with :ok <- allowed(scope) do
      case Map.get(runs(), run_id) do
        %{company_id: ^company_id} = run -> {:ok, Map.delete(run, :company_id)}
        _other -> {:error, :not_found}
      end
    end
  end

  @impl true
  def claims(%Scope{} = scope, company_id) do
    with :ok <- allowed(scope) do
      Application.put_env(@env, :stub_claims_reads, claims_reads() + 1)
      {:ok, claims() |> Map.values() |> of_company(company_id)}
    end
  end

  defp of_company(rows, company_id) do
    rows
    |> Enum.filter(&(&1.company_id == company_id))
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&Map.delete(&1, :company_id))
  end

  defp allowed(scope) do
    if Scope.actor(scope).user_id == Application.get_env(@env, :stub_refused_user),
      do: {:error, :unauthorized},
      else: :ok
  end
end
