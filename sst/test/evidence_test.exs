defmodule Bilimbi.Finance.Sst.EvidenceTest do
  use Bilimbi.Finance.Sst.SstCase

  test "an evidence page returns every registration version, paged in ID order", context do
    %{operator: operator} = context

    {:ok, _} = Sst.register(operator, 73, %{service_tax_number: "X00-2601-00000009", reason: "Fix"})

    assert "registration" in Sst.evidence_datasets()

    assert {:ok, %{rows: [first], next: cursor}} =
             Sst.evidence_page(operator, 73, "registration", limit: 1)

    assert cursor == first.id
    assert first.company_id == 73

    assert {:ok, %{rows: [second], next: nil}} =
             Sst.evidence_page(operator, 73, "registration", after: cursor)

    assert second.id > first.id
    assert {:error, :invalid_option} = Sst.evidence_page(operator, 73, "nope")
  end

  test "an evidence page needs the view grant and a company the scope can reach", context do
    stranger = TestFixtures.sign_in!(context.first_scope, 73, 97, [])

    assert {:error, :unauthorized} = Sst.evidence_page(stranger, 73, "registration")
    assert {:error, _} = Sst.evidence_page(context.operator, 999, "registration")
  end
end
