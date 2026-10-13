defmodule Bilimbi.Finance.Sst.Mappings do
  @moduledoc false
  # Which box each tax code of receivables and payables reports in. A
  # mapping is never changed: the next one for the same code replaces it,
  # and a return reads them through the mapping number it records. The
  # facade authorizes every call and holds the company lock for writes.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Payables
  alias Bilimbi.Finance.Receivables
  alias Bilimbi.Finance.Sst.{Form, Mapping, Records}
  alias Ecto.Changeset

  @fields [
    :id,
    :mapping_number,
    :source,
    :tax_code_id,
    :tax_code,
    :box,
    :reason,
    :recorded_by_user_id,
    :recorded_by_impersonator_id,
    :recorded_at
  ]

  @doc "The last mapping number the company recorded, 0 for none."
  def last_number(scope, company_id) do
    Records.query(Mapping, scope, company_id)
    |> select([m], coalesce(max(m.mapping_number), 0))
    |> Repo.one()
  end

  @doc "`%{{source, tax_code_id} => mapping}`: each code's latest mapping numbered through `through`."
  def at(scope, company_id, through) do
    Records.query(Mapping, scope, company_id)
    |> where([m], m.mapping_number <= ^through)
    |> distinct([m], [m.source, m.tax_code_id])
    |> order_by([m], asc: m.source, asc: m.tax_code_id, desc: m.mapping_number)
    |> Repo.all()
    |> Map.new(&{{&1.source, &1.tax_code_id}, view(&1)})
  end

  @doc "Every tax code of both sources with its current mapping (`nil` when none)."
  def tax_codes(scope, company_id) do
    with {:ok, receivables} <- Receivables.list_tax_codes(scope, company_id),
         {:ok, payables} <- Payables.list_tax_codes(scope, company_id) do
      current = at(scope, company_id, Records.max_bigint())

      {:ok,
       for {source, codes} <- [{"receivables", receivables}, {"payables", payables}],
           code <- codes do
         code
         |> Map.put(:source, source)
         |> Map.put(:mapping, Map.get(current, {source, code.id}))
       end}
    end
  end

  @doc "Every mapping recorded, oldest first; `limit` and `after` page them."
  def history(scope, company_id, options) do
    with {:ok, limit, cursor} <- Records.page_options(options) do
      {:ok,
       Records.query(Mapping, scope, company_id)
       |> Records.page(limit, cursor)
       |> Repo.all()
       |> Enum.map(&view/1)}
    end
  end

  @doc """
  Maps a tax code of `source` to `box` (nil: not reported), as a new
  mapping; mapping it to the box it already has records nothing.
  """
  def record(scope, company_id, attributes) do
    source = Records.fetch(attributes, :source)
    tax_code_id = Records.id(Records.fetch(attributes, :tax_code_id))
    box = blank_box(Records.fetch(attributes, :box))

    with {:ok, code} <- tax_code(scope, company_id, source, tax_code_id),
         :ok <- valid_box(source, box) do
      current = Map.get(at(scope, company_id, Records.max_bigint()), {source, code.id})

      if current && current.box == box do
        {:ok, current}
      else
        {user_id, impersonator_id} = Records.actor_ids(scope)

        %Mapping{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          source: source,
          tax_code_id: code.id,
          tax_code: code.code,
          box: box,
          recorded_by_user_id: user_id,
          recorded_by_impersonator_id: impersonator_id
        }
        |> Mapping.changeset(attributes)
        |> Repo.insert()
        |> case do
          {:ok, mapping} -> {:ok, view(mapping)}
          error -> error
        end
      end
    end
  end

  defp tax_code(scope, company_id, source, tax_code_id) do
    listed =
      case source do
        "receivables" -> Receivables.list_tax_codes(scope, company_id)
        "payables" -> Payables.list_tax_codes(scope, company_id)
        _other -> {:error, :invalid_source}
      end

    with {:ok, codes} <- listed do
      case Enum.find(codes, &(&1.id == tax_code_id)) do
        nil -> {:error, :tax_code_not_found}
        code -> {:ok, code}
      end
    end
  end

  defp valid_box(_source, nil), do: :ok

  defp valid_box(source, box) do
    if Enum.any?(Form.mappable_boxes(source), &(&1.key == box)),
      do: :ok,
      else:
        {:error,
         %Mapping{}
         |> Changeset.change()
         |> Changeset.add_error(:box, "is not a box a #{source} tax code reports in")}
  end

  defp blank_box(nil), do: nil
  defp blank_box(box) when is_binary(box), do: if(String.trim(box) == "", do: nil, else: box)
  defp blank_box(box), do: box

  def view(mapping), do: Map.take(mapping, @fields)
end
