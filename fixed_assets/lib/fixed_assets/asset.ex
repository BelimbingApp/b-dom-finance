defmodule Bilimbi.Finance.FixedAssets.Asset do
  @moduledoc false
  use Ecto.Schema

  schema "finance_fixed_assets_assets" do
    field :tenant_id, :integer
    field :company_id, :integer
    field :asset_number, :integer, read_after_writes: true
    field :category_revision_id, :integer
    field :description, :string
    field :acquisition_date, :date
    field :in_service_date, :date
    field :cost, :decimal
    field :residual_value, :decimal
    field :method, :string
    field :life_months, :integer
    field :annual_rate, :decimal
    field :entry_id, :integer
    field :entry_number, :integer
    field :entry_line_number, :integer
    field :bill_id, :integer
    field :bill_line_number, :integer
    field :recorded_by_user_id, :integer
    field :recorded_by_impersonator_id, :integer
    field :recorded_at, :utc_datetime_usec, read_after_writes: true
  end
end
