defmodule Bilimbi.Finance.Payroll.PostingTest do
  use Bilimbi.Finance.Payroll.PayrollCase

  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  setup context do
    {:ok, configure!(context)}
  end

  defp lines_by_account(entry, accounts) do
    by_id = Map.new(accounts, fn {key, account} -> {account.id, key} end)

    Enum.map(entry.lines, fn line ->
      {Map.fetch!(by_id, line.account_id), side(line.debit), side(line.credit)}
    end)
  end

  # The ledger keeps zero on a line's other side.
  defp side(amount) do
    if Decimal.eq?(amount, 0),
      do: nil,
      else: amount |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  describe "post_payroll_run/3" do
    test "posts one balanced entry dated the pay date, one line per component and net pay",
         context do
      run!()

      assert {:ok, posting} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert posting.source_kind == "payroll_run"
      assert posting.source_id == 1
      assert posting.source_reference == "2026-09 XTS"
      assert posting.entry_number == 1
      assert posting.entry_date == ~D[2026-09-30]
      assert decimal?(posting.total, "5650.00")
      assert posting.posted_by_user_id == 91
      assert posting.reversal == nil
      assert %DateTime{} = posting.posted_at

      assert {:ok, entry} = Ledger.get_entry(context.operator, 73, posting.entry_id)
      assert entry.description == "Payroll run 2026-09 XTS"
      assert entry.reference == "payroll_run 1: 2026-09 XTS"

      assert lines_by_account(entry, context.accounts) == [
               {:salaries, "5000", nil},
               {:fund_payable, nil, "550"},
               {:fund_expense, "650", nil},
               {:fund_payable, nil, "650"},
               {:tax_payable, nil, "120"},
               {:net_pay, nil, "4330"}
             ]

      assert {:ok, [run]} = Payroll.list_payroll_runs(context.operator, 73)
      assert run.posting.id == posting.id
      assert run.last_failure == nil
      assert {:ok, [listed]} = Payroll.list_postings(context.operator, 73)
      assert listed == Map.put(posting, :last_failure, nil)
    end

    test "posts once: a second call is refused and the database refuses a second posted event",
         context do
      run!()
      assert {:ok, posting} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert {:error, :already_posted} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert {:ok, [_posted]} = Payroll.list_posting_events(context.operator, 73)

      assert_raise Postgrex.Error, ~r/finance_payroll_posting_events_posted_unique/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_payroll_posting_events (tenant_id, company_id, source_kind, source_id, source_reference, event, entry_id, entry_number, entry_date, total, currency_code, actor_user_id, occurred_at) VALUES (41, 73, 'payroll_run', 1, 'again', 'posted', 99, 99, '2026-09-30', 1, 'XTS', 91, now())",
          []
        )
      end

      assert_raise Postgrex.Error, ~r/finance_payroll_posting_events_entry_unique/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_payroll_posting_events (tenant_id, company_id, source_kind, source_id, source_reference, event, entry_id, entry_number, entry_date, total, currency_code, actor_user_id, occurred_at) VALUES (41, 73, 'payroll_run', 2, 'other', 'posted', $1, 1, '2026-09-30', 1, 'XTS', 91, now())",
          [posting.entry_id]
        )
      end
    end

    test "rounds each component to the book's minor units and balances net pay from the rounded figures",
         context do
      run!(1, %{
        components: [
          %{code: "basic", direction: "earning", amount: "1000.004"},
          %{code: "fund", direction: "deduction", amount: "110.005"},
          %{code: "tax", direction: "deduction", amount: "0.004"}
        ]
      })

      assert {:ok, posting} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert {:ok, entry} = Ledger.get_entry(context.operator, 73, posting.entry_id)

      assert lines_by_account(entry, context.accounts) == [
               {:salaries, "1000", nil},
               {:fund_payable, nil, "110.01"},
               {:net_pay, nil, "889.99"}
             ]
    end

    test "debits net pay when deductions exceed earnings", context do
      run!(1, %{
        components: [
          %{code: "basic", direction: "earning", amount: "100"},
          %{code: "tax", direction: "deduction", amount: "150"}
        ]
      })

      assert {:ok, posting} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert {:ok, entry} = Ledger.get_entry(context.operator, 73, posting.entry_id)

      assert lines_by_account(entry, context.accounts) == [
               {:salaries, "100", nil},
               {:tax_payable, nil, "150"},
               {:net_pay, "50", nil}
             ]
    end

    test "refuses a run that is not finalised or unknown without recording a failure", context do
      run!(1, %{status: "calculated", finalised: false})
      assert {:error, :not_finalised} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert {:error, :source_not_found} = Payroll.post_payroll_run(context.operator, 73, 2)
      assert {:error, :source_not_found} = Payroll.post_payroll_run(context.operator, 73, "x")
      assert {:ok, []} = Payroll.list_posting_events(context.operator, 73)
    end

    test "records a failed attempt with its reason and lists it until a retry succeeds",
         context do
      run!(1, %{
        components: [
          %{code: "basic", direction: "earning", amount: "100"},
          %{code: "bonus", direction: "earning", amount: "50"},
          %{code: "levy", direction: "employer", amount: "5"}
        ]
      })

      assert {:error, {:failed, reason}} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert reason == "components not mapped to accounts: bonus (earning), levy (employer)"

      assert {:ok, [run]} = Payroll.list_payroll_runs(context.operator, 73)
      assert run.posting == nil
      assert %{action: "post", reason: ^reason, actor_user_id: 91} = run.last_failure
      assert {:ok, []} = Ledger.list_entries(context.operator, 73)

      for {code, direction, expense, liability} <- [
            {"bonus", "earning", context.accounts.salaries, nil},
            {"levy", "employer", context.accounts.fund_expense, context.accounts.fund_payable}
          ] do
        {:ok, _} =
          Payroll.put_mapping(context.operator, 73, %{
            kind: "component",
            code: code,
            direction: direction,
            expense_account_id: expense && expense.id,
            liability_account_id: liability && liability.id
          })
      end

      assert {:ok, posting} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert {:ok, [run]} = Payroll.list_payroll_runs(context.operator, 73)
      assert run.posting.id == posting.id
      assert run.last_failure == nil

      assert {:ok, [failed, posted]} = Payroll.list_posting_events(context.operator, 73)
      assert failed.event == "posting_failed"
      assert failed.reason == reason
      assert posted.event == "posted"
      assert DateTime.compare(failed.occurred_at, posted.occurred_at) == :lt
    end

    test "records the ledger's refusal of a closed period, and never reopens it", context do
      {:ok, year} =
        Ledger.open_fiscal_year(context.operator, 73, %{
          start_date: ~D[2026-01-01],
          end_date: ~D[2026-12-31]
        })

      [first | _] = year.periods
      {:ok, _} = Ledger.close_period(context.operator, 73, first.id, %{})
      run!(1, %{pay_date: first.start_date})

      assert {:error, {:failed, reason}} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert reason =~ "entry_date"

      assert {:ok, [%{event: "posting_failed"}]} =
               Payroll.list_posting_events(context.operator, 73)

      assert {:ok, %{periods: [%{status: "closed"} | _]}} =
               Ledger.get_fiscal_year(context.operator, 73, year.id)
    end

    test "records the book's currency and the unset accounts as failures", context do
      run!(1, %{currency_code: "XXX"})
      assert {:error, {:failed, reason}} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert reason == "the book is kept in XTS, the source in XXX"

      run!(2, %{components: []})

      assert {:error, {:failed, "the run's amounts are zero"}} =
               Payroll.post_payroll_run(context.operator, 73, 2)
    end

    test "records a run whose pay date is missing or invalid as a failure and still lists it",
         context do
      run!(1, %{pay_date: nil})

      assert {:ok, [listed]} = Payroll.list_payroll_runs(context.operator, 73)
      assert listed.pay_date == nil

      assert {:error, {:failed, "the run's pay date is missing or invalid"}} =
               Payroll.post_payroll_run(context.operator, 73, 1)

      assert {:ok, [failed]} = Payroll.list_payroll_runs(context.operator, 73)
      assert failed.last_failure.reason == "the run's pay date is missing or invalid"
      assert failed.posting == nil
    end

    test "needs the posting capability, the ledger's, and the source's", context do
      run!()
      viewer = TestFixtures.sign_in!(context.first_scope, 73, 92, ["finance.payroll.view"])
      assert {:error, :unauthorized} = Payroll.post_payroll_run(viewer, 73, 1)

      TestFixtures.revoke!(context.first_scope, 73, 91, "finance.ledger.entries.post")

      assert {:error, {:failed, "the actor may not post to the ledger"}} =
               Payroll.post_payroll_run(context.operator, 73, 1)

      StubPeopleSource.refuse!(91)
      assert {:error, :unauthorized} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert {:error, :unauthorized} = Payroll.list_payroll_runs(context.operator, 73)
      assert {:error, :unauthorized} = Payroll.list_payroll_runs(context.first_scope, 73)
    end
  end

  describe "post_claim/3" do
    test "posts the approved amount against the category's expense and claims payable", context do
      StubPeopleSource.put_claim!(%{id: 7, amount: "123.45", approved_on: ~D[2026-09-20]})

      assert {:ok, posting} = Payroll.post_claim(context.operator, 73, 7)
      assert posting.source_kind == "claim"
      assert posting.source_reference == "claim 7 travel"
      assert posting.entry_date == ~D[2026-09-20]
      assert decimal?(posting.total, "123.45")

      assert {:ok, entry} = Ledger.get_entry(context.operator, 73, posting.entry_id)
      assert entry.description == "Staff claim 7 travel"
      assert entry.reference == "claim 7: claim 7 travel"

      assert lines_by_account(entry, context.accounts) == [
               {:travel, "123.45", nil},
               {:claims_payable, nil, "123.45"}
             ]

      assert {:error, :already_posted} = Payroll.post_claim(context.operator, 73, 7)
      assert {:ok, [claim]} = Payroll.list_claims(context.operator, 73)
      assert claim.posting.id == posting.id
    end

    test "records an unmapped category as a failure", context do
      StubPeopleSource.put_claim!(%{id: 8, category_code: "meals"})

      assert {:error, {:failed, "claim category not mapped to an account: meals"}} =
               Payroll.post_claim(context.operator, 73, 8)

      StubPeopleSource.put_claim!(%{id: 9, category_code: nil})

      assert {:error, {:failed, "the claim's category is unknown"}} =
               Payroll.post_claim(context.operator, 73, 9)

      assert {:error, :source_not_found} = Payroll.post_claim(context.operator, 73, 10)
      assert {:ok, [eight, nine]} = Payroll.list_claims(context.operator, 73)
      assert eight.last_failure.reason =~ "meals"
      assert nine.last_failure.reason =~ "unknown"
    end
  end

  describe "post_claim/3 dates" do
    test "records a claim whose approval date cannot be worked out as a failure", context do
      StubPeopleSource.put_claim!(%{id: 11, approved_on: nil})

      assert {:error, {:failed, "the claim's approval date could not be worked out"}} =
               Payroll.post_claim(context.operator, 73, 11)

      assert {:ok, [claim]} = Payroll.list_claims(context.operator, 73)
      assert claim.approved_on == nil
      assert claim.last_failure.reason =~ "approval date"
    end
  end

  describe "post_claims/3" do
    test "posts a batch from one read of the source, and reports each claim", context do
      StubPeopleSource.put_claim!(%{id: 1, amount: "10.00"})
      StubPeopleSource.put_claim!(%{id: 2, amount: "20.00"})
      StubPeopleSource.put_claim!(%{id: 3, category_code: "meals"})
      {:ok, _first} = Payroll.post_claim(context.operator, 73, 1)
      before = StubPeopleSource.claims_reads()

      assert {:ok, outcomes} = Payroll.post_claims(context.operator, 73, [1, 2, 3, 4, "x"])
      assert StubPeopleSource.claims_reads() == before + 1

      assert [
               {1, {:error, :already_posted}},
               {2, {:ok, two}},
               {3, {:error, {:failed, "claim category not mapped to an account: meals"}}},
               {4, {:error, :source_not_found}},
               {"x", {:error, :source_not_found}}
             ] = outcomes

      assert two.source_id == 2
      assert decimal?(two.total, "20.00")
    end

    test "is refused as a whole without the capability or the source", context do
      StubPeopleSource.put_claim!(%{id: 1})
      viewer = TestFixtures.sign_in!(context.first_scope, 73, 92, ["finance.payroll.view"])
      assert {:error, :unauthorized} = Payroll.post_claims(viewer, 73, [1])

      StubPeopleSource.uninstall!()
      assert {:error, :people_unavailable} = Payroll.post_claims(context.operator, 73, [1])
    end
  end

  describe "reverse_posting/4" do
    test "the entry is the run's own: the ledger refuses a direct reversal", context do
      run!()
      {:ok, posting} = Payroll.post_payroll_run(context.operator, 73, 1)
      owner = %{module: "finance/payroll", record: "payroll_run:1"}
      assert {:ok, %{owner: ^owner}} = Ledger.get_entry(context.operator, 73, posting.entry_id)

      assert {:error, {:owned_by, ^owner}} =
               Ledger.reverse_entry(context.operator, 73, posting.entry_id, %{
                 entry_date: ~D[2026-10-02],
                 description: "Undo"
               })

      assert {:ok, [run]} = Payroll.list_payroll_runs(context.operator, 73)
      assert run.posting.reversal == nil
    end

    test "posts the mirror entry with a reason, once, and lists both entries", context do
      run!()
      {:ok, posting} = Payroll.post_payroll_run(context.operator, 73, 1)

      assert {:error, changeset} =
               Payroll.reverse_posting(context.operator, 73, posting.id, %{reason: "  "})

      assert %{reason: ["can't be blank"]} = errors_on(changeset)

      assert {:ok, reversed} =
               Payroll.reverse_posting(context.operator, 73, posting.id, %{
                 reason: "run posted to the wrong month",
                 entry_date: ~D[2026-10-02]
               })

      assert reversed.id == posting.id
      assert reversed.reversal.entry_number == 2
      assert reversed.reversal.entry_date == ~D[2026-10-02]
      assert reversed.reversal.reason == "run posted to the wrong month"
      assert reversed.reversal.reversed_by_user_id == 91

      assert {:ok, entry} = Ledger.get_entry(context.operator, 73, reversed.reversal.entry_id)
      assert entry.reverses_entry_id == posting.entry_id
      assert entry.owner == %{module: "finance/payroll", record: "payroll_run:1"}
      assert entry.description == "Reversal of Payroll run 2026-09 XTS"
      assert [{:salaries, nil, "5000"} | _] = lines_by_account(entry, context.accounts)

      assert {:error, :already_reversed} =
               Payroll.reverse_posting(context.operator, 73, posting.id, %{reason: "again"})

      assert {:error, :posting_not_found} =
               Payroll.reverse_posting(context.operator, 73, 999, %{reason: "none"})

      assert {:ok, [run]} = Payroll.list_payroll_runs(context.operator, 73)
      assert run.posting.reversal.entry_id == entry.id
      # A reversed source is not posted again.
      assert {:error, :already_posted} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert {:ok, got} = Payroll.get_posting(context.operator, 73, posting.id)
      assert got == Map.put(reversed, :last_failure, nil)
    end

    test "defaults the reversal date to the company's local today, not UTC's", context do
      before = DateTime.utc_now()
      zone = if before.hour < 12, do: "Etc/GMT+12", else: "Pacific/Kiritimati"
      TestFixtures.put_company_timezone!(context.first_scope, 73, zone)
      run!()
      {:ok, posting} = Payroll.post_payroll_run(context.operator, 73, 1)

      assert {:ok, reversed} =
               Payroll.reverse_posting(context.operator, 73, posting.id, %{reason: "wrong month"})

      local_dates =
        for instant <- [before, DateTime.utc_now()] do
          {:ok, local} =
            DateTime.shift_zone(instant, zone, Bilimbi.Base.DateTime.time_zone_database())

          DateTime.to_date(local)
        end

      refute DateTime.to_date(before) in local_dates
      assert reversed.reversal.entry_date in local_dates
    end

    test "records a refused reversal and the database refuses a reversal of nothing", context do
      run!()
      {:ok, posting} = Payroll.post_payroll_run(context.operator, 73, 1)

      assert {:error, {:failed, reason}} =
               Payroll.reverse_posting(context.operator, 73, posting.id, %{
                 reason: "too early",
                 entry_date: ~D[2026-09-01]
               })

      assert reason =~ "cannot be before the reversed entry's date"
      assert {:ok, [run]} = Payroll.list_payroll_runs(context.operator, 73)
      assert %{action: "reverse", reason: ^reason} = run.last_failure

      assert_raise Postgrex.Error, ~r/reverses only a posted source/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_payroll_posting_events (tenant_id, company_id, source_kind, source_id, source_reference, event, entry_id, entry_number, entry_date, total, currency_code, reason, actor_user_id, occurred_at) VALUES (41, 73, 'claim', 5, 'claim 5', 'reversed', 98, 98, '2026-09-30', 1, 'XTS', 'why', 91, now())",
          []
        )
      end

      assert_raise Postgrex.Error, ~r/UPDATE is refused/, fn ->
        SQL.query!(Repo, "UPDATE finance_payroll_posting_events SET reason = 'x'", [])
      end

      assert_raise Postgrex.Error, ~r/DELETE is refused/, fn ->
        SQL.query!(Repo, "DELETE FROM finance_payroll_posting_events", [])
      end
    end
  end

  describe "without a source" do
    test "nothing is listed or posted, and the postings made are still read", context do
      run!()
      {:ok, posting} = Payroll.post_payroll_run(context.operator, 73, 1)
      StubPeopleSource.uninstall!()

      refute Payroll.people_available?()
      assert {:error, :people_unavailable} = Payroll.list_payroll_runs(context.operator, 73)
      assert {:error, :people_unavailable} = Payroll.list_claims(context.operator, 73)
      assert {:error, :people_unavailable} = Payroll.post_payroll_run(context.operator, 73, 1)
      assert {:error, :people_unavailable} = Payroll.post_claim(context.operator, 73, 1)
      assert {:ok, [listed]} = Payroll.list_postings(context.operator, 73)
      assert listed.id == posting.id

      assert {:ok, reversed} =
               Payroll.reverse_posting(context.operator, 73, posting.id, %{reason: "wrong"})

      assert reversed.reversal.entry_number == 2
    end
  end
end
