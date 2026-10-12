defmodule Bilimbi.Finance.Einvoice.CodeLists do
  @moduledoc """
  The authority's code lists as reference data, with each company's
  overrides.

  An authority publishes its lists (document types, tax types, item
  classifications, states, countries, currencies, units, industry codes,
  payment means). The module ships them in `priv/code_lists/<authority>.json`
  with the date they were read, and a production seed loads them into
  `finance_einvoice_code_entries`; a later file with new or renamed codes is
  loaded by a new seed. A company's override renames a code, retires it, or
  adds one the shipped file does not have yet, for that company only, so a
  list change the authority announces need not wait for a release.
  """

  import Ecto.Query

  alias Bilimbi.Base.Database.WriteCapture
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Einvoice.{CodeEntry, CodeOverride}

  @type codes :: %{String.t() => String.t()}

  @shipped_files Path.wildcard(Path.expand("../../priv/code_lists/*.json", __DIR__))
  for path <- @shipped_files, do: @external_resource(path)

  @shipped_lists Map.new(@shipped_files, fn path ->
                   lists = path |> File.read!() |> Jason.decode!() |> Map.fetch!("lists")
                   {Path.basename(path, ".json"), lists |> Map.keys() |> Enum.sort()}
                 end)

  @doc "The lists in an authority's shipped file."
  @spec lists(String.t()) :: [String.t()]
  def lists(authority), do: Map.get(@shipped_lists, authority, [])

  @doc """
  Loads an authority's shipped lists, adding new codes and replacing changed
  descriptions. A code the file no longer has stays: documents issued with it
  still name it. Idempotent.
  """
  @spec seed!(String.t(), module()) :: :ok
  def seed!(authority, repo \\ Repo) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for {list, %{"codes" => codes}} <- shipped!(authority)["lists"],
          [code, description] <- codes do
        %{
          authority: authority,
          list: list,
          code: code,
          description: description,
          inserted_at: now,
          updated_at: now
        }
      end

    # Shipped reference data reconciled by a production seed, not an actor's
    # decision; every company's own change is an override, which is audited.
    WriteCapture.without_capture(fn ->
      rows
      |> Enum.chunk_every(1_000)
      |> Enum.each(fn chunk ->
        repo.insert_all(CodeEntry, chunk,
          conflict_target: [:authority, :list, :code],
          on_conflict: {:replace, [:description, :updated_at]}
        )
      end)
    end)

    :ok
  end

  @doc """
  The company's active codes in one list, code to description: the seeded
  entries with the company's overrides applied.
  """
  @spec codes(Scope.t(), pos_integer(), String.t(), String.t()) :: codes()
  def codes(%Scope{} = scope, company_id, authority, list) do
    entries =
      from(e in CodeEntry,
        where: e.authority == ^authority and e.list == ^list,
        select: {e.code, e.description}
      )
      |> Repo.all()
      |> Map.new()

    scope
    |> overrides_query(company_id, authority)
    |> where([o], o.list == ^list)
    |> Repo.all()
    |> Enum.reduce(entries, fn
      %CodeOverride{active: false, code: code}, codes ->
        Map.delete(codes, code)

      %CodeOverride{code: code, description: description}, codes ->
        Map.put(codes, code, description || Map.get(codes, code, code))
    end)
  end

  @doc "Every list's active codes for the company, by list name."
  @spec all_codes(Scope.t(), pos_integer(), String.t()) :: %{String.t() => codes()}
  def all_codes(%Scope{} = scope, company_id, authority) do
    Map.new(lists(authority), &{&1, codes(scope, company_id, authority, &1)})
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

  defp shipped!(authority) do
    if Map.has_key?(@shipped_lists, authority) do
      :bilimbi_finance_einvoice
      |> :code.priv_dir()
      |> Path.join("code_lists/#{authority}.json")
      |> File.read!()
      |> Jason.decode!()
    else
      raise ArgumentError, "unknown authority #{inspect(authority)}"
    end
  end
end
