defmodule Bilimbi.Finance.Reports.Issued do
  @moduledoc false
  use Ecto.Schema

  schema "finance_reports_issued" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:kind, :string)
    field(:implementation_version, :string)
    field(:through_entry_number, :integer)
    field(:content, :map)
    field(:chart, {:array, :map})
    field(:layout, :map)
    field(:membership, :map)
    field(:issued_by_user_id, :integer)
    field(:issued_by_impersonator_id, :integer)
    field(:issued_at, :utc_datetime_usec, read_after_writes: true)
  end
end
