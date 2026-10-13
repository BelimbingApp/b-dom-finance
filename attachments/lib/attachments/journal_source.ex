defmodule Bilimbi.Finance.Attachments.JournalSource do
  @moduledoc """
  A manual journal as a record source documents support: the voucher or
  working behind an adjustment. The ledger exposes no pages, so this source
  lives here; a journal's attachments are managed through
  `Bilimbi.Finance.Attachments` and read on the source documents page.

  The journal is read through `Bilimbi.Finance.Ledger.get_journal/3` with the
  caller's scope, so `finance.ledger.view` is also needed. A journal is
  final once decided (approved or rejected); while submitted its
  attachments can be replaced or removed.
  """

  @behaviour Bilimbi.Finance.Attachments.Source

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Ledger

  @impl true
  def source_id, do: "finance/ledger/journal"

  @impl true
  def source_label, do: "Manual journal"

  @impl true
  def document(%Scope{} = scope, company_id, journal_id) do
    with {:ok, journal} <- Ledger.get_journal(scope, company_id, journal_id) do
      {:ok,
       %{
         label: "Journal #{journal.journal_number}",
         date: journal.entry_date,
         final?: journal.status != "submitted"
       }}
    end
  end
end
