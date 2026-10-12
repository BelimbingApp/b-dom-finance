defmodule Bilimbi.Finance.Receivables.Customers do
  @moduledoc false
  # Customers: the parties a company invoices. The facade authorizes every
  # call and holds the company lock for writes.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Receivables.{Customer, Records}

  def list(scope, company_id) do
    Customer
    |> Records.query(scope, company_id)
    |> order_by([c], asc: c.code)
    |> Repo.all()
    |> Enum.map(&view/1)
  end

  def get(scope, company_id, customer_id) do
    case Records.get(Customer, scope, company_id, customer_id) do
      nil -> {:error, :customer_not_found}
      customer -> {:ok, view(customer)}
    end
  end

  def create(scope, company_id, attributes) do
    %Customer{tenant_id: Scope.tenant_id(scope), company_id: company_id}
    |> Customer.create_changeset(attributes)
    |> Repo.insert()
    |> result()
  end

  def update(scope, company_id, customer_id, attributes) do
    case Records.get(Customer, scope, company_id, customer_id) do
      nil -> {:error, :customer_not_found}
      customer -> customer |> Customer.update_changeset(attributes) |> Repo.update() |> result()
    end
  end

  def view(customer) do
    Map.take(customer, [:id, :code, :payment_terms_days, :active | Customer.party_fields()])
  end

  defp result({:ok, customer}), do: {:ok, view(customer)}
  defp result(error), do: error
end
