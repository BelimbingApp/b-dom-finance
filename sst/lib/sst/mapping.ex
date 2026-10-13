defmodule Bilimbi.Finance.Sst.Mapping do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Sst.Text

  @sources ~w(receivables payables)

  # The database numbers and stamps a mapping (see the migration).
  schema "finance_sst_mappings" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:mapping_number, :integer, read_after_writes: true)
    field(:source, :string)
    field(:tax_code_id, :integer)
    field(:tax_code, :string)
    field(:box, :string)
    field(:reason, :string)
    field(:recorded_by_user_id, :integer)
    field(:recorded_by_impersonator_id, :integer)
    field(:recorded_at, :utc_datetime_usec, read_after_writes: true)
  end

  def sources, do: @sources

  def changeset(mapping, attributes) do
    mapping
    |> cast(attributes, [:reason])
    |> update_change(:reason, &Text.blank_to_nil/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :source,
      :tax_code_id,
      :tax_code,
      :recorded_by_user_id
    ])
    |> validate_inclusion(:source, @sources)
    |> validate_length(:reason, max: 500)
  end
end
