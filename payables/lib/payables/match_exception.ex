defmodule Bilimbi.Finance.Payables.MatchException do
  @moduledoc false
  use Ecto.Schema

  schema "finance_payables_match_exceptions" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:match_line_id, :integer)
    field(:code, :string)
    field(:detail, :string)
  end
end
