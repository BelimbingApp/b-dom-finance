defmodule Bilimbi.Finance.Payroll.EvidenceTest do
  use Bilimbi.Finance.Payroll.PayrollCase

  test "an evidence page returns the company's change history, paged in ID order", context do
    context = configure!(context)
    %{operator: operator, accounts: accounts} = context

    {:ok, _} =
      Payroll.put_mapping(operator, 73, %{
        kind: "component",
        code: "basic",
        direction: "earning",
        expense_account_id: accounts.old_expense.id,
        reason: "Moved"
      })

    assert "mapping_change" in Payroll.evidence_datasets()
    assert {:ok, %{rows: [first], next: cursor}} =
             Payroll.evidence_page(operator, 73, "mapping_change", limit: 1)

    assert cursor == first.id
    assert first.company_id == 73

    assert {:ok, %{rows: rest}} =
             Payroll.evidence_page(operator, 73, "mapping_change", after: cursor)

    assert Enum.all?(rest, &(&1.id > cursor))

    assert {:ok, %{rows: [_ | _]}} = Payroll.evidence_page(operator, 73, "settings")
    assert {:error, :invalid_option} = Payroll.evidence_page(operator, 73, "nope")
    assert {:error, :invalid_option} = Payroll.evidence_page(operator, 73, "settings", limit: 501)
  end

  test "an evidence page needs the view grant and a company the scope can reach", context do
    context = configure!(context)
    stranger = TestFixtures.sign_in!(context.first_scope, 73, 97, [])

    assert {:error, :unauthorized} = Payroll.evidence_page(stranger, 73, "settings")
    assert {:error, _} = Payroll.evidence_page(context.operator, 999, "settings")
  end
end
