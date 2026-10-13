defmodule Bilimbi.Finance.Reconciliation.AttachmentsTest do
  use Bilimbi.Finance.Reconciliation.ReconciliationCase

  alias Bilimbi.Finance.Attachments
  alias Bilimbi.Finance.Reconciliation.StatementSource

  @rows [
    ["2026-10-01", "Deposit", "DEP-1", "1000.00", "1000.00"],
    ["2026-10-20", "Monthly fee", "", "-5.00", "995.00"]
  ]

  test "an import keeps the bank's file as the statement's source document, and the mapping it read it through",
       context do
    content = TestFixtures.csv(@rows)

    {:ok, statement} =
      Reconciliation.import_statement(context.operator, 73, context.bank_account.id, %{
        file_name: "october.csv",
        content: content
      })

    assert statement.import_mapping == context.bank_account.import_mapping

    assert {:ok, %{import_mapping: mapping}} =
             Reconciliation.get_statement(context.operator, 73, statement.id)

    assert mapping == context.bank_account.import_mapping

    assert {:ok, [attachment]} =
             Attachments.list_attachments(context.operator, 73, StatementSource, statement.id)

    assert attachment.file_name == "october.csv"
    assert attachment.content_type == "text/csv"
    assert attachment.sha256 == statement.file_sha256
    assert attachment.document_label == "Statement #{statement.statement_number}"
    assert attachment.document_date == ~D[2026-10-20]
    assert attachment.retain_until == ~U[2033-12-31 23:59:59.999999Z]
    assert attachment.captured_by_user_id == 91

    assert {:ok, %{bytes: ^content}} =
             Attachments.read_attachment(context.operator, 73, attachment.id)

    # A statement is immutable, so its file is kept as it is.
    assert {:error, :document_final} =
             Attachments.replace(context.operator, 73, attachment.id, %{
               file_name: "x.csv",
               content: "x"
             })
  end

  test "a refused import stores no file", context do
    content = TestFixtures.csv(@rows)
    _statement = import!(context, @rows, "october.csv")

    assert {:error, {:duplicate_file, _number}} =
             Reconciliation.import_statement(context.operator, 73, context.bank_account.id, %{
               file_name: "october-again.csv",
               content: content
             })

    assert {:error, {:duplicate_lines, _lines}} =
             Reconciliation.import_statement(context.operator, 73, context.bank_account.id, %{
               file_name: "overlap.csv",
               content: TestFixtures.csv(@rows ++ [["2026-10-21", "More", "", "1.00", "996.00"]])
             })

    assert {:ok, [_october]} = Attachments.list_company_attachments(context.operator, 73)
  end

  test "an import needs the attachments create capability and Base Artifacts storage", context do
    importer =
      TestFixtures.sign_in!(
        context.first_scope,
        73,
        97,
        ~w(finance.ledger.view finance.reconciliation.view finance.reconciliation.statements.import)
      )

    assert {:error, :unauthorized} =
             Reconciliation.import_statement(importer, 73, context.bank_account.id, %{
               file_name: "october.csv",
               content: TestFixtures.csv(@rows)
             })

    :ok = Bilimbi.Base.Settings.delete("artifacts.storage_root")

    assert {:error, _storage} =
             Reconciliation.import_statement(context.operator, 73, context.bank_account.id, %{
               file_name: "october.csv",
               content: TestFixtures.csv(@rows)
             })

    assert {:ok, []} =
             Reconciliation.list_statements(context.operator, 73, context.bank_account.id)
  end
end
