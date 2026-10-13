defmodule Bilimbi.Finance.FixedAssets.Event do
  @moduledoc false
  use Ecto.Schema

  schema "finance_fixed_assets_events" do
    field :tenant_id, :integer
    field :company_id, :integer
    field :event_number, :integer, read_after_writes: true
    field :asset_id, :integer
    field :run_id, :integer
    field :action, :string
    field :effective_date, :date
    field :entry_id, :integer
    field :entry_number, :integer
    field :reverses_event_id, :integer
    field :proceeds, :decimal
    field :accumulated, :decimal
    field :reason, :string
    field :recorded_by_user_id, :integer
    field :recorded_by_impersonator_id, :integer
    field :recorded_at, :utc_datetime_usec, read_after_writes: true
  end
end
