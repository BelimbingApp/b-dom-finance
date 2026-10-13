defmodule Bilimbi.Finance.Reconciliation.StatementSource do
  @moduledoc """
  An imported bank statement as a record source documents support: the
  bank's own file, kept whole by `Bilimbi.Finance.Attachments` as the
  statement is imported, so the normalised lines can be checked against it
  for as long as the law asks. Read through
  `Bilimbi.Finance.Reconciliation.get_statement/3` with the caller's scope,
  so `finance.reconciliation.view` is also needed. A statement is immutable
  from its import, so it is always final: its file is never replaced or
  removed.
  """

  @behaviour Bilimbi.Finance.Attachments.Source

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Reconciliation

  @impl true
  def source_id, do: "finance/reconciliation/statement"

  @impl true
  def source_label, do: "Bank statement"

  @impl true
  def view_capability, do: Reconciliation.view_capability()

  @impl true
  def document(%Scope{} = scope, company_id, statement_id) do
    with {:ok, statement} <- Reconciliation.get_statement(scope, company_id, statement_id) do
      {:ok,
       %{
         label: "Statement #{statement.statement_number}",
         date: statement.end_date,
         final?: true
       }}
    end
  end
end
