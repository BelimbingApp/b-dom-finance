defmodule Bilimbi.Finance.Attachments.RetentionTest do
  use Bilimbi.Finance.Attachments.AttachmentsCase

  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Attachments.Retention
  alias Ecto.Adapters.SQL

  test "the default is seven years, in the code and the migration" do
    assert Retention.default_years() == 7
    assert Attachments.default_retention_years() == 7
    assert TestFixtures.migration().default_years() == 7
  end

  test "the end of the day years on, clamped to a real date" do
    assert Retention.until(~D[2024-02-29], 7) == ~U[2031-02-28 23:59:59.999999Z]
    assert Retention.until(~D[2026-12-31], 1) == ~U[2027-12-31 23:59:59.999999Z]
    assert Retention.end_of_day(~D[2026-01-01]) == ~U[2026-01-01 23:59:59.999999Z]
  end

  test "a company keeps the default until it lengthens it, with a reason, and never shortens it",
       %{operator: operator, viewer: viewer} do
    assert {:ok, %{years: 7, change: nil}} = Attachments.get_retention(operator, 73)
    assert {:ok, []} = Attachments.list_retention_changes(operator, 73)

    assert {:error, :retention_not_lengthened} =
             Attachments.set_retention(operator, 73, %{years: 7, reason: "same"})

    assert {:error, :retention_not_lengthened} =
             Attachments.set_retention(operator, 73, %{years: 5, reason: "shorter"})

    assert {:error, %Ecto.Changeset{} = changeset} =
             Attachments.set_retention(operator, 73, %{years: 9, reason: " "})

    assert %{reason: [_blank]} = errors_on(changeset)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Attachments.set_retention(operator, 73, %{years: "nine", reason: "x"})

    assert %{years: [_invalid]} = errors_on(changeset)

    assert {:ok, %{years: 9, change: change}} =
             Attachments.set_retention(operator, 73, %{years: "9", reason: "group policy"})

    assert change.change_number == 1
    assert change.changed_by_user_id == 91
    assert %DateTime{} = change.changed_at

    assert {:error, :retention_not_lengthened} =
             Attachments.set_retention(operator, 73, %{years: 8, reason: "back"})

    assert {:ok, %{years: 12}} =
             Attachments.set_retention(operator, 73, %{years: 12, reason: "longer"})

    assert {:ok, [%{years: 9}, %{years: 12}]} = Attachments.list_retention_changes(operator, 73)
    assert {:error, :unauthorized} = Attachments.get_retention(operator, 74)

    assert {:error, :unauthorized} =
             Attachments.set_retention(viewer, 73, %{years: 20, reason: "no"})

    assert {:ok, %{years: 12}} = Attachments.get_retention(viewer, 73)
  end

  test "the database refuses a shorter setting and a change to a recorded one" do
    insert = fn years ->
      SQL.query!(
        Repo,
        "INSERT INTO finance_attachments_retention_changes (tenant_id, company_id, years, reason, changed_by_user_id, changed_at) VALUES (41, 73, $1, 'why', 91, '2000-01-01') RETURNING change_number, changed_at",
        [years]
      )
    end

    assert_raise Postgrex.Error, ~r/7 years and is only ever lengthened/, fn -> insert.(7) end
    %{rows: [[1, changed_at]]} = insert.(8)
    assert changed_at.year > 2000
    assert_raise Postgrex.Error, ~r/8 years and is only ever lengthened/, fn -> insert.(8) end

    assert_raise Postgrex.Error, ~r/UPDATE is refused/, fn ->
      SQL.query!(Repo, "UPDATE finance_attachments_retention_changes SET years = 20", [])
    end

    assert_raise Postgrex.Error, ~r/DELETE is refused/, fn ->
      SQL.query!(Repo, "DELETE FROM finance_attachments_retention_changes", [])
    end
  end
end
