defmodule Bilimbi.Finance.FixedAssets.RunException do
  @moduledoc false
  use Ecto.Schema

  schema "finance_fixed_assets_run_exceptions" do
    field :tenant_id, :integer
    field :company_id, :integer
    field :run_id, :integer
    field :asset_id, :integer
    field :recorded_by_user_id, :integer
    field :recorded_by_impersonator_id, :integer
    field :recorded_at, :utc_datetime_usec, read_after_writes: true
  end
end
