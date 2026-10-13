defmodule Bilimbi.Finance.Ledger.DutySeparationTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures
  alias Ecto.Adapters.SQL

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  @view "finance.ledger.view"
  @manage "finance.ledger.accounts.manage"
  @post "finance.ledger.entries.post"
  @periods "finance.ledger.periods.manage"
  @reopen "finance.ledger.periods.reopen"
  @separation "finance.ledger.duty-separation.manage"
  @submit "finance.ledger.journals.submit"
  @approve "finance.ledger.journals.approve"
  @review "finance.ledger.approval-exceptions.review"

  @all [@view, @manage, @post, @periods, @reopen, @separation, @submit, @approve, @review]

  setup do
    context = TestFixtures.setup_ledger!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    clerk = TestFixtures.sign_in!(context.first_scope, 73, 91, @all)
    approver = TestFixtures.sign_in!(context.first_scope, 73, 92, @all)
    reviewer = TestFixtures.sign_in!(context.first_scope, 73, 93, @all)

    {:ok, _book} = Ledger.open_book(clerk, 73, %{currency_code: "XTS", minor_units: 2})

    {:ok, cash} =
      Ledger.create_account(clerk, 73, %{code: "1000", name: "Cash", account_type: "asset"})

    {:ok, income} =
      Ledger.create_account(clerk, 73, %{code: "4000", name: "Sales", account_type: "income"})

    Map.merge(context, %{
      clerk: clerk,
      approver: approver,
      reviewer: reviewer,
      cash: cash,
      income: income
    })
  end

  defp journal(context, extra \\ %{}) do
    Map.merge(
      %{
        entry_date: ~D[2026-10-05],
        description: "Accrual",
        reference: "J-1",
        lines: [
          %{account_id: context.cash.id, debit: "10.00"},
          %{account_id: context.income.id, credit: "10.00"}
        ]
      },
      extra
    )
  end

  defp turn_off!(scope, reason \\ "One finance person") do
    {:ok, %{required: false}} =
      Ledger.set_duty_separation(scope, 73, %{required: false, reason: reason})
  end

  defp approval(prepared_by, extra \\ %{}) do
    Map.merge(
      %{
        source: "finance/payables",
        action: "document_approval",
        subject_type: "bill",
        subject_id: 7,
        subject: "Bill 7",
        prepared_by: prepared_by
      },
      extra
    )
  end

  describe "the setting" do
    test "requires separation until a company turns it off with a reason", context do
      %{clerk: clerk, approver: approver} = context

      assert {:ok, %{required: true, change: nil}} = Ledger.get_duty_separation(clerk, 73)

      assert {:error, changeset} =
               Ledger.set_duty_separation(clerk, 73, %{required: false, reason: " "})

      assert %{reason: ["is required to turn separation off"]} = errors_on(changeset)

      assert {:ok, %{required: false, change: change}} =
               Ledger.set_duty_separation(clerk, 73, %{required: false, reason: "Sole bookkeeper"})

      assert %{
               change_number: 1,
               required: false,
               reason: "Sole bookkeeper",
               changed_by_user_id: 91,
               changed_by_impersonator_id: nil,
               changed_at: %DateTime{}
             } = change

      # A call that changes nothing records nothing.
      assert {:ok, %{required: false, change: ^change}} =
               Ledger.set_duty_separation(approver, 73, %{required: false, reason: "Again"})

      assert {:ok, %{required: true, change: %{change_number: 2, changed_by_user_id: 92}}} =
               Ledger.set_duty_separation(approver, 73, %{required: true})

      assert {:ok, [%{change_number: 1}, %{change_number: 2, reason: nil}]} =
               Ledger.list_duty_separation_changes(clerk, 73)
    end

    test "needs its own capability", context do
      %{first_scope: system} = context
      viewer = TestFixtures.sign_in!(system, 73, 96, [@view])

      assert {:error, :unauthorized} =
               Ledger.set_duty_separation(viewer, 73, %{required: false, reason: "x"})

      assert {:error, :unauthorized} = Ledger.set_duty_separation(system, 73, %{required: false})
      assert {:ok, %{required: true}} = Ledger.get_duty_separation(viewer, 73)
    end

    test "the database refuses a change that changes nothing and any edit", context do
      %{clerk: clerk} = context
      turn_off!(clerk)

      assert_raise Postgrex.Error, ~r/already not required/, fn ->
        Repo.transaction(fn ->
          SQL.query!(
            Repo,
            "INSERT INTO finance_ledger_duty_separation_changes " <>
              "(tenant_id, company_id, change_number, required, reason, changed_by_user_id, changed_at) " <>
              "VALUES (41, 73, 9, false, 'x', 91, now())",
            []
          )
        end)
      end

      assert_raise Postgrex.Error, ~r/keeps finance_ledger_duty_separation_changes rows/, fn ->
        SQL.query!(Repo, "UPDATE finance_ledger_duty_separation_changes SET reason = 'y'", [])
      end
    end
  end

  describe "check_approval/3" do
    test "refuses the preparer while separation is required, and records nothing", context do
      %{clerk: clerk, approver: approver} = context
      preparer = [%{user_id: 91, impersonator_id: nil}]

      assert {:error, :same_person} = Ledger.check_approval(clerk, 73, approval(preparer))
      assert :ok = Ledger.check_approval(approver, 73, approval(preparer))
      assert {:ok, []} = Ledger.list_approval_exceptions(clerk, 73)
    end

    test "counts impersonation either way as the same person", context do
      %{first_scope: system} = context
      TestFixtures.sign_in!(system, 73, 95, @all)

      # The approver is impersonated by the preparer.
      impersonated =
        Authentication.sign_in(system, 95, 73,
          impersonator_id: 91,
          impersonation_session_id: "borrowed-session"
        )

      assert {:error, :same_person} =
               Ledger.check_approval(impersonated, 73, approval([%{user_id: 91}]))

      # The preparer was impersonated by the approver.
      assert {:error, :same_person} =
               Ledger.check_approval(
                 context.approver,
                 73,
                 approval([%{user_id: 94, impersonator_id: 92}])
               )

      # One operator impersonated both.
      assert {:error, :same_person} =
               Ledger.check_approval(
                 impersonated,
                 73,
                 approval([%{user_id: 94, impersonator_id: 91}])
               )

      assert :ok =
               Ledger.check_approval(
                 impersonated,
                 73,
                 approval([%{user_id: 94, impersonator_id: 98}])
               )
    end

    test "allows the preparer while separation is off and records the exception", context do
      %{clerk: clerk} = context
      turn_off!(clerk, "Sole bookkeeper")
      {:ok, %{change: change}} = Ledger.get_duty_separation(clerk, 73)

      assert :ok = Ledger.check_approval(clerk, 73, approval([%{user_id: 91}]))

      assert {:ok, [exception]} = Ledger.list_approval_exceptions(clerk, 73)

      assert %{
               exception_number: 1,
               source: "finance/payables",
               action: "document_approval",
               subject_type: "bill",
               subject_id: 7,
               subject: "Bill 7",
               same_person: true,
               override: false,
               prepared_by_user_id: 91,
               approved_by_user_id: 91,
               reason: "Sole bookkeeper",
               review: nil,
               recorded_at: %DateTime{}
             } = exception

      assert exception.separation_change_id == change.id
    end

    test "always records an override, with the approver's reason", context do
      %{clerk: clerk, approver: approver} = context

      assert {:error, changeset} =
               Ledger.check_approval(approver, 73, approval([%{user_id: 91}], %{override: true}))

      assert %{reason: ["can't be blank"]} = errors_on(changeset)

      assert :ok =
               Ledger.check_approval(
                 approver,
                 73,
                 approval([%{user_id: 91}], %{override: true, reason: "Price agreed by phone"})
               )

      assert {:ok, [%{same_person: false, override: true, reason: "Price agreed by phone"}]} =
               Ledger.list_approval_exceptions(clerk, 73)

      # An override by the preparer is still refused while separation is on.
      assert {:error, :same_person} =
               Ledger.check_approval(
                 clerk,
                 73,
                 approval([%{user_id: 91}], %{override: true, reason: "Mine"})
               )
    end

    test "needs the ledger's view capability", context do
      %{first_scope: system} = context
      outsider = TestFixtures.sign_in!(system, 73, 96, [@post])

      assert {:error, :unauthorized} =
               Ledger.check_approval(outsider, 73, approval([%{user_id: 91}]))
    end

    test "the database refuses a same-person exception while separation is required",
         context do
      %{clerk: clerk} = context
      turn_off!(clerk)
      {:ok, %{change: off}} = Ledger.get_duty_separation(clerk, 73)
      {:ok, _on} = Ledger.set_duty_separation(clerk, 73, %{required: true})

      assert_raise Postgrex.Error, ~r/requires separation of duties/, fn ->
        Repo.transaction(fn ->
          SQL.query!(
            Repo,
            """
            INSERT INTO finance_ledger_approval_exceptions
              (tenant_id, company_id, exception_number, source, action, subject_type, subject_id,
               subject, same_person, override, prepared_by_user_id, approved_by_user_id, reason,
               separation_change_id, recorded_at)
            VALUES (41, 73, 1, 'finance/payables', 'document_approval', 'bill', 7, 'Bill 7',
                    true, false, 91, 91, 'x', $1, now())
            """,
            [off.id]
          )
        end)
      end

      # And a row whose same_person flag misstates the people.
      assert_raise Postgrex.Error, ~r/finance_ledger_approval_exceptions_same_person/, fn ->
        Repo.transaction(fn ->
          SQL.query!(
            Repo,
            """
            INSERT INTO finance_ledger_approval_exceptions
              (tenant_id, company_id, exception_number, source, action, subject_type, subject_id,
               subject, same_person, override, prepared_by_user_id, approved_by_user_id, reason,
               recorded_at)
            VALUES (41, 73, 1, 'finance/payables', 'match_override', 'bill', 7, 'Bill 7',
                    false, true, 91, 91, 'x', now())
            """,
            []
          )
        end)
      end
    end
  end

  describe "reviews" do
    setup context do
      turn_off!(context.clerk)
      :ok = Ledger.check_approval(context.clerk, 73, approval([%{user_id: 91}]))
      {:ok, [exception]} = Ledger.list_approval_exceptions(context.clerk, 73)
      %{exception: exception}
    end

    test "are recorded once, by someone independent", context do
      %{clerk: clerk, reviewer: reviewer, exception: exception} = context

      assert {:error, :reviewer_not_independent} =
               Ledger.review_approval_exception(clerk, 73, exception.id, %{})

      assert {:ok, %{review: review}} =
               Ledger.review_approval_exception(reviewer, 73, exception.id, %{
                 note: "Invoice checked"
               })

      assert %{note: "Invoice checked", reviewed_by_user_id: 93, reviewed_at: %DateTime{}} =
               review

      assert {:error, :already_reviewed} =
               Ledger.review_approval_exception(context.approver, 73, exception.id, %{})

      assert {:error, :exception_not_found} =
               Ledger.review_approval_exception(reviewer, 73, -1, %{})
    end

    test "filter the listing", context do
      %{clerk: clerk, reviewer: reviewer, exception: exception} = context
      :ok = Ledger.check_approval(clerk, 73, approval([%{user_id: 91}], %{subject_id: 8}))
      {:ok, _} = Ledger.review_approval_exception(reviewer, 73, exception.id, %{})

      assert {:ok, [%{subject_id: 7}]} =
               Ledger.list_approval_exceptions(clerk, 73, reviewed: true)

      assert {:ok, [%{subject_id: 8}]} =
               Ledger.list_approval_exceptions(clerk, 73, reviewed: false)

      now = DateTime.utc_now()
      hour_ago = DateTime.add(now, -3600)

      assert {:ok, [_, _]} =
               Ledger.list_approval_exceptions(clerk, 73,
                 recorded_from: hour_ago,
                 recorded_before: DateTime.add(now, 3600)
               )

      assert {:ok, []} = Ledger.list_approval_exceptions(clerk, 73, recorded_before: hour_ago)

      assert {:ok, []} =
               Ledger.list_approval_exceptions(clerk, 73, recorded_from: DateTime.add(now, 3600))

      assert {:error, :invalid_option} =
               Ledger.list_approval_exceptions(clerk, 73, recorded_from: Date.utc_today())

      assert {:ok, [%{exception_number: 2}]} =
               Ledger.list_approval_exceptions(clerk, 73, after: 1)

      assert {:ok, [%{exception_number: 1}]} =
               Ledger.list_approval_exceptions(clerk, 73, limit: 1)

      assert {:error, :invalid_option} =
               Ledger.list_approval_exceptions(clerk, 73, reviewed: "yes")

      assert {:error, :invalid_option} = Ledger.list_approval_exceptions(clerk, 73, limit: 501)
    end

    test "the database refuses a review by the approver", context do
      %{exception: exception} = context

      assert_raise Postgrex.Error, ~r/neither approved nor prepared/, fn ->
        Repo.transaction(fn ->
          SQL.query!(
            Repo,
            "INSERT INTO finance_ledger_approval_exception_reviews " <>
              "(tenant_id, company_id, exception_id, reviewed_by_user_id, reviewed_at) " <>
              "VALUES (41, 73, $1, 91, now())",
            [exception.id]
          )
        end)
      end
    end
  end

  describe "manual journals" do
    test "post only when someone other than the submitter approves", context do
      %{clerk: clerk, approver: approver} = context

      assert {:ok, journal} = Ledger.submit_journal(clerk, 73, journal(context))

      assert %{
               journal_number: 1,
               status: "submitted",
               decision: nil,
               submitted_by_user_id: 91,
               submitted_at: %DateTime{},
               lines: [%{line_number: 1}, %{line_number: 2}]
             } = journal

      assert {:ok, []} = Ledger.list_entries(clerk, 73)
      assert {:error, :same_person} = Ledger.approve_journal(clerk, 73, journal.id)

      assert {:ok, %{status: "approved", decision: decision}} =
               Ledger.approve_journal(approver, 73, journal.id)

      assert %{event: "approved", actor_user_id: 92, entry_id: entry_id} = decision

      assert {:ok,
              %{
                entry_number: 1,
                description: "Accrual",
                reference: "J-1",
                posted_by_user_id: 92,
                lines: [_, _]
              }} = Ledger.get_entry(clerk, 73, entry_id)

      assert {:error, :journal_decided} = Ledger.approve_journal(approver, 73, journal.id)
      assert {:ok, []} = Ledger.list_approval_exceptions(clerk, 73)
    end

    test "post by the submitter while separation is off, as an approval exception", context do
      %{clerk: clerk} = context
      turn_off!(clerk)
      {:ok, journal} = Ledger.submit_journal(clerk, 73, journal(context))

      assert {:ok, %{status: "approved"}} = Ledger.approve_journal(clerk, 73, journal.id)

      assert {:ok,
              [
                %{
                  source: "finance/ledger",
                  action: "journal_approval",
                  subject_type: "journal",
                  subject: "Journal 1: Accrual",
                  same_person: true
                }
              ]} = Ledger.list_approval_exceptions(clerk, 73)
    end

    test "are checked when submitted and again when approved", context do
      %{clerk: clerk, approver: approver, cash: cash} = context

      assert {:error, changeset} =
               Ledger.submit_journal(
                 clerk,
                 73,
                 journal(context, %{lines: [%{account_id: cash.id, debit: "10.00"}]})
               )

      assert %{lines: ["needs at least two lines"]} = errors_on(changeset)

      {:ok, journal} = Ledger.submit_journal(clerk, 73, journal(context))
      {:ok, _cash} = Ledger.update_account(clerk, 73, context.income.id, %{active: false})

      assert {:error, %Ecto.Changeset{}} = Ledger.approve_journal(approver, 73, journal.id)
      assert {:ok, %{status: "submitted"}} = Ledger.get_journal(clerk, 73, journal.id)
    end

    test "are rejected with a reason and never post", context do
      %{clerk: clerk, approver: approver} = context
      {:ok, journal} = Ledger.submit_journal(clerk, 73, journal(context))

      assert {:error, changeset} = Ledger.reject_journal(approver, 73, journal.id, %{})
      assert %{reason: ["is required to reject a journal"]} = errors_on(changeset)

      assert {:ok, %{status: "rejected", decision: %{reason: "Wrong period", entry_id: nil}}} =
               Ledger.reject_journal(approver, 73, journal.id, %{reason: "Wrong period"})

      assert {:error, :journal_decided} = Ledger.approve_journal(approver, 73, journal.id)
      assert {:ok, []} = Ledger.list_entries(clerk, 73)

      {:ok, second} = Ledger.submit_journal(clerk, 73, journal(context))
      assert {:ok, [%{id: id}]} = Ledger.list_journals(clerk, 73, status: "submitted")
      assert id == second.id
      assert {:ok, [%{status: "rejected"}]} = Ledger.list_journals(clerk, 73, status: "rejected")
      assert {:ok, [_, _]} = Ledger.list_journals(clerk, 73)
      assert {:error, :invalid_option} = Ledger.list_journals(clerk, 73, status: "posted")
    end

    test "each step asks its own capability", context do
      %{first_scope: system, clerk: clerk} = context
      poster = TestFixtures.sign_in!(system, 73, 96, [@view, @post])
      {:ok, journal} = Ledger.submit_journal(clerk, 73, journal(context))

      assert {:error, :unauthorized} = Ledger.submit_journal(poster, 73, journal(context))
      assert {:error, :unauthorized} = Ledger.approve_journal(poster, 73, journal.id)

      assert {:error, :unauthorized} =
               Ledger.reject_journal(poster, 73, journal.id, %{reason: "x"})
    end

    test "the database refuses an approval by the submitter without its exception", context do
      %{clerk: clerk, approver: approver} = context
      {:ok, journal} = Ledger.submit_journal(clerk, 73, journal(context))
      {:ok, entry} = Ledger.post_entry(approver, 73, Map.delete(journal(context), :reference))

      assert_raise Postgrex.Error, ~r/approved by someone other than whoever submitted it/, fn ->
        Repo.transaction(fn ->
          SQL.query!(
            Repo,
            "INSERT INTO finance_ledger_journal_events " <>
              "(tenant_id, company_id, journal_id, event, entry_id, actor_user_id, occurred_at) " <>
              "VALUES (41, 73, $1, 'approved', $2, 91, now())",
            [journal.id, entry.id]
          )
        end)
      end
    end
  end

  describe "reopening" do
    test "a period or fiscal year is recorded as an override", context do
      %{clerk: clerk, approver: approver} = context
      {:ok, year} = Ledger.open_fiscal_year(clerk, 73, %{start_date: ~D[2026-01-01]})
      [first | _] = year.periods
      {:ok, _} = Ledger.close_period(clerk, 73, first.id)

      assert {:ok, _} = Ledger.reopen_period(approver, 73, first.id, %{reason: "Late invoice"})

      assert {:ok,
              [
                %{
                  source: "finance/ledger",
                  action: "period_reopen",
                  subject_type: "period",
                  subject: "Period 2026-01-01 to 2026-01-31",
                  same_person: false,
                  override: true,
                  prepared_by_user_id: nil,
                  approved_by_user_id: 92,
                  reason: "Late invoice"
                }
              ]} = Ledger.list_approval_exceptions(clerk, 73)
    end
  end
end
