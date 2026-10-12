defmodule Bilimbi.Finance.Einvoice.CodeLists do
  @moduledoc """
  The authority's code lists as reference data, with each company's
  overrides.

  An authority publishes its lists (document types, tax types, item
  classifications, states, countries, currencies, units, industry codes,
  payment means). The module ships them in `priv/code_lists/<authority>.json`
  with the date they were read and each list's source, compiled into this
  module: a refreshed list is a new file in a new release, reviewed like
  code. A company's override, stored in `finance_einvoice_code_overrides`,
  renames a code, retires it, or adds one the shipped file does not have yet,
  for that company only, so a list change the authority announces need not
  wait for a release.
  """

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Einvoice.CodeOverride

  @type codes :: %{String.t() => String.t()}

  @shipped_files Path.wildcard(Path.expand("../../priv/code_lists/*.json", __DIR__))
  for path <- @shipped_files, do: @external_resource(path)

  # authority => list => code => description
  @shipped Map.new(@shipped_files, fn path ->
             lists =
               path
               |> File.read!()
               |> Jason.decode!()
               |> Map.fetch!("lists")
               |> Map.new(fn {list, %{"codes" => codes}} ->
                 {list, Map.new(codes, fn [code, description] -> {code, description} end)}
               end)

             {Path.basename(path, ".json"), lists}
           end)

  @doc "The lists in an authority's shipped file."
  @spec lists(String.t()) :: [String.t()]
  def lists(authority), do: @shipped |> Map.get(authority, %{}) |> Map.keys() |> Enum.sort()

  @doc "One shipped list as the authority published it, code to description."
  @spec shipped(String.t(), String.t()) :: codes()
  def shipped(authority, list), do: @shipped |> Map.get(authority, %{}) |> Map.get(list, %{})

  @doc """
  The company's active codes in one list, code to description: the shipped
  list with the company's overrides applied.
  """
  @spec codes(Scope.t(), pos_integer(), String.t(), String.t()) :: codes()
  def codes(%Scope{} = scope, company_id, authority, list) do
    scope
    |> overrides_query(company_id, authority)
    |> where([o], o.list == ^list)
    |> Repo.all()
    |> apply_overrides(shipped(authority, list))
  end

  @doc "Every list's active codes for the company, by list name, in one query."
  @spec all_codes(Scope.t(), pos_integer(), String.t()) :: %{String.t() => codes()}
  def all_codes(%Scope{} = scope, company_id, authority) do
    overrides =
      scope
      |> overrides_query(company_id, authority)
      |> Repo.all()
      |> Enum.group_by(& &1.list)

    Map.new(lists(authority), fn list ->
      {list, apply_overrides(Map.get(overrides, list, []), shipped(authority, list))}
    end)
  end

  defp apply_overrides(overrides, codes) do
    Enum.reduce(overrides, codes, fn
      %CodeOverride{active: false, code: code}, codes ->
        Map.delete(codes, code)

      %CodeOverride{code: code, description: description}, codes ->
        Map.put(codes, code, description || Map.get(codes, code, code))
    end)
  end

  @doc """
  Sets the company's override of one code: `description` renames it (or
  names a code the shipped list lacks) and `active: false` retires it.
  """
  @spec put_override(Scope.t(), pos_integer(), String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, :unknown_list | Ecto.Changeset.t()}
  def put_override(%Scope{} = scope, company_id, authority, list, code, attributes) do
    cond do
      list not in lists(authority) ->
        {:error, :unknown_list}

      not (code =~ ~r/^[A-Za-z0-9.\-]{1,16}$/) ->
        {:error,
         %CodeOverride{}
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:code, "must be 1 to 16 letters, digits, dots, or dashes")}

      true ->
        upsert_override(scope, company_id, authority, list, code, attributes)
    end
  end

  defp upsert_override(scope, company_id, authority, list, code, attributes) do
    existing =
      scope
      |> overrides_query(company_id, authority)
      |> where([o], o.list == ^list and o.code == ^code)
      |> Repo.one()

    (existing ||
       %CodeOverride{
         tenant_id: Scope.tenant_id(scope),
         company_id: company_id,
         authority: authority,
         list: list,
         code: code
       })
    |> CodeOverride.changeset(attributes)
    |> Repo.insert_or_update()
    |> case do
      {:ok, override} ->
        {:ok, Map.take(override, [:list, :code, :description, :active])}

      error ->
        error
    end
  end

  defp overrides_query(scope, company_id, authority) do
    from(o in Tenancy.scope_query(CodeOverride, scope),
      where: o.company_id == ^company_id and o.authority == ^authority
    )
  end
end
