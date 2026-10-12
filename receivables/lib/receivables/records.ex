defmodule Bilimbi.Finance.Receivables.Records do
  @moduledoc false
  # Company-scoped reads every receivables query begins with.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope

  @max_bigint 9_223_372_036_854_775_807

  def max_bigint, do: @max_bigint

  def query(schema, scope, company_id) when is_integer(company_id) do
    from(r in Tenancy.scope_query(schema, scope), where: r.company_id == ^company_id)
  end

  def get(schema, scope, company_id, id) when is_integer(id) do
    schema |> query(scope, company_id) |> where([r], r.id == ^id) |> Repo.one()
  end

  def get(_schema, _scope, _company_id, _id), do: nil

  @doc "`limit` (1 to 500, default 100) and `after`, the last ID already read."
  def page_options(options) do
    limit = Keyword.get(options, :limit, 100)
    cursor = Keyword.get(options, :after)

    if is_integer(limit) and limit in 1..500 and
         (is_nil(cursor) or (is_integer(cursor) and cursor in 1..@max_bigint)),
       do: {:ok, limit, cursor},
       else: {:error, :invalid_option}
  end

  def page(query, limit, nil), do: query |> order_by([r], asc: r.id) |> limit(^limit)

  def page(query, limit, cursor),
    do: query |> where([r], r.id > ^cursor) |> order_by([r], asc: r.id) |> limit(^limit)

  @doc "The signed-in user and any impersonator behind an authorized scope."
  def actor_ids(scope) do
    %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)
    {user_id, impersonator_id}
  end

  def fetch(attributes, key), do: Map.get(attributes, key, Map.get(attributes, to_string(key)))
end
