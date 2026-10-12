defmodule Bilimbi.Finance.Einvoice.CodeListsTest do
  # The contribution registry snapshot is process-global.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.{CodeLists, TestFixtures}

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  setup do
    context = TestFixtures.setup_einvoice!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, TestFixtures.capabilities())
    Map.put(context, :operator, operator)
  end

  test "every shipped list is available whole", %{operator: op} do
    assert CodeLists.lists("myinvois") ==
             ~w(classification country currency document_type industry payment_means state tax_type unit)

    counts =
      for list <- CodeLists.lists("myinvois"), into: %{} do
        {:ok, codes} = Einvoice.list_codes(op, 73, list)
        {list, map_size(codes)}
      end

    assert counts == %{
             "classification" => 45,
             "country" => 253,
             "currency" => 180,
             "document_type" => 8,
             "industry" => 1174,
             "payment_means" => 8,
             "state" => 17,
             "tax_type" => 7,
             "unit" => 2162
           }

    assert {:ok, %{"E" => "Tax exemption (where applicable)"} = tax_types} =
             Einvoice.list_codes(op, 73, "tax_type")

    assert map_size(tax_types) == 7
  end

  test "a company renames, retires, and adds codes for itself only", %{
    first_scope: scope,
    operator: op
  } do
    assert {:ok, _} = Einvoice.override_code(op, 73, "tax_type", "06", %{description: "No tax"})
    assert {:ok, _} = Einvoice.override_code(op, 73, "payment_means", "01", %{active: false})

    assert {:ok, _} =
             Einvoice.override_code(op, 73, "classification", "046", %{description: "New code"})

    assert {:ok, %{"06" => "No tax"}} = Einvoice.list_codes(op, 73, "tax_type")
    assert {:ok, payment} = Einvoice.list_codes(op, 73, "payment_means")
    refute Map.has_key?(payment, "01")
    assert {:ok, %{"046" => "New code"}} = Einvoice.list_codes(op, 73, "classification")

    sibling = TestFixtures.sign_in!(scope, 74, 92, TestFixtures.capabilities())
    assert {:ok, %{"06" => "Not Applicable"}} = Einvoice.list_codes(sibling, 74, "tax_type")

    # A retired code is refused when issuing.
    :ok = TestFixtures.put_supplier_profile!(scope, 73)

    assert {:error, changeset} =
             Einvoice.issue_document(
               op,
               73,
               TestFixtures.invoice_attributes(%{payment_means_code: "01"})
             )

    assert %{payment_means_code: ["is not a known code"]} = errors_on(changeset)
  end

  test "refuses an unknown list or malformed code, and needs the settings capability",
       %{first_scope: scope, operator: op} do
    assert {:error, :unknown_list} = Einvoice.override_code(op, 73, "colours", "01", %{})
    assert {:error, :unknown_list} = Einvoice.list_codes(op, 73, "colours")
    assert {:error, %Ecto.Changeset{}} = Einvoice.override_code(op, 73, "unit", "a b", %{})

    viewer = TestFixtures.sign_in!(scope, 73, 93, ["finance.einvoice.view"])

    assert {:error, :unauthorized} =
             Einvoice.override_code(viewer, 73, "tax_type", "06", %{description: "x"})
  end
end
