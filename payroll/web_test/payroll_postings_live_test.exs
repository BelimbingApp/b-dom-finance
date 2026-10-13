defmodule BilimbiWeb.FinancePayrollPostingsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Payroll
  alias Bilimbi.Finance.Payroll.PageFixtures, as: Helpers
  alias Bilimbi.Finance.Payroll.PayrollCase
  alias Bilimbi.Finance.Payroll.PeopleSource
  alias Bilimbi.Finance.Payroll.StubPeopleSource

  @view "finance.payroll.view"
  @post "finance.payroll.postings.post"
  @ledger ~w(finance.ledger.view finance.ledger.entries.post)

  setup do
    signed_in_identity!()
    on_exit(&StubPeopleSource.uninstall!/0)
    scene = Helpers.setup_scene!()
    PayrollCase.run!(1)
    PayrollCase.run!(2, %{reference: "2026-10 XTS", status: "locked", finalised: false})
    StubPeopleSource.put_claim!(%{id: 7, amount: "40.00"})
    StubPeopleSource.put_claim!(%{id: 8, category_code: "meals", reference: "claim 8 lunch"})
    scene
  end

  test "needs the view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/finance/payroll")
  end

  test "lists the runs and claims with their standing and withholds the actions without the grant",
       %{conn: conn} do
    grant_capabilities!([@view | @ledger])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payroll")

    assert has_element?(view, "#payroll-run-1", "2026-09 XTS")
    assert has_element?(view, "#payroll-run-1", "not posted")
    assert has_element?(view, "#payroll-run-2", "locked")
    assert has_element?(view, "#payroll-claim-7", "claim 7 travel")
    assert has_element?(view, "#payroll-claim-8", "meals")
    refute has_element?(view, "#payroll-post-run-1")
    refute has_element?(view, "#payroll-post-claim-7")
    refute has_element?(view, "#payroll-post-all-claims")
    assert has_element?(view, "#payroll-postings-table")
  end

  test "posts a run and a claim, shows a failure with its reason, retries, and reverses with a reason",
       %{conn: conn, operator: operator, accounts: accounts} do
    grant_capabilities!([@view, @post | @ledger])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payroll")

    # Only the finalised run offers to post.
    assert has_element?(view, "#payroll-post-run-1")
    refute has_element?(view, "#payroll-post-run-2")

    view |> element("#payroll-post-run-1") |> render_click()
    assert has_element?(view, "#payroll-run-1", "entry 1")
    assert has_element?(view, "#payroll-reverse-run-1")
    refute has_element?(view, "#payroll-post-run-1")

    assert {:ok, [%{entry_number: 1, source_kind: "payroll_run"}]} =
             Payroll.list_postings(operator, 73)

    # The unmapped category fails and says why; the mapped one posts.
    view |> element("#payroll-post-all-claims") |> render_click()
    assert has_element?(view, "#payroll-claim-7", "entry 2")
    assert has_element?(view, "#payroll-claim-8", "failed")

    assert has_element?(
             view,
             "#payroll-claim-8",
             "claim category not mapped to an account: meals"
           )

    assert has_element?(view, "#payroll-post-claim-8", "Retry posting")

    {:ok, _} =
      Payroll.put_mapping(operator, 73, %{
        kind: "claim_category",
        code: "meals",
        direction: "claim",
        expense_account_id: accounts.travel.id
      })

    view |> element("#payroll-post-claim-8") |> render_click()
    assert has_element?(view, "#payroll-claim-8", "entry 3")
    assert has_element?(view, "#payroll-posting-1", "Payroll run 2026-09 XTS")

    # A reversal needs a reason and lists both entries.
    view |> element("#payroll-reverse-run-1") |> render_click()
    assert has_element?(view, "#payroll-reversal-form")

    view
    |> form("#payroll-reversal-form", reversal: %{reason: "posted to the wrong month"})
    |> render_submit()

    assert has_element?(view, "#payroll-run-1", "reversed")
    assert has_element?(view, "#payroll-posting-1", "reversed by entry 4")
    assert has_element?(view, "#payroll-posting-1", "posted to the wrong month")
    refute has_element?(view, "#payroll-reversal-form")
    refute has_element?(view, "#payroll-reverse-run-1")
    assert {:ok, entries} = Ledger.list_entries(operator, 73)
    assert length(entries) == 4
  end

  test "refuses a posting once the grant is revoked after mount", %{
    conn: conn,
    scope: scope,
    operator: operator
  } do
    grant_capabilities!([@view, @post | @ledger])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payroll")
    revoke_capability!(scope, @post)

    view |> element("#payroll-post-run-1") |> render_click()
    assert {:ok, []} = Payroll.list_postings(operator, 73)
    refute has_element?(view, "#payroll-post-run-1")
  end

  test "says so when no source is installed, and still lists what was posted", %{
    conn: conn,
    operator: operator
  } do
    grant_capabilities!([@view | @ledger])
    {:ok, posting} = Payroll.post_payroll_run(operator, 73, 1)
    StubPeopleSource.uninstall!()

    if PeopleSource.installed() == :unavailable do
      {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/payroll")
      assert has_element?(view, "#payroll-source-unavailable")
      refute has_element?(view, "#payroll-runs")
      assert has_element?(view, "#payroll-posting-#{posting.id}", "2026-09 XTS")
    end
  end

  # With People mounted the installed source answers from the real payroll
  # and claims facades; without it this suite proves nothing more and says so.
  if PeopleSource.installed() == :unavailable do
    describe "the installed source" do
      test "is unavailable without People, so nothing is listed or posted", %{operator: operator} do
        StubPeopleSource.uninstall!()
        refute Payroll.people_available?()
        assert {:error, :people_unavailable} = Payroll.list_payroll_runs(operator, 73)
        assert {:error, :people_unavailable} = Payroll.post_claim(operator, 73, 1)
      end
    end
  else
    describe "the installed source" do
      test "posts a real approved run and a real approved claim", %{
        scope: scope,
        operator: operator
      } do
        StubPeopleSource.uninstall!()
        {:ok, %{payroll: payroll, claims: claims}} = PeopleSource.facades()
        people = fn name -> Module.concat(["Bilimbi", "People", name]) end

        # People's own tables and fixtures, by the names its tests use.
        apply(Module.concat(payroll, TestFixtures), :create_tables!, [])
        apply(Module.concat(claims, TestFixtures), :create_claim_tables!, [])
        apply(Module.concat(people.("Attendance"), TestFixtures), :create_attendance_tables!, [])
        apply(Module.concat(people.("Leave"), TestFixtures), :create_leave_tables!, [])
        :ok = Bilimbi.Core.Employee.ensure_system_types()

        {:ok, employee} =
          Bilimbi.Core.Employee.create_employee(scope, 73, %{
            employee_number: "E-1",
            full_name: "Employee One"
          })

        users = Module.concat(["Bilimbi", "Core", "User", "TestFixtures"])

        apply(users, :insert_user!, [
          %{id: 93, company_id: 73, employee_id: employee.id, email: "claimant@example.test"}
        ])

        apply(users, :insert_user!, [%{id: 94, company_id: 73, email: "reviewer@example.test"}])

        workforce = people.("Workforce")

        preparer =
          Bilimbi.Finance.Payroll.TestFixtures.sign_in!(
            scope,
            73,
            92,
            ~w(people.workforce.settings.manage people.payroll.view people.payroll.manage people.claims.manage people.claims.approve)
          )

        reviewer =
          Bilimbi.Finance.Payroll.TestFixtures.sign_in!(
            scope,
            73,
            94,
            ~w(people.payroll.view people.payroll.approve)
          )

        claimant =
          Bilimbi.Finance.Payroll.TestFixtures.sign_in!(scope, 73, 93, ~w(people.claims.submit))

        {:ok, _} = apply(workforce, :put_working_statuses, [preparer, 73, ["active"]])

        # A finalised run: setup frozen, one earning and one deduction
        # accepted, locked, calculated, and approved by an independent user.
        {:ok, _} = apply(payroll, :put_settings, [preparer, 73, "Jurisdiction A", ["XTS"]])
        dates = %{effective_from: "2026-01-01"}

        {:ok, classification} =
          apply(payroll, :create_classification, [
            preparer,
            73,
            Map.merge(dates, %{code: "class-a", name: "Classification A"})
          ])

        items =
          for code <- ["basic", "fund"], into: %{} do
            {:ok, item} =
              apply(payroll, :create_item, [
                preparer,
                73,
                Map.merge(dates, %{
                  code: code,
                  name: "Item #{code}",
                  classification_id: classification.id,
                  currency: "XTS",
                  amount: "1"
                })
              ])

            {code, item}
          end

        {:ok, period} =
          apply(payroll, :create_period, [
            preparer,
            73,
            %{
              code: "2026-09",
              starts_on: "2026-09-01",
              ends_on: "2026-09-30",
              pay_on: "2026-09-30"
            }
          ])

        {:ok, run} = apply(payroll, :create_run, [preparer, 73, period.id, "XTS"])

        for {code, direction, units} <- [
              {"basic", "earning", "5000"},
              {"fund", "deduction", "550"}
            ] do
          {:ok, _} =
            apply(payroll, :intake, [
              preparer,
              73,
              run.id,
              %{
                source_key: "#{code}-1",
                employee_id: employee.id,
                item_id: items[code].id,
                on_date: "2026-09-15",
                units: units,
                direction: direction,
                evidence: "Attested"
              }
            ])
        end

        {:ok, _} = apply(payroll, :lock_run, [preparer, 73, run.id])
        {:ok, _} = apply(payroll, :calculate, [preparer, 73, run.id])
        {:ok, _} = apply(payroll, :decide_run, [reviewer, 73, run.id, "approved", "Checked"])

        # An approved claim of a category the mapping knows.
        {:ok, _} = apply(claims, :put_currencies, [preparer, 73, ["XTS"]])

        {:ok, category} =
          apply(claims, :create_category, [
            preparer,
            73,
            %{"code" => "travel", "name" => "Travel"}
          ])

        {:ok, claim_type} =
          apply(claims, :create_claim_type, [
            preparer,
            73,
            %{
              "category_id" => category.id,
              "code" => "mileage",
              "name" => "Mileage",
              "receipt_requirement" => "never"
            }
          ])

        {:ok, _} =
          apply(claims, :create_policy, [
            preparer,
            73,
            %{
              "claim_type_id" => claim_type.id,
              "effective_from" => "2026-01-01",
              "currency" => "XTS"
            }
          ])

        {:ok, claim} =
          apply(claims, :submit_request, [
            claimant,
            73,
            %{
              "claim_type_id" => claim_type.id,
              "incurred_on" => "2026-09-10",
              "amount" => "40.00",
              "currency" => "XTS"
            }
          ])

        {:ok, _} = apply(claims, :approve_request, [preparer, 73, claim.id, %{}])

        # The bookkeeper reads runs and claims through the source.
        assert {:ok, [listed]} = Payroll.list_payroll_runs(preparer, 73)
        assert listed.id == run.id and listed.finalised and listed.reference == "2026-09 XTS"
        assert listed.pay_date == ~D[2026-09-30]

        assert Enum.map(
                 listed.components,
                 &{&1.code, &1.direction,
                  &1.amount |> Decimal.normalize() |> Decimal.to_string(:normal)}
               ) ==
                 [{"basic", "earning", "5000"}, {"fund", "deduction", "550"}]

        bookkeeper =
          Bilimbi.Finance.Payroll.TestFixtures.sign_in!(
            scope,
            73,
            92,
            PayrollCase.all_capabilities()
          )

        assert {:ok, posting} = Payroll.post_payroll_run(bookkeeper, 73, run.id)
        assert Decimal.equal?(posting.total, "5000")
        assert posting.entry_date == ~D[2026-09-30]
        assert {:error, :already_posted} = Payroll.post_payroll_run(bookkeeper, 73, run.id)

        assert {:ok, [claim_listed]} = Payroll.list_claims(bookkeeper, 73)
        assert claim_listed.id == claim.id and claim_listed.category_code == "travel"
        assert {:ok, claim_posting} = Payroll.post_claim(bookkeeper, 73, claim.id)
        assert Decimal.equal?(claim_posting.total, "40.00")
        assert {:ok, entry} = Ledger.get_entry(operator, 73, claim_posting.entry_id)
        assert entry.reference == "claim #{claim.id}: claim #{claim.id} mileage"
      end
    end
  end
end
