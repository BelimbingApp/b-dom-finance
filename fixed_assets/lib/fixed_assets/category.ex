defmodule Bilimbi.Finance.FixedAssets.Category do
  @moduledoc false
  use Ecto.Schema

  schema "finance_fixed_assets_categories" do
    field :tenant_id, :integer
    field :company_id, :integer
    field :name, :string
    field :recorded_by_user_id, :integer
    field :recorded_by_impersonator_id, :integer
    field :recorded_at, :utc_datetime_usec, read_after_writes: true
  end
end
