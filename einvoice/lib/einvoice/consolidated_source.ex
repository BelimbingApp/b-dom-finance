defmodule Bilimbi.Finance.Einvoice.ConsolidatedSource do
  @moduledoc false
  use Ecto.Schema

  # One document a consolidated document covers, and the consolidated
  # document's line that carries it (see the consolidation migration).
  schema "finance_einvoice_consolidated_sources" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:document_id, :integer)
    field(:source_document_id, :integer)
    field(:line_number, :integer)
  end
end
