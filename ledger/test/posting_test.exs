defmodule Bilimbi.Finance.Ledger.PostingTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures
  alias Ecto.Adapters.SQL

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  @view "finance.ledger.view"
  @manage "finance.ledger.accounts.manage"
  @post "finance.ledger.entries.post"

  setup do
    context = TestFixtures.setup_ledger!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, [@view, @manage, @post])
    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})
    {:ok, cash} = Ledger.create_account(operator, 73, account("1000", "asset"))
    {:ok, equity} = Ledger.create_account(operator, 73, account("3000", "equity"))
    {:ok, income} = Ledger.create_account(operator, 73, account("4000", "income"))

    Map.merge(context, %{operator: operator, cash: cash, equity: equity, income: income})
  end

  describe "posting" do
    test "stores a balanced entry with its lines in order", context do
      %{operator: operator, cash: cash, equity: equity, income: income} = context

      assert {:ok, entry} =
               Ledger.post_entry(operator, 73, %{
                 entry_date: ~D[2026-10-01],
                 description: "Opening capital",
                 reference: "J-1",
                 lines: [
                   %{account_id: cash.id, debit: "150.50"},
                   %{account_id: equity.id, credit: "100", description: "Capital"},
                   %{account_id: income.id, credit: "50.50"}
                 ]
               })

      assert %{
               entry_date: ~D[2026-10-01],
               currency_code: "XTS",
               reference: "J-1",
               reverses_entry_id: nil,
               reversed_by_entry_id: nil,
               posted_by_user_id: 91,
               posted_by_impersonator_id: nil
             } = entry

      assert {:ok, ^entry} = Ledger.get_entry(operator, 73, entry.id)

      assert [
               %{line_number: 1, account_id: cash_id, debit: debit, credit: zero},
               %{line_number: 2, account_id: equity_id, description: "Capital"},
               %{line_number: 3, account_id: income_id}
             ] = entry.lines

      assert {cash_id, equity_id, income_id} == {cash.id, equity.id, income.id}
      assert Decimal.equal?(debit, "150.50") and Decimal.equal?(zero, 0)
    end

    test "accepts string keys, as a form or an API sends them", context do
      assert {:ok, %{lines: [_, _]}} =
               Ledger.post_entry(context.operator, 73, %{
                 "entry_date" => "2026-10-01",
                 "description" => "From params",
                 "lines" => [
                   %{"account_id" => context.cash.id, "debit" => "10"},
                   %{"account_id" => context.income.id, "credit" => "10"}
                 ]
               })
    end

    test "refuses an entry whose debits and credits differ", context do
      assert {:error, changeset} =
               post(context, [debit(context.cash, "100"), credit(context.income, "99.99")])

      assert %{lines: ["debits and credits do not balance"]} = errors_on(changeset)
      assert {:ok, []} = Ledger.list_entries(context.operator, 73)
    end

    test "refuses fewer than two lines", context do
      assert {:error, changeset} = post(context, [debit(context.cash, "100")])
      assert %{lines: ["needs at least two lines"]} = errors_on(changeset)

      assert {:error, changeset} = post(context, [])
      assert %{lines: ["needs at least two lines"]} = errors_on(changeset)
    end

    test "refuses a line with both, neither, a negative, too fine, or too large an amount",
         context do
      %{cash: cash, income: income} = context

      for {line, field} <- [
            {%{account_id: cash.id, debit: "5", credit: "5"}, :debit},
            {%{account_id: cash.id}, :debit},
            {%{account_id: cash.id, debit: "-5"}, :debit},
            {%{account_id: cash.id, debit: "5.001"}, :debit},
            {%{account_id: cash.id, debit: "10000000000000000"}, :debit}
          ] do
        assert {:error, changeset} = post(context, [line, credit(income, "5")])
        assert %{lines: [line_errors, %{}]} = errors_on(changeset)
        assert Map.has_key?(line_errors, field)
      end
    end

    test "posts to an inactive account only when it is a listed settlement account", context do
      %{operator: operator, cash: cash, income: income} = context
      {:ok, _} = Ledger.update_account(operator, 73, cash.id, %{active: false})
      {:ok, _} = Ledger.update_account(operator, 73, income.id, %{active: false})
      lines = [debit(cash, "5"), credit(income, "5")]
      post = &Ledger.post_entry(operator, 73, entry(lines), &1)

      assert {:error, changeset} = post.([])

      assert %{lines: [%{account_id: ["is inactive"]}, %{account_id: ["is inactive"]}]} =
               errors_on(changeset)

      assert {:error, changeset} = post.(settlement_account_ids: [cash.id])
      assert %{lines: [%{}, %{account_id: ["is inactive"]}]} = errors_on(changeset)

      assert {:error, changeset} = post.(settlement_account_ids: [income.id])
      assert %{lines: [%{account_id: ["is inactive"]}, %{}]} = errors_on(changeset)

      for options <- [
            [settlement_account_ids: income.id],
            [settlement_account_ids: ["1"]],
            [settlement_account_ids: [nil]],
            [other: [income.id]],
            [:settlement_account_ids]
          ] do
        assert {:error, :invalid_option} = post.(options)
      end

      assert {:ok, %{lines: [_, _]}} = post.(settlement_account_ids: [cash.id, income.id])
    end

    test "refuses an inactive account and another company's account", context do
      %{first_scope: system, operator: operator, cash: cash, income: income} = context
      {:ok, _} = Ledger.update_account(operator, 73, income.id, %{active: false})

      assert {:error, changeset} = post(context, [debit(cash, "5"), credit(income, "5")])
      assert %{lines: [%{}, %{account_id: ["is inactive"]}]} = errors_on(changeset)

      sibling = TestFixtures.sign_in!(system, 74, 93, [@manage])
      {:ok, foreign} = Ledger.create_account(sibling, 74, account("4000", "income"))

      assert {:error, changeset} = post(context, [debit(cash, "5"), credit(foreign, "5")])

      assert %{lines: [%{}, %{account_id: ["is not an account of this company"]}]} =
               errors_on(changeset)
    end

    test "needs an open book and the posting grant", context do
      %{first_scope: system, cash: cash, income: income} = context
      clerk = TestFixtures.sign_in!(system, 74, 92, [@manage, @post])

      assert {:error, :book_not_open} =
               Ledger.post_entry(clerk, 74, %{
                 entry_date: ~D[2026-10-01],
                 description: "No book",
                 lines: []
               })

      viewer = TestFixtures.sign_in!(system, 73, 94, [@view, @manage])

      assert {:error, :unauthorized} =
               Ledger.post_entry(viewer, 73, entry([debit(cash, "1"), credit(income, "1")]))

      assert {:error, :unauthorized} = Ledger.post_entry(system, 73, entry([]))
    end

    test "records the operator behind an impersonated session", context do
      %{first_scope: system, cash: cash, income: income} = context
      TestFixtures.sign_in!(system, 73, 95, [@post])

      impersonated =
        Authentication.sign_in(system, 95, 73,
          impersonator_id: 91,
          impersonation_session_id: "borrowed-session"
        )

      assert {:ok, %{posted_by_user_id: 95, posted_by_impersonator_id: 91}} =
               Ledger.post_entry(impersonated, 73, entry([debit(cash, "1"), credit(income, "1")]))
    end

    test "lists entries in date order within optional bounds", context do
      %{operator: operator, cash: cash, income: income} = context
      lines = [debit(cash, "1"), credit(income, "1")]

      for date <- [~D[2026-10-03], ~D[2026-10-01], ~D[2026-10-02]] do
        {:ok, _} = Ledger.post_entry(operator, 73, %{entry([]) | entry_date: date, lines: lines})
      end

      assert {:ok, entries} = Ledger.list_entries(operator, 73)

      assert Enum.map(entries, & &1.entry_date) == [
               ~D[2026-10-01],
               ~D[2026-10-02],
               ~D[2026-10-03]
             ]

      assert {:ok, [%{entry_date: ~D[2026-10-02]}]} =
               Ledger.list_entries(operator, 73, from: ~D[2026-10-02], to: ~D[2026-10-02])

      assert {:ok, [_one]} = Ledger.list_entries(operator, 73, limit: 1)
    end

    test "pages past the limit with a cursor, reading every entry once", context do
      %{operator: operator, cash: cash, income: income} = context
      lines = [debit(cash, "1"), credit(income, "1")]

      posted =
        for date <- List.duplicate(~D[2026-10-01], 5) ++ [~D[2026-10-02], ~D[2026-10-02]] do
          {:ok, entry} =
            Ledger.post_entry(operator, 73, %{entry([]) | entry_date: date, lines: lines})

          entry.id
        end

      page = fn cursor ->
        {:ok, entries} = Ledger.list_entries(operator, 73, limit: 3, after: cursor)
        entries
      end

      first = page.(nil)
      second = page.({List.last(first).entry_date, List.last(first).id})
      third = page.({List.last(second).entry_date, List.last(second).id})
      fourth = page.({List.last(third).entry_date, List.last(third).id})

      assert Enum.map([first, second, third], &length/1) == [3, 3, 1]
      assert fourth == []
      assert Enum.map(first ++ second ++ third, & &1.id) == posted
    end

    test "refuses a malformed option instead of raising", context do
      %{operator: operator} = context

      for option <- [
            [limit: "10"],
            [limit: 0],
            [limit: 2.5],
            [limit: 501],
            [limit: nil],
            [from: "2026-10-01"],
            [to: 20_261_001],
            [after: ~D[2026-10-01]],
            [after: {"2026-10-01", 1}],
            [after: {~D[2026-10-01], "1"}],
            [after: {~D[2026-10-01], 0}],
            [after: {~D[2026-10-01], 9_223_372_036_854_775_808}]
          ] do
        assert {:error, :invalid_option} = Ledger.list_entries(operator, 73, option)
      end
    end
  end

  describe "entry numbers" do
    test "number each company's entries in posting order without gaps", context do
      %{first_scope: system, operator: operator, cash: cash, income: income} = context
      lines = [debit(cash, "1"), credit(income, "1")]

      assert {:ok, %{entry_number: 1, posted_at: %DateTime{}}} = post(context, lines)

      assert {:error, %Ecto.Changeset{}} =
               post(context, [debit(cash, "1"), credit(income, "2")])

      assert {:ok, %{entry_number: 2} = second} = post(context, lines)

      assert {:ok, %{entry_number: 3}} =
               Ledger.reverse_entry(operator, 73, second.id, %{
                 entry_date: ~D[2026-10-01],
                 description: "Reversal"
               })

      sibling = TestFixtures.sign_in!(system, 74, 93, [@manage, @post])
      {:ok, _} = Ledger.open_book(sibling, 74, %{currency_code: "XTS", minor_units: 2})
      {:ok, debit_account} = Ledger.create_account(sibling, 74, account("1000", "asset"))
      {:ok, credit_account} = Ledger.create_account(sibling, 74, account("4000", "income"))

      assert {:ok, %{entry_number: 1}} =
               Ledger.post_entry(
                 sibling,
                 74,
                 entry([debit(debit_account, "1"), credit(credit_account, "1")])
               )
    end

    test "are the database's, whatever a writer sends", context do
      {:ok, _} = post(context, [debit(context.cash, "1"), credit(context.income, "1")])

      %{rows: [[number, stamped?]]} =
        SQL.query!(
          Repo,
          """
          INSERT INTO finance_ledger_entries
            (tenant_id, company_id, entry_number, entry_date, description, currency_code,
             posted_by_user_id, posted_at)
          VALUES (41, 73, 1, '2026-10-01', 'Raw', 'XTS', 91, '2000-01-01')
          RETURNING entry_number, posted_at > '2026-01-01'
          """,
          []
        )

      assert {number, stamped?} == {2, true}
    end
  end

  describe "reversal" do
    setup context do
      {:ok, original} =
        post(context, [debit(context.cash, "40"), credit(context.income, "40")])

      %{original: original}
    end

    test "posts the mirror image once and links both entries", context do
      %{operator: operator, original: original, cash: cash, income: income} = context

      assert {:ok, reversal} = reverse(context, original.id, ~D[2026-10-05])
      assert reversal.reverses_entry_id == original.id

      assert [
               %{account_id: cash_id, debit: zero, credit: forty},
               %{account_id: income_id, debit: forty_again}
             ] = reversal.lines

      assert {cash_id, income_id} == {cash.id, income.id}
      assert Decimal.equal?(zero, 0) and Decimal.equal?(forty, 40)
      assert Decimal.equal?(forty_again, 40)

      assert {:ok, %{reversed_by_entry_id: reversed_by}} =
               Ledger.get_entry(operator, 73, original.id)

      assert reversed_by == reversal.id

      assert {:error, :already_reversed} = reverse(context, original.id, ~D[2026-10-05])
      assert {:error, :reversal_not_reversible} = reverse(context, reversal.id, ~D[2026-10-06])
    end

    test "refuses a date before the original's and an unknown entry", context do
      assert {:error, changeset} = reverse(context, context.original.id, ~D[2026-09-30])
      assert %{entry_date: ["cannot be before the reversed entry's date"]} = errors_on(changeset)

      assert {:error, :entry_not_found} =
               reverse(context, context.original.id + 1000, ~D[2026-10-05])
    end

    test "reverses into an account deactivated since", context do
      {:ok, _} = post(context, [debit(context.income, "40"), credit(context.cash, "40")])
      {:ok, _} = Ledger.update_account(context.operator, 73, context.income.id, %{active: false})

      assert {:ok, %{reverses_entry_id: id}} =
               reverse(context, context.original.id, ~D[2026-10-05])

      assert id == context.original.id
    end
  end

  describe "the database" do
    setup context do
      {:ok, original} =
        post(context, [debit(context.cash, "40"), credit(context.income, "40")])

      %{original: original}
    end

    test "refuses to change or delete a posted entry or its lines", %{original: original} do
      for {sql, params} <- [
            {"UPDATE finance_ledger_entries SET description = 'x' WHERE id = $1", [original.id]},
            {"DELETE FROM finance_ledger_entries WHERE id = $1", [original.id]},
            {"UPDATE finance_ledger_entry_lines SET debit = 41 WHERE entry_id = $1",
             [original.id]},
            {"DELETE FROM finance_ledger_entry_lines WHERE entry_id = $1", [original.id]}
          ] do
        # The savepoint keeps the test's own transaction usable afterwards.
        assert_raise Postgrex.Error, ~r/finance ledger keeps/, fn ->
          Repo.transaction(fn -> SQL.query!(Repo, sql, params) end)
        end
      end
    end

    test "refuses an entry whose lines do not balance", %{original: original} do
      SQL.query!(
        Repo,
        """
        INSERT INTO finance_ledger_entry_lines
          (tenant_id, company_id, entry_id, line_number, account_id, debit, credit)
        SELECT tenant_id, company_id, entry_id, 3, account_id, 1, 0
        FROM finance_ledger_entry_lines WHERE entry_id = $1 AND line_number = 1
        """,
        [original.id]
      )

      assert_raise Postgrex.Error,
                   ~r/does not balance/,
                   &TestFixtures.check_deferred_constraints!/0
    end

    test "refuses an entry without lines" do
      SQL.query!(
        Repo,
        """
        INSERT INTO finance_ledger_entries
          (tenant_id, company_id, entry_date, description, currency_code,
           posted_by_user_id, posted_at)
        VALUES (41, 73, '2026-10-01', 'Empty', 'XTS', 91, now())
        """,
        []
      )

      assert_raise Postgrex.Error, ~r/has no lines/, &TestFixtures.check_deferred_constraints!/0
    end

    test "refuses a line naming another company's account", context do
      sibling = TestFixtures.sign_in!(context.first_scope, 74, 93, [@manage])
      {:ok, foreign} = Ledger.create_account(sibling, 74, account("1000", "asset"))

      assert_raise Postgrex.Error, ~r/finance_ledger_entry_lines_account_fkey/, fn ->
        Repo.transaction(fn ->
          SQL.query!(
            Repo,
            """
            INSERT INTO finance_ledger_entry_lines
              (tenant_id, company_id, entry_id, line_number, account_id, debit, credit)
            VALUES (41, 73, $1, 9, $2, 1, 0)
            """,
            [context.original.id, foreign.id]
          )
        end)
      end
    end

    test "refuses an entry in another currency than the book's" do
      assert_raise Postgrex.Error, ~r/finance_ledger_entries_book_fkey/, fn ->
        Repo.transaction(fn ->
          SQL.query!(
            Repo,
            """
            INSERT INTO finance_ledger_entries
              (tenant_id, company_id, entry_date, description, currency_code,
               posted_by_user_id, posted_at)
            VALUES (41, 73, '2026-10-01', 'Other currency', 'XXX', 91, now())
            """,
            []
          )
        end)
      end
    end
  end

  defp post(context, lines), do: Ledger.post_entry(context.operator, 73, entry(lines))

  defp reverse(context, entry_id, date) do
    Ledger.reverse_entry(context.operator, 73, entry_id, %{
      entry_date: date,
      description: "Reversal"
    })
  end

  defp entry(lines),
    do: %{entry_date: ~D[2026-10-01], description: "Test entry", lines: lines}

  defp debit(account, amount), do: %{account_id: account.id, debit: amount}
  defp credit(account, amount), do: %{account_id: account.id, credit: amount}

  defp account(code, type), do: %{code: code, name: "Account #{code}", account_type: type}
end
