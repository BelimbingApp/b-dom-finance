defmodule Bilimbi.Finance.Reconciliation.MatchLine do
  @moduledoc false
  use Ecto.Schema

  schema "finance_reconciliation_match_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:match_id, :integer)
    field(:statement_line_id, :integer)
  end
end
