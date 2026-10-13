defmodule Bilimbi.Finance.Einvoice.Migrations.AddLedgerEntry do
  @moduledoc """
  The ledger entry a status event posted or reversed.

  Bilimbi-only. Validating a document posts a balanced entry through the
  ledger facade and cancelling it posts the reversal; each is recorded as a
  new status event (`posted`, `posting_reversed`) carrying the entry's ID,
  because a document row is never updated. A partial index finds, per
  company, the documents whose postings the reconciliation page compares.
  """

  use Ecto.Migration

  def up do
    alter table(:finance_einvoice_status_events) do
      add :ledger_entry_id, :bigint
    end

    create index(:finance_einvoice_status_events, [:company_id, :document_id, :event],
             where: "ledger_entry_id IS NOT NULL",
             name: :finance_einvoice_status_events_ledger_entry_index
           )

    create constraint(
             :finance_einvoice_status_events,
             :finance_einvoice_status_events_ledger_entry_id,
             check: "ledger_entry_id IS NULL OR ledger_entry_id > 0"
           )
  end

  def down do
    drop constraint(
           :finance_einvoice_status_events,
           :finance_einvoice_status_events_ledger_entry_id
         )

    drop index(:finance_einvoice_status_events, [:company_id, :document_id, :event],
           name: :finance_einvoice_status_events_ledger_entry_index
         )

    alter table(:finance_einvoice_status_events) do
      remove :ledger_entry_id
    end
  end
end
