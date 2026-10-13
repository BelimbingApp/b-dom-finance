defmodule Bilimbi.Finance.Einvoice.SourceLink do
  @moduledoc false
  use Ecto.Schema

  # The source transaction a document is the tax document of: the module
  # that recognised it in the ledger, its record, and the entry that record
  # posted (see the source links migration).
  schema "finance_einvoice_source_links" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:document_id, :integer)
    field(:source_module, :string)
    field(:source_record, :string)
    field(:ledger_entry_id, :integer)
  end
end
