defmodule Bilimbi.Finance.Einvoice.PostingTest do
  # The contribution registry snapshot is process-global.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.{Posting, TestFixtures}
  alias Bilimbi.Finance.Ledger
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    context = TestFixtures.setup_einvoice!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    operator =
      TestFixtures.sign_in!(
        context.first_scope,
        73,
        91,
        TestFixtures.capabilities() ++ TestFixtures.ledger_capabilities()
      )

    :ok = TestFixtures.put_supplier_profile!(context.first_scope, 73)
    accounts = TestFixtures.open_posting_book!(operator, 73)
    Map.merge(context, %{operator: operator, accounts: accounts})
  end

  defp validated!(op, attributes, options \\ []) do
    {:ok, document} = Einvoice.issue_document(op, 73, attributes)
    :ok = TestFixtures.validate!(op, 73, document.id, options)
    {:ok, view} = Einvoice.get_document(op, 73, document.id)
    view
  end

  defp money(value), do: value |> Decimal.round(2) |> Decimal.to_string(:normal)

  defp amounts(entry, accounts) do
    by_id = Map.new(accounts, fn {role, account} -> {account.id, role} end)

    Enum.map(entry.lines, fn line ->
      {by_id[line.account_id], money(line.debit), money(line.credit)}
    end)
  end

  test "a validated invoice posts receivable against revenue and tax, referenced by number and UUID",
       %{operator: op, accounts: accounts} do
    document = validated!(op, TestFixtures.invoice_attributes())
    assert {:ok, entry} = Posting.post(op, 73, document)

    assert entry.entry_date == ~D[2026-10-01]
    assert entry.reference == "JSON-INV12345 F9D425P6DS7D8IU"
    assert entry.description == "E-invoice JSON-INV12345 (invoice)"

    assert amounts(entry, accounts) == [
             {:receivable_account, "180.20", "0.00"},
             {:revenue_account, "0.00", "170.00"},
             {:tax_account, "0.00", "10.20"}
           ]

    assert {:ok, %{ledger_entry_id: entry_id, attention: []}} =
             Einvoice.get_document(op, 73, document.id)

    assert entry_id == entry.id
    assert {:ok, ^entry} = Ledger.get_entry(op, 73, entry.id)
  end

  describe "a consolidated document" do
    setup %{operator: op, first_scope: scope} do
      :ok = TestFixtures.put_settings!(scope, 73, %{"document_version" => "1.0"})
      # Inside September's window, which opens when the month ends.
      Application.put_env(:bilimbi_finance_einvoice, :clock, fn -> ~U[2026-10-03 02:00:00Z] end)
      on_exit(fn -> Application.delete_env(:bilimbi_finance_einvoice, :clock) end)

      manager =
        TestFixtures.sign_in!(scope, 73, 92, [
          "finance.ledger.view",
          "finance.ledger.periods.manage"
        ])

      {:ok, years} = Ledger.list_fiscal_years(manager, 73)

      september =
        years |> Enum.flat_map(& &1.periods) |> Enum.find(&(&1.start_date == ~D[2026-09-01]))

      {:ok, _source} =
        Einvoice.issue_document(
          op,
          73,
          TestFixtures.invoice_attributes(%{issued_at: ~U[2026-09-02 04:00:00Z]})
        )

      {:ok, consolidated} =
        Einvoice.issue_consolidated_document(op, 73, %{
          month: "2026-09",
          code_number: "CON-2026-09"
        })

      :ok = TestFixtures.validate!(op, 73, consolidated.id)
      %{consolidated: consolidated, manager: manager, september: september}
    end

    test "posts into the month it reports, not the month it was issued", %{
      operator: op,
      consolidated: consolidated
    } do
      assert consolidated.issued_at == ~U[2026-10-03 02:00:00Z]
      assert {:ok, entry} = Posting.post(op, 73, consolidated)
      assert entry.entry_date == ~D[2026-09-30]
    end

    test "is refused, never reopening the period, once its month is closed", %{
      operator: op,
      consolidated: consolidated,
      manager: manager,
      september: september
    } do
      Bilimbi.Finance.Ledger.TestFixtures.close_periods_through!(manager, 73, ~D[2026-08-01])
      assert {:ok, %{status: "closed"}} = Ledger.close_period(manager, 73, september.id)

      assert {:error, message} = Posting.post(op, 73, consolidated)
      assert message =~ "falls in a closed period"
      assert {:ok, []} = Ledger.list_entries(op, 73)

      assert {:ok, %{ledger_entry_id: nil, attention: [:posting_failed], events: events}} =
               Einvoice.get_document(op, 73, consolidated.id)

      assert List.last(events).event == "posting_failed"
      assert {:error, ^message} = Posting.post(op, 73, consolidated)
    end
  end

  test "a document posts once, whatever view of it the caller holds", %{operator: op} do
    document = validated!(op, TestFixtures.invoice_attributes())
    assert {:ok, entry} = Posting.post(op, 73, document)
    assert :noop = Posting.post(op, 73, document)

    assert {:ok, %{ledger_entry_id: entry_id, events: events}} =
             Einvoice.get_document(op, 73, document.id)

    assert entry_id == entry.id
    assert Enum.count(events, &(&1.event == "posted")) == 1
  end

  test "posting again while another posting runs is a no-op, with one entry and one posted event",
       %{operator: op} do
    document = validated!(op, TestFixtures.invoice_attributes())
    owner = self()

    results =
      for _try <- 1..2 do
        Task.async(fn ->
          Sandbox.allow(Repo, owner, self())
          Posting.post(op, 73, document)
        end)
      end
      |> Task.await_many()

    assert [{:ok, _entry}, :noop] = Enum.sort_by(results, &(&1 == :noop))
    assert {:ok, [_only_entry]} = Ledger.list_entries(op, 73)

    assert {:ok, %{events: events}} = Einvoice.get_document(op, 73, document.id)
    assert Enum.count(events, &(&1.event == "posted")) == 1
  end

  test "a ledger refusal leaves no entry and no posted event, only the failure",
       %{operator: op, accounts: accounts} do
    document = validated!(op, TestFixtures.invoice_attributes())
    {:ok, _account} = Ledger.update_account(op, 73, accounts.revenue_account.id, %{active: false})

    assert {:error, message} = Posting.post(op, 73, document)
    assert message =~ ~r/^lines\[\d+\] account_id /
    assert {:ok, []} = Ledger.list_entries(op, 73)

    assert {:ok, %{ledger_entry_id: nil, events: events}} =
             Einvoice.get_document(op, 73, document.id)

    assert Enum.map(events, & &1.event) == ["issued", "submitted", "valid", "posting_failed"]
    assert List.last(events).reason == message

    {:ok, _account} = Ledger.update_account(op, 73, accounts.revenue_account.id, %{active: true})
    assert {:ok, entry} = Posting.post(op, 73, document)
    assert {:ok, [only_entry]} = Ledger.list_entries(op, 73)
    assert only_entry.id == entry.id

    assert {:ok, %{ledger_entry_id: entry_id}} = Einvoice.get_document(op, 73, document.id)
    assert entry_id == entry.id
  end

  test "a refused posting is recorded as one failure",
       %{operator: op} = context do
    document = validated!(op, TestFixtures.invoice_attributes())
    :ok = TestFixtures.put_settings!(context.first_scope, 73, %{"posting.tax_account" => "9999"})

    assert {:error, _reason} = Posting.post(op, 73, document)

    assert {:ok, %{events: events}} = Einvoice.get_document(op, 73, document.id)
    assert Enum.count(events, &(&1.event == "posting_failed")) == 1
  end

  describe "attempt/1" do
    defp counted(results) do
      {:ok, calls} = Agent.start_link(fn -> results end)

      fun = fn ->
        Agent.get_and_update(calls, fn [next | rest] -> {next, rest} end).()
      end

      {fun, calls}
    end

    test "tries a transient database failure once more" do
      {fun, calls} =
        counted([
          fn -> raise DBConnection.ConnectionError, "connection closed" end,
          fn -> {:ok, :posted} end
        ])

      assert {:ok, :posted} = Posting.attempt(fun)
      assert Agent.get(calls, & &1) == []
    end

    test "gives up after the second transient failure, recording one failure" do
      lock = %Postgrex.Error{
        postgres: %{
          severity: "ERROR",
          pg_code: "55P03",
          code: :lock_not_available,
          message: "could not obtain lock"
        }
      }

      {fun, _calls} =
        counted([fn -> raise lock end, fn -> raise lock end, fn -> flunk("third") end])

      assert {:error, {:transient, _message}} = Posting.attempt(fun)
    end

    test "never repeats a ledger refusal or a non-transient database error" do
      {fun, calls} = counted([fn -> {:error, :book_not_open} end, fn -> flunk("second") end])
      assert {:error, :book_not_open} = Posting.attempt(fun)
      assert length(Agent.get(calls, & &1)) == 1

      unique = %Postgrex.Error{
        postgres: %{
          code: :unique_violation,
          pg_code: "23505",
          severity: "ERROR",
          message: "duplicate"
        }
      }

      {fun, _calls} = counted([fn -> raise unique end, fn -> flunk("second") end])
      assert_raise Postgrex.Error, fn -> Posting.attempt(fun) end
    end

    test "classifies connection, timeout, and lock failures as transient only" do
      assert Posting.transient?(%DBConnection.ConnectionError{message: "timeout"})

      for code <- [:lock_not_available, :serialization_failure, :deadlock_detected] do
        assert Posting.transient?(%Postgrex.Error{postgres: %{code: code, message: "x"}})
      end

      refute Posting.transient?(%Postgrex.Error{postgres: %{code: :unique_violation}})

      refute Posting.transient?(%RuntimeError{
               message: "a ledger refusal is not a database failure"
             })
    end
  end

  test "a credit note posts the mirror image, a refund note credits the settlement account, and zero tax posts no tax line",
       %{operator: op, accounts: accounts} do
    original = validated!(op, TestFixtures.invoice_attributes())

    credit =
      validated!(
        op,
        TestFixtures.invoice_attributes(%{
          document_type: "02",
          code_number: "CN-1",
          original_document_id: original.id
        }),
        uuid: "NOTE000000000001"
      )

    assert {:ok, entry} = Posting.post(op, 73, credit)

    assert amounts(entry, accounts) == [
             {:receivable_account, "0.00", "180.20"},
             {:revenue_account, "170.00", "0.00"},
             {:tax_account, "10.20", "0.00"}
           ]

    refund =
      validated!(
        op,
        TestFixtures.invoice_attributes(%{
          document_type: "04",
          code_number: "RN-1",
          original_document_id: original.id,
          lines: [
            %{
              description: "Refund",
              classification_code: "022",
              quantity: "1",
              unit_price: "50",
              tax_type: "06",
              tax_rate: "0"
            }
          ]
        }),
        uuid: "NOTE000000000002"
      )

    assert {:ok, entry} = Posting.post(op, 73, refund)

    assert amounts(entry, accounts) == [
             {:settlement_account, "0.00", "50.00"},
             {:revenue_account, "50.00", "0.00"}
           ]
  end

  test "a posting that cannot happen is recorded with its reason and listed for reconciliation",
       %{operator: op} = context do
    document = validated!(op, TestFixtures.invoice_attributes())
    :ok = TestFixtures.put_settings!(context.first_scope, 73, %{"posting.tax_account" => "9999"})

    assert {:error, "accounts not in the chart: tax_account 9999"} =
             Posting.post(op, 73, document)

    assert {:ok, %{attention: [:posting_failed]}} = Einvoice.get_document(op, 73, document.id)

    assert {:ok, %{unposted: [row], unreversed: []}} = Einvoice.reconciliation(op, 73)
    assert row.id == document.id
    assert row.reason == "accounts not in the chart: tax_account 9999"

    # Without the ledger grant the posting is refused, and the reason says so.
    viewer = TestFixtures.sign_in!(context.first_scope, 73, 92, TestFixtures.capabilities())
    assert {:error, "the actor may not post to the ledger"} = Posting.post(viewer, 73, document)

    :ok = TestFixtures.put_settings!(context.first_scope, 73, %{"posting.tax_account" => "2200"})
    assert {:ok, _entry} = Posting.post(op, 73, document)
    assert {:ok, %{unposted: [], unreversed: []}} = Einvoice.reconciliation(op, 73)
  end

  test "reconciliation lists a cancelled document whose entry stands, until it is reversed", %{
    operator: op
  } do
    document = validated!(op, TestFixtures.invoice_attributes())
    {:ok, _entry} = Posting.post(op, 73, document)

    Bilimbi.Finance.Einvoice.Documents.record_event!(op, 73, document.id, %{
      event: "cancelled",
      authority_status: "Cancelled",
      reason: "portal"
    })

    assert {:ok, %{unposted: [], unreversed: [row]}} = Einvoice.reconciliation(op, 73)
    assert row.id == document.id and row.status == "cancelled" and is_integer(row.ledger_entry_id)
    assert {:ok, %{attention: [:unreversed]}} = Einvoice.get_document(op, 73, document.id)

    {:ok, view} = Einvoice.get_document(op, 73, document.id)
    assert {:ok, _reversal} = Posting.reverse(op, 73, view, DateTime.utc_now())

    assert :noop =
             Posting.reverse(
               op,
               73,
               elem(Einvoice.get_document(op, 73, document.id), 1),
               DateTime.utc_now()
             )

    assert {:ok, %{unposted: [], unreversed: []}} = Einvoice.reconciliation(op, 73)
    assert {:ok, %{attention: []}} = Einvoice.get_document(op, 73, document.id)
  end

  test "a rejected document keeps its entry and is not listed for reversal", %{operator: op} do
    document = validated!(op, TestFixtures.invoice_attributes())
    {:ok, _entry} = Posting.post(op, 73, document)

    Bilimbi.Finance.Einvoice.Documents.record_event!(op, 73, document.id, %{
      event: "rejected",
      authority_status: "Valid",
      reason: "Wrong quantity"
    })

    assert {:ok, %{unposted: [], unreversed: []}} = Einvoice.reconciliation(op, 73)

    assert {:ok, %{attention: [:rejection_requested]}} =
             Einvoice.get_document(op, 73, document.id)
  end

  test "a book in another currency refuses the posting", %{operator: op} = context do
    sibling =
      TestFixtures.sign_in!(
        context.first_scope,
        74,
        93,
        TestFixtures.capabilities() ++ TestFixtures.ledger_capabilities()
      )

    :ok = TestFixtures.put_supplier_profile!(context.first_scope, 74)
    {:ok, _book} = Ledger.open_book(sibling, 74, %{currency_code: "XTS", minor_units: 2})
    Bilimbi.Finance.Ledger.TestFixtures.open_fiscal_years!(sibling, 74)

    :ok =
      TestFixtures.put_settings!(sibling, 74, %{
        "posting.receivable_account" => "1",
        "posting.revenue_account" => "2",
        "posting.tax_account" => "3"
      })

    {:ok, document} = Einvoice.issue_document(sibling, 74, TestFixtures.invoice_attributes())
    :ok = TestFixtures.validate!(sibling, 74, document.id)
    {:ok, view} = Einvoice.get_document(sibling, 74, document.id)

    assert {:error, "the book is kept in XTS, the document in MYR"} =
             Posting.post(sibling, 74, view)

    _ = op
  end
end
