defmodule Bilimbi.Finance.Reconciliation.Migrations.AddImportMapping do
  @moduledoc """
  The import mapping a statement was read through.

  Bilimbi-only. A bank account's mapping changes in place as the bank's
  export changes, and a statement's lines are what the mapping of its day
  made of the file; the statement keeps that mapping as it was, so the
  lines reproduce from the file the attachments module keeps. A statement
  imported before this column is null here.

  The migration is self-contained: a database that ran the earlier one
  loads only this file. `statements/1` is its one source; with
  `temporary: true` it alters the module tests' temporary copy.
  """

  use Ecto.Migration

  def up, do: Enum.each(statements(), &execute/1)

  def down do
    execute("ALTER TABLE finance_reconciliation_statements DROP COLUMN import_mapping")
  end

  @doc "The schema change's SQL in order; the same over a temporary copy."
  def statements(_options \\ []) do
    ["ALTER TABLE finance_reconciliation_statements ADD COLUMN import_mapping jsonb"]
  end
end
