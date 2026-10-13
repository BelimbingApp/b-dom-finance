defmodule Bilimbi.Finance.FixedAssets.Run do
  @moduledoc false
  use Ecto.Schema

  schema "finance_fixed_assets_runs" do
    field :tenant_id, :integer
    field :company_id, :integer
    field :period, :date
    field :entry_id, :integer
    field :entry_number, :integer
    field :total, :decimal
    field :recorded_by_user_id, :integer
    field :recorded_by_impersonator_id, :integer
    field :recorded_at, :utc_datetime_usec, read_after_writes: true
  end
end
