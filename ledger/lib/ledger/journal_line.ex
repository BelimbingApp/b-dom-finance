defmodule Bilimbi.Finance.Ledger.JournalLine do
  @moduledoc false
  use Ecto.Schema

  # One line of a submitted journal, cast by `Bilimbi.Finance.Ledger.Line`'s
  # changeset, so it obeys the rules the entry it becomes will.
  schema "finance_ledger_journal_lines" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:journal_id, :integer)
    field(:line_number, :integer)
    field(:account_id, :integer)
    field(:debit, :decimal)
    field(:credit, :decimal)
    field(:description, :string)
  end
end
