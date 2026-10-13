defmodule Bilimbi.Finance.Payroll.PeopleSource.Installed do
  @moduledoc false
  # The source over the installed payroll and claims facades, found by
  # descriptor ID at run time. The calls are dynamic on purpose: see
  # `Bilimbi.Finance.Payroll.PeopleSource`.
  #
  # The payroll facade lists a company's runs with the setup each froze and,
  # per run, its output: the calculation (lines of `item_code`, `direction`,
  # and `amount`) and the independent decision. A run is finalised when its
  # decision is an approval. The claims facade lists an operator's queue by
  # status; approved and reimbursed claims both carry an approved amount. A
  # claim's approval time is stored as naive UTC; its ledger date is the
  # company's local calendar date of it.
  @behaviour Bilimbi.Finance.Payroll.PeopleSource

  alias Bilimbi.Finance.Payroll.CompanyTime
  alias Bilimbi.Finance.Payroll.PeopleSource

  @impl true
  def payroll_runs(scope, company_id) do
    with {:ok, %{payroll: payroll}} <- facades(),
         {:ok, %{runs: runs}} <- apply(payroll, :setup, [scope, company_id]) do
      runs
      |> Enum.sort_by(& &1.id)
      |> Enum.reduce_while({:ok, []}, fn run, {:ok, acc} ->
        case run_view(payroll, scope, company_id, run) do
          {:ok, view} -> {:cont, {:ok, [view | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, views} -> {:ok, Enum.reverse(views)}
        error -> error
      end
    end
  end

  @impl true
  def payroll_run(scope, company_id, run_id) do
    with {:ok, %{payroll: payroll}} <- facades(),
         {:ok, %{runs: runs}} <- apply(payroll, :setup, [scope, company_id]) do
      case Enum.find(runs, &(&1.id == run_id)) do
        nil -> {:error, :not_found}
        run -> run_view(payroll, scope, company_id, run)
      end
    end
  end

  @impl true
  def claims(scope, company_id) do
    with {:ok, %{claims: claims}} <- facades(),
         {:ok, categories} <- category_codes(claims, scope, company_id),
         {:ok, approved} <- apply(claims, :claim_queue, [scope, company_id, "approved"]),
         {:ok, reimbursed} <- apply(claims, :claim_queue, [scope, company_id, "reimbursed"]) do
      timezone = CompanyTime.timezone(scope, company_id)

      {:ok,
       (approved ++ reimbursed)
       |> Enum.sort_by(& &1.id)
       |> Enum.map(&claim_view(&1, categories, timezone))}
    end
  end

  defp run_view(payroll, scope, company_id, run) do
    with {:ok, output} <- apply(payroll, :run_output, [scope, company_id, run.id]) do
      period = run.snapshot["period"] || %{}
      decision = output.decision
      calculation = output.calculation

      status =
        cond do
          decision && decision.outcome == "approved" -> "approved"
          decision -> "rejected"
          calculation -> "calculated"
          run.locked_at -> "locked"
          true -> "open"
        end

      {:ok,
       %{
         id: run.id,
         reference: String.trim("#{period["code"]} #{run.currency}"),
         pay_date: pay_date(period["pay_on"]),
         currency_code: run.currency,
         status: status,
         finalised: status == "approved",
         components: components(calculation)
       }}
    end
  end

  defp pay_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp pay_date(_value), do: nil

  defp components(nil), do: []

  defp components(%{snapshot: %{"result" => %{"lines" => lines}}}) do
    lines
    |> Enum.group_by(&{&1["item_code"], &1["direction"]})
    |> Enum.map(fn {{code, direction}, rows} ->
      %{
        code: code,
        direction: direction,
        amount: Enum.reduce(rows, Decimal.new(0), &Decimal.add(Decimal.new(&1["amount"]), &2))
      }
    end)
    |> Enum.sort_by(&{&1.code, &1.direction})
  end

  defp components(_calculation), do: []

  defp category_codes(claims, scope, company_id) do
    with {:ok, types} <- apply(claims, :claim_types, [scope, company_id]),
         {:ok, categories} <- apply(claims, :categories, [scope, company_id]) do
      by_id = Map.new(categories, &{&1.id, &1.code})
      {:ok, Map.new(types, &{&1.id, {&1.code, Map.get(by_id, &1.category_id)}})}
    end
  end

  defp claim_view(claim, categories, timezone) do
    {type_code, category_code} = Map.get(categories, claim.claim_type_id, {nil, nil})

    %{
      id: claim.id,
      reference: String.trim("claim #{claim.id} #{type_code}"),
      approved_on: CompanyTime.local_date(claim.decided_at, timezone),
      currency_code: claim.currency,
      amount: claim.approved_amount,
      category_code: category_code,
      claim_type_code: type_code,
      status: claim.status
    }
  end

  defp facades do
    case PeopleSource.facades() do
      {:ok, facades} -> {:ok, facades}
      :unavailable -> {:error, :people_unavailable}
    end
  end
end
