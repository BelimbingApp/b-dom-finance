defmodule Bilimbi.Finance.Reconciliation.Statement do
  @moduledoc false
  use Ecto.Schema

  alias Bilimbi.Finance.Reconciliation.StatementLine

  # The database numbers and stamps a statement (see the migration).
  schema "finance_reconciliation_statements" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:bank_account_id, :integer)
    field(:statement_number, :integer, read_after_writes: true)
    field(:file_name, :string)
    field(:file_sha256, :string)
    field(:line_count, :integer)
    field(:start_date, :date)
    field(:end_date, :date)
    field(:opening_balance, :decimal)
    field(:closing_balance, :decimal)
    field(:imported_by_user_id, :integer)
    field(:imported_by_impersonator_id, :integer)
    field(:imported_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:lines, StatementLine, foreign_key: :statement_id)
  end
end
