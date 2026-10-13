defmodule Bilimbi.Finance.Sst.Registrations do
  @moduledoc false
  # A company's SST registration as numbered versions. The facade
  # authorizes every call and holds the company lock for writes.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Sst.{Records, Registration, ReturnEvent, TaxReturn}
  alias Ecto.Changeset

  @fields [
    :id,
    :version,
    :sales_tax_number,
    :service_tax_number,
    :period_months,
    :period_start,
    :service_tax_basis,
    :reason,
    :recorded_by_user_id,
    :recorded_by_impersonator_id,
    :recorded_at
  ]

  # What a version carries on from the one before it.
  @carried [
    :sales_tax_number,
    :service_tax_number,
    :period_months,
    :period_start,
    :service_tax_basis
  ]

  @doc "The latest version, or nil."
  def latest(scope, company_id) do
    Records.query(Registration, scope, company_id)
    |> order_by([r], desc: r.version)
    |> limit(1)
    |> Repo.one()
  end

  @doc "The latest version whose cycle starts on or before `date`, or nil."
  def governing(scope, company_id, %Date{} = date) do
    Records.query(Registration, scope, company_id)
    |> where([r], r.period_start <= ^date)
    |> order_by([r], desc: r.version)
    |> limit(1)
    |> Repo.one()
  end

  def get(scope, company_id, id), do: Records.get(Registration, scope, company_id, id)

  @doc "Every version, oldest first."
  def list(scope, company_id) do
    Records.query(Registration, scope, company_id)
    |> order_by([r], asc: r.version)
    |> Repo.all()
  end

  @doc """
  Records the next version from the latest one and `attributes`; a call
  that changes nothing records nothing. The cycle and the service tax basis
  change only from after the last finalised return's period.
  """
  def record(scope, company_id, attributes) do
    latest = latest(scope, company_id)
    {user_id, impersonator_id} = Records.actor_ids(scope)

    base = if latest, do: Map.take(latest, @carried), else: %{}

    changeset =
      %Registration{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        recorded_by_user_id: user_id,
        recorded_by_impersonator_id: impersonator_id
      }
      |> struct(base)
      |> Registration.changeset(attributes)
      |> validate_cycle(latest, reported_through(scope, company_id))

    cond do
      not changeset.valid? -> {:error, changeset}
      latest && unchanged?(changeset, latest) -> {:ok, view(latest)}
      true -> insert(changeset)
    end
  end

  defp insert(changeset) do
    case Repo.insert(changeset) do
      {:ok, registration} -> {:ok, view(registration)}
      error -> error
    end
  end

  @doc "The end of the latest period any finalised return reported, or nil."
  def reported_through(scope, company_id) do
    from(r in Records.query(TaxReturn, scope, company_id),
      join: e in ^Records.query(ReturnEvent, scope, company_id),
      on: e.return_id == r.id and e.action == "finalised",
      select: max(r.period_end)
    )
    |> Repo.one()
  end

  defp validate_cycle(changeset, nil, _reported_through), do: changeset
  defp validate_cycle(changeset, _latest, nil), do: changeset

  defp validate_cycle(changeset, latest, reported_through) do
    changed? =
      Enum.any?([:period_months, :period_start, :service_tax_basis], fn field ->
        Changeset.get_field(changeset, field) != Map.fetch!(latest, field)
      end)

    start = Changeset.get_field(changeset, :period_start)

    if changed? and start && Date.compare(start, reported_through) != :gt,
      do:
        Changeset.add_error(
          changeset,
          :period_start,
          "must fall after #{reported_through}, the end of the last finalised return's period, to change the cycle or basis"
        ),
      else: changeset
  end

  defp unchanged?(changeset, latest) do
    Enum.all?(@carried, &(Changeset.get_field(changeset, &1) == Map.fetch!(latest, &1)))
  end

  def view(nil), do: nil
  def view(registration), do: Map.take(registration, @fields)
end
