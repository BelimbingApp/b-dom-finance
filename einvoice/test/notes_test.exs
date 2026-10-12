defmodule Bilimbi.Finance.Einvoice.NotesTest do
  # The contribution registry snapshot is process-global.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.{MyInvois, TestFixtures}

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  setup do
    context = TestFixtures.setup_einvoice!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, TestFixtures.capabilities())
    :ok = TestFixtures.put_supplier_profile!(context.first_scope, 73)
    {:ok, original} = Einvoice.issue_document(operator, 73, TestFixtures.invoice_attributes())
    Map.merge(context, %{operator: operator, original: original})
  end

  defp note(type, original_id, overrides \\ %{}) do
    TestFixtures.invoice_attributes(
      Map.merge(
        %{document_type: type, code_number: "NOTE-#{type}", original_document_id: original_id},
        overrides
      )
    )
  end

  test "a note references a validated original by code number and UUID", %{
    operator: op,
    original: original
  } do
    :ok = TestFixtures.validate!(op, 73, original.id)

    for type <- ["02", "03", "04"] do
      assert {:ok, note} = Einvoice.issue_document(op, 73, note(type, original.id))
      assert note.original_document_id == original.id
      assert note.details["original_code_number"] == "JSON-INV12345"
      assert note.details["original_document_uuid"] == "F9D425P6DS7D8IU"

      assert {:ok, %{bytes: bytes}} =
               MyInvois.payload(
                 note,
                 %{version: "1.0", signing_key: nil},
                 ~U[2026-10-02 00:00:00Z]
               )

      assert bytes =~
               ~s("BillingReference":[{"InvoiceDocumentReference":[{"ID":[{"_":"JSON-INV12345"}],"UUID":[{"_":"F9D425P6DS7D8IU"}]}]}])

      assert bytes =~ ~s("InvoiceTypeCode":[{"_":"#{type}","listVersionID":"1.0"}])
    end
  end

  test "a note needs an original the authority validated, and an invoice takes none", %{
    operator: op,
    original: original
  } do
    assert {:error, changeset} = Einvoice.issue_document(op, 73, note("02", nil))
    assert %{original_document_id: ["is required for a note"]} = errors_on(changeset)

    assert {:error, changeset} = Einvoice.issue_document(op, 73, note("02", original.id + 100))
    assert %{original_document_id: ["is not a document of this company"]} = errors_on(changeset)

    assert {:error, changeset} = Einvoice.issue_document(op, 73, note("02", original.id))
    assert %{original_document_id: ["is not a validated document"]} = errors_on(changeset)

    assert {:error, changeset} =
             Einvoice.issue_document(
               op,
               73,
               TestFixtures.invoice_attributes(%{
                 code_number: "INV-9",
                 original_document_id: original.id
               })
             )

    assert %{original_document_id: ["is only given for a note"]} = errors_on(changeset)
  end

  test "a note cannot reference another note or a document of a sibling company",
       %{operator: op, original: original} = context do
    :ok = TestFixtures.validate!(op, 73, original.id)
    {:ok, credit} = Einvoice.issue_document(op, 73, note("02", original.id))
    :ok = TestFixtures.validate!(op, 73, credit.id, uuid: "NOTE000000000001")

    assert {:error, changeset} = Einvoice.issue_document(op, 73, note("03", credit.id))

    assert %{original_document_id: ["is itself a note; reference the invoice"]} =
             errors_on(changeset)

    sibling = TestFixtures.sign_in!(context.first_scope, 74, 93, TestFixtures.capabilities())
    :ok = TestFixtures.put_supplier_profile!(context.first_scope, 74)
    assert {:error, changeset} = Einvoice.issue_document(sibling, 74, note("02", original.id))
    assert %{original_document_id: ["is not a document of this company"]} = errors_on(changeset)
  end
end
