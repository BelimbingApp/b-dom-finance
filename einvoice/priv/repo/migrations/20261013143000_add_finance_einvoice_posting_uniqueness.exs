defmodule Bilimbi.Finance.Einvoice.Migrations.AddPostingUniqueness do
  @moduledoc """
  One ledger entry and one reversal per document.

  Bilimbi-only. A document's `posted` status event names the entry its
  validation posted, and its `posting_reversed` event the entry that
  reversed it. Partial unique indexes let the database refuse a second of
  either, so no race between two callers can leave a document with two
  entries or two reversals.
  """

  use Ecto.Migration

  def up do
    create unique_index(:finance_einvoice_status_events, [:document_id],
             where: "event = 'posted'",
             name: :finance_einvoice_status_events_posted_unique
           )

    create unique_index(:finance_einvoice_status_events, [:document_id],
             where: "event = 'posting_reversed'",
             name: :finance_einvoice_status_events_reversed_unique
           )
  end

  def down do
    drop index(:finance_einvoice_status_events, [:document_id],
           name: :finance_einvoice_status_events_reversed_unique
         )

    drop index(:finance_einvoice_status_events, [:document_id],
           name: :finance_einvoice_status_events_posted_unique
         )
  end
end
