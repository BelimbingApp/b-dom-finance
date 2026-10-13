defmodule Bilimbi.Finance.Ledger.LateRecordingsTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  @view "finance.ledger.view"
  @manage "finance.ledger.accounts.manage"
  @post "finance.ledger.entries.post"
  @periods "finance.ledger.periods.manage"
  @review "finance.ledger.late-recordings.review"

  # The database stamps each entry with today's date as its recording day, so
  # the days a listing shows are the days back from today to each entry date.
  # The fiscal years cover last year and the next two, around today.

  setup do
    context = TestFixtures.setup_ledger!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    poster =
      TestFixtures.sign_in!(context.first_scope, 73, 91, [
        @view,
        @manage,
        @post,
        @periods,
        @review
      ])

    reviewer = TestFixtures.sign_in!(context.first_scope, 73, 92, [@view, @review])
    reader = TestFixtures.sign_in!(context.first_scope, 73, 93, [@view])

    {:ok, _book} = Ledger.open_book(poster, 73, %{currency_code: "XTS", minor_units: 2})
    {:ok, _year} = Ledger.open_fiscal_year(poster, 73, %{start_date: first_year_start()})
    Enum.each(1..2, fn _ -> {:ok, _year} = Ledger.open_fiscal_year(poster, 73) end)

    {:ok, cash} =
      Ledger.create_account(poster, 73, %{code: "1000", name: "Cash", account_type: "asset"})

    {:ok, income} =
      Ledger.create_account(poster, 73, %{code: "4000", name: "Sales", account_type: "income"})

    entries =
      for {description, days_back} <- [
            {"Recent", 0},
            {"Days 44", 44},
            {"Days 45", 45},
            {"Days 50", 50},
            {"Days 60", 60},
            {"Days 61", 61},
            {"Days 100", 100}
          ],
          into: %{} do
        {:ok, entry} =
          Ledger.post_entry(poster, 73, %{
            entry_date: Date.add(Date.utc_today(), -days_back),
            description: description,
            lines: [%{account_id: cash.id, debit: "10"}, %{account_id: income.id, credit: "10"}]
          })

        {description, entry}
      end

    Map.merge(context, %{poster: poster, reviewer: reviewer, reader: reader, entries: entries})
  end

  test "the thresholds are 45 days to be listed and more than 60 to be late" do
    assert %{approaching_days: 45, late_days: 60} = Ledger.late_recording_thresholds()
  end

  test "lists the entries recorded 45 or more days after their dates, late past 60",
       %{reader: reader} do
    assert {:ok, listed} = Ledger.list_late_recordings(reader, 73)

    assert Enum.map(listed, &{&1.description, &1.days, &1.status, &1.review}) == [
             {"Days 45", 45, "approaching", nil},
             {"Days 50", 50, "approaching", nil},
             {"Days 60", 60, "approaching", nil},
             {"Days 61", 61, "late", nil},
             {"Days 100", 100, "late", nil}
           ]

    assert [%{entry_date: _, posted_at: %DateTime{}, posted_by_user_id: 91} | _] = listed
  end

  test "filters by status and by review", %{
    reader: reader,
    reviewer: reviewer,
    entries: entries
  } do
    assert {:ok, late} = Ledger.list_late_recordings(reader, 73, status: "late")
    assert Enum.map(late, & &1.description) == ["Days 61", "Days 100"]

    assert {:ok, approaching} = Ledger.list_late_recordings(reader, 73, status: "approaching")
    assert Enum.map(approaching, & &1.description) == ["Days 45", "Days 50", "Days 60"]

    assert {:ok, []} = Ledger.list_late_recordings(reader, 73, reviewed: true)

    {:ok, _review} =
      Ledger.record_late_recording_review(reviewer, 73, entries["Days 61"].id, %{
        reason: "Explained"
      })

    assert {:ok, [%{description: "Days 61"}]} =
             Ledger.list_late_recordings(reader, 73, reviewed: true)

    assert {:ok, [%{description: "Days 100"}]} =
             Ledger.list_late_recordings(reader, 73, reviewed: false, status: "late")
  end

  test "a reviewer records a reason once, and not the poster", %{
    reviewer: reviewer,
    poster: poster,
    entries: entries
  } do
    late = entries["Days 61"].id

    assert {:error, changeset} =
             Ledger.record_late_recording_review(reviewer, 73, late, %{reason: "  "})

    assert %{reason: ["can't be blank"]} = errors_on(changeset)

    assert {:error, :reviewer_not_independent} =
             Ledger.record_late_recording_review(poster, 73, late, %{reason: "Own entry"})

    assert {:error, :not_late_recorded} =
             Ledger.record_late_recording_review(reviewer, 73, entries["Recent"].id, %{
               reason: "Not late"
             })

    assert {:ok, review} =
             Ledger.record_late_recording_review(reviewer, 73, late, %{
               reason: "Bank feed delayed by the supplier"
             })

    assert %{reason: "Bank feed delayed by the supplier", reviewed_by_user_id: 92} = review

    assert {:error, :already_reviewed} =
             Ledger.record_late_recording_review(reviewer, 73, late, %{reason: "Again"})

    assert {:ok, [listed]} = Ledger.list_late_recordings(reviewer, 73, reviewed: true)
    assert listed.description == "Days 61"
    assert %{reason: "Bank feed delayed by the supplier", reviewed_by_user_id: 92} = listed.review
  end

  test "a review needs its capability, and an unknown entry is refused", %{
    reader: reader,
    reviewer: reviewer
  } do
    assert {:error, :unauthorized} =
             Ledger.record_late_recording_review(reader, 73, 1, %{reason: "Nope"})

    assert {:error, :entry_not_found} =
             Ledger.record_late_recording_review(reviewer, 73, -1, %{reason: "Nope"})
  end

  test "malformed options are refused", %{reader: reader} do
    assert {:error, :invalid_option} = Ledger.list_late_recordings(reader, 73, status: "overdue")
    assert {:error, :invalid_option} = Ledger.list_late_recordings(reader, 73, limit: 0)
    assert {:error, :invalid_option} = Ledger.list_late_recordings(reader, 73, reviewed: "yes")
  end

  defp first_year_start, do: Date.new!(Date.utc_today().year - 1, 1, 1)
end
