defmodule Bilimbi.Finance.Ledger.ClosingTest do
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
  @lock "finance.ledger.periods.lock"

  setup do
    context = TestFixtures.setup_ledger!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    operator =
      TestFixtures.sign_in!(context.first_scope, 73, 91, [
        @view,
        @manage,
        @post,
        @periods,
        @reopen,
        @lock
      ])

    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})

    accounts =
      for {code, type} <- [
            {"1000", "asset"},
            {"3000", "equity"},
            {"3100", "equity"},
            {"4000", "income"},
            {"4100", "income"},
            {"5000", "expense"}
          ],
          into: %{} do
        {:ok, account} =
          Ledger.create_account(operator, 73, %{code: code, name: code, account_type: type})

        {code, account}
      end

    Map.merge(context, %{operator: operator, accounts: accounts})
  end

  describe "fiscal years" do
    test "open as calendar-month periods, each later year after the previous one", context do
      %{operator: operator} = context

      assert {:ok, year} = Ledger.open_fiscal_year(operator, 73, %{start_date: ~D[2026-04-01]})

      assert %{
               start_date: ~D[2026-04-01],
               end_date: ~D[2027-03-31],
               status: "open",
               closing_entry_id: nil,
               opened_by_user_id: 91,
               opened_by_impersonator_id: nil
             } = year

      assert length(year.periods) == 12
      assert Enum.all?(year.periods, &(&1.status == "open"))

      assert [%{period_number: 1, start_date: ~D[2026-04-01], end_date: ~D[2026-04-30]} | _] =
               year.periods

      assert %{period_number: 11, start_date: ~D[2027-02-01], end_date: ~D[2027-02-28]} =
               Enum.at(year.periods, 10)

      assert {:ok, next} = Ledger.open_fiscal_year(operator, 73)
      assert %{start_date: ~D[2027-04-01], end_date: ~D[2028-03-31]} = next

      assert {:ok, [^year, ^next]} = Ledger.list_fiscal_years(operator, 73)
      assert {:ok, ^next} = Ledger.get_fiscal_year(operator, 73, next.id)
      assert {:error, :fiscal_year_not_found} = Ledger.get_fiscal_year(operator, 73, -1)
      TestFixtures.check_deferred_constraints!()
    end

    test "take any whole months from one to 24", context do
      %{operator: operator} = context

      assert {:ok, %{periods: periods}} =
               Ledger.open_fiscal_year(operator, 73, %{
                 start_date: ~D[2026-07-01],
                 end_date: ~D[2027-12-31]
               })

      assert length(periods) == 18

      for {attributes, field} <- [
            {%{start_date: ~D[2028-01-15]}, :start_date},
            {%{start_date: ~D[2028-01-01], end_date: ~D[2028-06-15]}, :end_date},
            {%{start_date: ~D[2028-01-01], end_date: ~D[2030-01-31]}, :end_date},
            {%{start_date: ~D[2028-02-01]}, :start_date}
          ] do
        assert {:error, changeset} = Ledger.open_fiscal_year(operator, 73, attributes)
        assert Map.has_key?(errors_on(changeset), field)
      end
    end

    test "need an open book and the period grant", context do
      %{first_scope: system} = context
      clerk = TestFixtures.sign_in!(system, 74, 92, [@periods])

      assert {:error, :book_not_open} =
               Ledger.open_fiscal_year(clerk, 74, %{start_date: ~D[2026-01-01]})

      poster = TestFixtures.sign_in!(system, 73, 93, [@view, @post])

      assert {:error, :unauthorized} =
               Ledger.open_fiscal_year(poster, 73, %{start_date: ~D[2026-01-01]})

      assert {:error, :unauthorized} = Ledger.open_fiscal_year(system, 73)
      assert {:error, :company_not_found} = Ledger.list_fiscal_years(context.operator, 75)
    end
  end

  describe "closing periods" do
    setup context do
      {:ok, year} = Ledger.open_fiscal_year(context.operator, 73, %{start_date: ~D[2026-01-01]})
      %{year: year, january: period(year, 1), february: period(year, 2)}
    end

    test "refuses postings into a closed period, in the facade and in PostgreSQL", context do
      %{operator: operator, january: january} = context

      assert {:ok, _} = post(context, ~D[2026-01-15], "10")
      assert {:ok, %{status: "closed"}} = Ledger.close_period(operator, 73, january.id)

      assert {:error, changeset} = post(context, ~D[2026-01-31], "10")
      assert %{entry_date: ["falls in a closed period"]} = errors_on(changeset)
      assert {:ok, _} = post(context, ~D[2026-02-01], "10")

      assert_raise Postgrex.Error, ~r/falls in a closed period/, fn ->
        insert_entry_directly!(~D[2026-01-20])
      end
    end

    test "refuse postings before the first fiscal year, and after the last while controlled",
         context do
      assert {:error, changeset} = post(context, ~D[2025-12-31], "10")
      assert %{entry_date: ["is before the first fiscal year"]} = errors_on(changeset)
      assert {:error, changeset} = post(context, ~D[2027-01-01], "10")
      assert %{entry_date: ["falls in no fiscal period" <> _]} = errors_on(changeset)

      assert_raise Postgrex.Error, ~r/before the first fiscal year/, fn ->
        insert_entry_directly!(~D[2025-06-30])
      end
    end

    test "a controlled company's database refuses a date after its last year", _context do
      assert_raise Postgrex.Error, ~r/falls in no fiscal period/, fn ->
        insert_entry_directly!(~D[2027-01-01])
      end
    end

    test "close in date order; the last closes only with its year", context do
      %{operator: operator, year: year, january: january, february: february} = context

      assert {:error, :earlier_period_open} = Ledger.close_period(operator, 73, february.id)
      assert {:ok, _} = Ledger.close_period(operator, 73, january.id, %{reason: "Month end"})
      assert {:error, :period_not_open} = Ledger.close_period(operator, 73, january.id)
      assert {:ok, _} = Ledger.close_period(operator, 73, february.id)

      for number <- 3..11,
          do: {:ok, _} = Ledger.close_period(operator, 73, period(year, number).id)

      assert {:error, :closes_with_fiscal_year} =
               Ledger.close_period(operator, 73, period(year, 12).id)

      assert {:error, :period_not_found} = Ledger.close_period(operator, 73, -1)

      assert {:ok, [%{reason: "Month end"} = first, second | _]} =
               Ledger.list_closing_events(operator, 73, year.id)

      assert %{
               event_number: 1,
               fiscal_year_id: year_id,
               period_id: january_id,
               action: "close",
               recorded_by_user_id: 91,
               recorded_by_impersonator_id: nil,
               recorded_at: %DateTime{}
             } = first

      assert {year_id, january_id} == {year.id, january.id}
      assert %{event_number: 2, period_id: february_id, reason: nil} = second
      assert february_id == february.id
    end

    test "reopen in reverse order, with a reason and the reopen grant", context do
      %{first_scope: system, operator: operator, january: january, february: february} = context
      {:ok, _} = Ledger.close_period(operator, 73, january.id)
      {:ok, _} = Ledger.close_period(operator, 73, february.id)

      closer = TestFixtures.sign_in!(system, 73, 94, [@view, @periods])

      assert {:error, :unauthorized} =
               Ledger.reopen_period(closer, 73, february.id, %{reason: "Late invoice"})

      assert {:error, changeset} = Ledger.reopen_period(operator, 73, february.id, %{})
      assert %{reason: ["is required to reopen"]} = errors_on(changeset)

      assert {:error, :later_period_closed} =
               Ledger.reopen_period(operator, 73, january.id, %{reason: "Late invoice"})

      assert {:ok, %{status: "open"}} =
               Ledger.reopen_period(operator, 73, february.id, %{reason: "Late invoice"})

      assert {:error, :period_not_closed} =
               Ledger.reopen_period(operator, 73, february.id, %{reason: "Again"})

      assert {:ok, _} = post(context, ~D[2026-02-10], "10")

      assert {:ok, [_, _, %{action: "reopen", reason: "Late invoice", recorded_by_user_id: 91}]} =
               Ledger.list_closing_events(operator, 73, context.year.id)

      # PostgreSQL refuses what the facade checks, whoever writes.
      assert_raise Postgrex.Error, ~r/finance_ledger_closing_events_reopen_reason/, fn ->
        insert_event_directly!(context.year.id, january.id, "reopen", nil)
      end

      assert_raise Postgrex.Error, ~r/while the period after it is/, fn ->
        {:ok, _} = Ledger.close_period(operator, 73, february.id)
        insert_event_directly!(context.year.id, january.id, "reopen", "Direct")
      end
    end

    test "lock closed periods in date order, for good", context do
      %{first_scope: system, operator: operator, january: january, february: february} = context

      assert {:error, :period_not_closed} = Ledger.lock_period(operator, 73, january.id)
      {:ok, _} = Ledger.close_period(operator, 73, january.id)
      {:ok, _} = Ledger.close_period(operator, 73, february.id)

      assert {:error, :earlier_period_unlocked} = Ledger.lock_period(operator, 73, february.id)

      closer = TestFixtures.sign_in!(system, 73, 94, [@view, @periods, @reopen])
      assert {:error, :unauthorized} = Ledger.lock_period(closer, 73, january.id)

      assert {:ok, %{status: "locked"}} =
               Ledger.lock_period(operator, 73, january.id, %{reason: "Filed"})

      assert {:error, :period_locked} = Ledger.lock_period(operator, 73, january.id)

      assert {:ok, _} = Ledger.reopen_period(operator, 73, february.id, %{reason: "Fix"})

      assert {:error, :period_locked} =
               Ledger.reopen_period(operator, 73, january.id, %{reason: "Fix"})

      assert {:error, changeset} = post(context, ~D[2026-01-05], "10")
      assert %{entry_date: ["falls in a locked period"]} = errors_on(changeset)

      assert_raise Postgrex.Error, ~r/is locked, not closed/, fn ->
        insert_event_directly!(context.year.id, january.id, "reopen", "Direct")
      end
    end

    test "the closing log and periods are append-only", context do
      {:ok, _} = Ledger.close_period(context.operator, 73, context.january.id)

      for sql <- [
            "UPDATE finance_ledger_closing_events SET action = 'reopen'",
            "DELETE FROM finance_ledger_closing_events",
            "UPDATE finance_ledger_periods SET end_date = end_date + 1",
            "DELETE FROM finance_ledger_fiscal_years"
          ] do
        assert_raise Postgrex.Error, ~r/finance ledger keeps/, fn -> direct!(sql, []) end
      end
    end
  end

  describe "year-end close" do
    setup context do
      %{operator: operator, accounts: accounts} = context
      {:ok, year} = Ledger.open_fiscal_year(operator, 73, %{start_date: ~D[2026-01-01]})

      post!(context, ~D[2026-01-01], [{"1000", :debit, "1000"}, {"3000", :credit, "1000"}])
      post!(context, ~D[2026-03-10], [{"1000", :debit, "700"}, {"4000", :credit, "700"}])
      post!(context, ~D[2026-06-20], [{"1000", :debit, "150.50"}, {"4100", :credit, "150.50"}])
      post!(context, ~D[2026-09-05], [{"5000", :debit, "320.25"}, {"1000", :credit, "320.25"}])

      {:ok, _} =
        Ledger.update_account(operator, 73, accounts["3100"].id, %{retained_earnings: true})

      %{year: year}
    end

    test "moves the year's profit into retained earnings and closes every period", context do
      %{operator: operator, accounts: accounts, year: year} = context

      assert {:ok, closed} = Ledger.close_fiscal_year(operator, 73, year.id)
      assert %{status: "closed", closing_entry_id: entry_id} = closed
      assert Enum.all?(closed.periods, &(&1.status == "closed"))

      assert {:ok, entry} = Ledger.get_entry(operator, 73, entry_id)

      assert %{
               entry_date: ~D[2026-12-31],
               description: "Close fiscal year 2026-01-01 to 2026-12-31"
             } = entry

      assert lines(entry, accounts) == [
               {"4000", "700", "0"},
               {"4100", "150.5", "0"},
               {"5000", "0", "320.25"},
               {"3100", "0", "530.25"}
             ]

      # The next year's opening balances follow from the ledger: as of the
      # year's end only balance-sheet accounts carry a balance.
      {:ok, balance} = Ledger.trial_balance(operator, 73, ~D[2026-12-31])

      assert balances(balance) == %{
               "1000" => {:debit, "1530.25"},
               "3000" => {:credit, "1000"},
               "3100" => {:credit, "530.25"},
               "4000" => :zero,
               "4100" => :zero,
               "5000" => :zero
             }

      assert {:ok, [_close_year | period_events]} =
               Ledger.list_closing_events(operator, 73, year.id)

      assert length(period_events) == 12
      TestFixtures.check_deferred_constraints!()
    end

    test "is idempotent", context do
      %{operator: operator, year: year} = context

      assert {:ok, closed} = Ledger.close_fiscal_year(operator, 73, year.id)
      {:ok, entries} = Ledger.list_entries(operator, 73)
      {:ok, events} = Ledger.list_closing_events(operator, 73, year.id)

      assert {:ok, ^closed} = Ledger.close_fiscal_year(operator, 73, year.id)
      assert {:ok, ^entries} = Ledger.list_entries(operator, 73)
      assert {:ok, ^events} = Ledger.list_closing_events(operator, 73, year.id)
    end

    test "debits retained earnings with a loss", context do
      %{operator: operator, accounts: accounts, year: year} = context
      post!(context, ~D[2026-12-31], [{"5000", :debit, "2000"}, {"1000", :credit, "2000"}])

      {:ok, %{closing_entry_id: entry_id}} = Ledger.close_fiscal_year(operator, 73, year.id)
      {:ok, entry} = Ledger.get_entry(operator, 73, entry_id)

      assert List.last(lines(entry, accounts)) == {"3100", "1469.75", "0"}
    end

    test "closes a year without income or expense with no entry", context do
      %{operator: operator} = context
      {:ok, next} = Ledger.open_fiscal_year(operator, 73)
      {:ok, _} = Ledger.close_fiscal_year(operator, 73, context.year.id)

      assert {:ok, %{status: "closed", closing_entry_id: nil}} =
               Ledger.close_fiscal_year(operator, 73, next.id)
    end

    test "closing and reopening a year need the posting capability as well", context do
      %{operator: operator, first_scope: system, year: year} = context

      no_posting = TestFixtures.sign_in!(system, 73, 96, [@view, @periods, @reopen])
      assert {:error, :unauthorized} = Ledger.close_fiscal_year(no_posting, 73, year.id)
      assert {:ok, %{status: "open", closing_entry_id: nil}} = year_of(operator, year)

      no_periods = TestFixtures.sign_in!(system, 73, 97, [@view, @post])
      assert {:error, :unauthorized} = Ledger.close_fiscal_year(no_periods, 73, year.id)
      assert {:ok, %{status: "open", closing_entry_id: nil}} = year_of(operator, year)

      {:ok, %{closing_entry_id: entry_id}} = Ledger.close_fiscal_year(operator, 73, year.id)

      assert {:error, :unauthorized} =
               Ledger.reopen_fiscal_year(no_posting, 73, year.id, %{reason: "Adjust"})

      assert {:ok, %{status: "closed", closing_entry_id: ^entry_id}} = year_of(operator, year)
      assert {:ok, %{reversed_by_entry_id: nil}} = Ledger.get_entry(operator, 73, entry_id)
    end

    test "needs an active retained-earnings account and the previous year closed", context do
      %{operator: operator, accounts: accounts, year: year} = context
      {:ok, next} = Ledger.open_fiscal_year(operator, 73)

      assert {:error, :earlier_period_open} = Ledger.close_fiscal_year(operator, 73, next.id)

      {:ok, _} = Ledger.update_account(operator, 73, accounts["3100"].id, %{active: false})

      assert {:error, :no_retained_earnings_account} =
               Ledger.close_fiscal_year(operator, 73, year.id)

      assert {:error, :fiscal_year_not_found} = Ledger.close_fiscal_year(operator, 73, -1)
      assert {:ok, %{status: "open"}} = Ledger.get_fiscal_year(operator, 73, year.id)
    end

    test "is undone only by reopening the year, with a reason", context do
      %{operator: operator, first_scope: system, year: year} = context
      {:ok, %{closing_entry_id: entry_id}} = Ledger.close_fiscal_year(operator, 73, year.id)

      assert {:error, :closing_entry} =
               Ledger.reverse_entry(operator, 73, entry_id, %{
                 entry_date: ~D[2027-01-01],
                 description: "Undo"
               })

      assert {:error, :fiscal_year_closed} =
               Ledger.reopen_period(operator, 73, period(year, 12).id, %{reason: "Adjust"})

      closer = TestFixtures.sign_in!(system, 73, 94, [@view, @periods])

      assert {:error, :unauthorized} =
               Ledger.reopen_fiscal_year(closer, 73, year.id, %{reason: "Adjust"})

      assert {:error, changeset} = Ledger.reopen_fiscal_year(operator, 73, year.id, %{})
      assert %{reason: ["is required to reopen"]} = errors_on(changeset)

      assert {:ok, reopened} =
               Ledger.reopen_fiscal_year(operator, 73, year.id, %{reason: "Audit adjustment"})

      assert %{status: "open", closing_entry_id: nil} = reopened
      assert %{status: "open"} = period(reopened, 12)
      assert %{status: "closed"} = period(reopened, 11)

      assert {:ok, %{reversed_by_entry_id: reversal_id}} =
               Ledger.get_entry(operator, 73, entry_id)

      assert {:ok, %{entry_date: ~D[2026-12-31]}} = Ledger.get_entry(operator, 73, reversal_id)

      assert {:ok, events} = Ledger.list_closing_events(operator, 73, year.id)

      assert [
               %{action: "reopen", period_id: nil, reason: "Audit adjustment"},
               %{action: "reopen", reason: "Audit adjustment"}
             ] = Enum.take(events, -2)

      assert {:error, :fiscal_year_not_closed} =
               Ledger.reopen_fiscal_year(operator, 73, year.id, %{reason: "Again"})

      # An adjustment in the reopened period, and the close posts afresh.
      post!(context, ~D[2026-12-15], [{"1000", :debit, "100"}, {"4000", :credit, "100"}])
      {:ok, %{closing_entry_id: new_entry_id}} = Ledger.close_fiscal_year(operator, 73, year.id)
      {:ok, new_entry} = Ledger.get_entry(operator, 73, new_entry_id)

      assert List.last(lines(new_entry, context.accounts)) == {"3100", "0", "630.25"}
      TestFixtures.check_deferred_constraints!()
    end

    test "a year never reopens past a locked last period or a closed next year", context do
      %{operator: operator, year: year} = context
      {:ok, next} = Ledger.open_fiscal_year(operator, 73)
      {:ok, _} = Ledger.close_fiscal_year(operator, 73, year.id)
      {:ok, _} = Ledger.close_period(operator, 73, period(next, 1).id)

      assert {:error, :later_period_closed} =
               Ledger.reopen_fiscal_year(operator, 73, year.id, %{reason: "Adjust"})

      {:ok, _} = Ledger.reopen_period(operator, 73, period(next, 1).id, %{reason: "Adjust"})

      for number <- 1..12,
          do: {:ok, _} = Ledger.lock_period(operator, 73, period(year, number).id)

      assert {:error, :period_locked} =
               Ledger.reopen_fiscal_year(operator, 73, year.id, %{reason: "Adjust"})
    end

    test "records the operator behind an impersonated session", context do
      %{first_scope: system, year: year} = context

      impersonated =
        Authentication.sign_in(system, 95, 73,
          impersonator_id: 91,
          impersonation_session_id: "borrowed-session"
        )

      TestFixtures.sign_in!(system, 73, 95, [@view, @periods])

      assert {:ok, _} = Ledger.close_period(impersonated, 73, period(year, 1).id)

      assert {:ok, [%{recorded_by_user_id: 95, recorded_by_impersonator_id: 91}]} =
               Ledger.list_closing_events(context.operator, 73, year.id)
    end
  end

  describe "retained-earnings designation" do
    test "is one equity account per company and moves when another is designated", context do
      %{operator: operator, accounts: accounts} = context

      assert {:ok, %{retained_earnings: true}} =
               Ledger.update_account(operator, 73, accounts["3000"].id, %{retained_earnings: true})

      assert {:ok, %{retained_earnings: true}} =
               Ledger.create_account(operator, 73, %{
                 code: "3200",
                 name: "3200",
                 account_type: "equity",
                 retained_earnings: true
               })

      assert {:ok, accounts_now} = Ledger.list_accounts(operator, 73)
      assert ["3200"] = for(%{retained_earnings: true, code: code} <- accounts_now, do: code)

      assert {:error, changeset} =
               Ledger.update_account(operator, 73, accounts["4000"].id, %{retained_earnings: true})

      assert %{retained_earnings: ["must be an equity account"]} = errors_on(changeset)
    end
  end

  defp year_of(scope, year), do: Ledger.get_fiscal_year(scope, 73, year.id)

  defp period(year, number), do: Enum.find(year.periods, &(&1.period_number == number))

  defp post(context, date, amount) do
    %{"1000" => cash, "4000" => income} = context.accounts

    Ledger.post_entry(context.operator, 73, %{
      entry_date: date,
      description: "Sale",
      lines: [%{account_id: cash.id, debit: amount}, %{account_id: income.id, credit: amount}]
    })
  end

  defp post!(context, date, lines) do
    {:ok, entry} =
      Ledger.post_entry(context.operator, 73, %{
        entry_date: date,
        description: "Entry",
        lines:
          Enum.map(lines, fn {code, side, amount} ->
            %{:account_id => context.accounts[code].id, side => amount}
          end)
      })

    entry
  end

  # `{code, debit, credit}` per line, amounts normalized.
  defp lines(entry, accounts) do
    codes = Map.new(accounts, fn {code, account} -> {account.id, code} end)

    for line <- entry.lines do
      {codes[line.account_id], normal(line.debit), normal(line.credit)}
    end
  end

  defp balances(balance) do
    Map.new(balance.rows, fn row ->
      cond do
        Decimal.gt?(row.debit_balance, 0) -> {row.code, {:debit, normal(row.debit_balance)}}
        Decimal.gt?(row.credit_balance, 0) -> {row.code, {:credit, normal(row.credit_balance)}}
        true -> {row.code, :zero}
      end
    end)
  end

  defp normal(amount), do: amount |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp insert_entry_directly!(date) do
    direct!(
      """
      INSERT INTO finance_ledger_entries
        (tenant_id, company_id, entry_number, entry_date, description, currency_code,
         posted_by_user_id, posted_at)
      VALUES (41, 73, 1, $1, 'Direct', 'XTS', 91, now())
      """,
      [date]
    )
  end

  defp insert_event_directly!(year_id, period_id, action, reason) do
    direct!(
      """
      INSERT INTO finance_ledger_closing_events
        (tenant_id, company_id, event_number, fiscal_year_id, period_id, action, reason,
         recorded_by_user_id, recorded_at)
      VALUES (41, 73, 1, $1, $2, $3, $4, 91, now())
      """,
      [year_id, period_id, action, reason]
    )
  end

  # A refused statement rolls back only its own savepoint.
  defp direct!(sql, params), do: Repo.transaction(fn -> SQL.query!(Repo, sql, params) end)
end
