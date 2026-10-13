defmodule Bilimbi.Finance.FixedAssets.CategoryRevision do
  @moduledoc false
  use Ecto.Schema

  schema "finance_fixed_assets_category_revisions" do
    field :tenant_id, :integer
    field :company_id, :integer
    field :category_id, :integer
    field :cost_account_id, :integer
    field :accumulated_account_id, :integer
    field :expense_account_id, :integer
    field :gain_account_id, :integer
    field :loss_account_id, :integer
    field :method, :string
    field :life_months, :integer
    field :annual_rate, :decimal
    field :reason, :string
    field :recorded_by_user_id, :integer
    field :recorded_by_impersonator_id, :integer
    field :recorded_at, :utc_datetime_usec, read_after_writes: true
  end
end
