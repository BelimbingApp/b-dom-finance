defmodule Bilimbi.Finance.Payroll.Mapping do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(component claim_category)
  @component_directions ~w(earning deduction employer)
  @claim_direction "claim"

  schema "finance_payroll_mappings" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    # `component`: a payroll pay item code with the direction its lines
    # carry; `claim_category`: a claim category code, direction `claim`.
    field(:kind, :string)
    field(:code, :string)
    field(:direction, :string)
    field(:expense_account_id, :integer)
    field(:liability_account_id, :integer)
    timestamps(type: :naive_datetime)
  end

  @doc "The mapping kinds: `component` and `claim_category`."
  def kinds, do: @kinds

  @doc "The directions a payroll component's lines carry."
  def component_directions, do: @component_directions

  @doc "The one direction a claim category mapping has."
  def claim_direction, do: @claim_direction

  @doc "The fields a mapping is keyed by."
  def key_fields, do: [:kind, :code, :direction]

  @doc "The account fields, as `put_mapping/3` takes and shows them."
  def account_fields, do: [:expense_account_id, :liability_account_id]

  @doc "Which account fields a direction needs: the expense side, the liability side, or both."
  def needed_accounts("earning"), do: [:expense_account_id]
  def needed_accounts("claim"), do: [:expense_account_id]
  def needed_accounts("deduction"), do: [:liability_account_id]
  def needed_accounts("employer"), do: [:expense_account_id, :liability_account_id]
  def needed_accounts(_other), do: []

  @doc "The changeset a new mapping is recorded with: its key and accounts."
  def changeset(mapping, attributes) do
    mapping
    |> cast(attributes, key_fields() ++ account_fields())
    |> update_change(:code, &String.trim/1)
    |> validate_required([:tenant_id, :company_id | key_fields()])
    |> validate_length(:code, min: 1, max: 60)
    |> validate_inclusion(:kind, @kinds)
    |> validate_direction()
    |> validate_accounts()
    |> unique_constraint(key_fields(), name: :finance_payroll_mappings_company_key_unique)
  end

  @doc "The changeset a mapping's accounts change with; its key is kept."
  def account_changeset(mapping, attributes) do
    mapping
    |> cast(attributes, account_fields())
    |> validate_accounts()
  end

  defp validate_direction(changeset) do
    case get_field(changeset, :kind) do
      "component" -> validate_inclusion(changeset, :direction, @component_directions)
      "claim_category" -> validate_inclusion(changeset, :direction, [@claim_direction])
      _other -> changeset
    end
  end

  # Each direction names exactly the accounts it posts to.
  defp validate_accounts(changeset) do
    direction = get_field(changeset, :direction)
    needed = needed_accounts(direction)

    Enum.reduce(account_fields(), changeset, fn field, changeset ->
      cond do
        field in needed and is_nil(get_field(changeset, field)) ->
          add_error(changeset, field, "is needed for a #{direction}")

        field not in needed and not is_nil(get_field(changeset, field)) and needed != [] ->
          add_error(changeset, field, "is not used by a #{direction}")

        true ->
          changeset
      end
    end)
  end
end
