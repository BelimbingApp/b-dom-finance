defmodule Bilimbi.Finance.Ledger.PostingsTest do
  # The contribution registry snapshot is process-global, so this suite does
  # not run alongside other suites.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.Postings
  alias Bilimbi.Finance.Ledger.TestFixtures
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @view "finance.ledger.view"

  setup do
    context = TestFixtures.setup_ledger!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    context
  end

  # A sandboxed post never commits, so it never notifies; the migration's
  # trigger is proved in schema_contract_test.exs. These send the notice the
  # trigger sends, committed outside the sandbox, and prove who hears it.
  test "a subscriber hears its own company's postings only", %{first_scope: system} do
    viewer = TestFixtures.sign_in!(system, 73, 91, [@view])
    assert :ok = Ledger.subscribe_postings(viewer, 73)
    assert :ok = Ledger.subscribe_postings(viewer, 73)
    _ = :sys.get_state(Postings)

    for payload <- ["41:74:1", "42:73:1", "41:73:x", "41:73:12"], do: notify!(payload)

    assert_receive {:finance_ledger_posted, %{company_id: 73, entry_number: 12}}
    refute_received {:finance_ledger_posted, _}
  end

  test "subscribing needs the view grant on that company", %{first_scope: system} do
    clerk = TestFixtures.sign_in!(system, 73, 92, ["finance.ledger.entries.post"])
    assert {:error, :unauthorized} = Ledger.subscribe_postings(clerk, 73)

    viewer = TestFixtures.sign_in!(system, 73, 93, [@view])
    assert {:error, :unauthorized} = Ledger.subscribe_postings(viewer, 74)
    assert {:error, :company_not_found} = Ledger.subscribe_postings(viewer, 75)
    assert {:error, :unauthorized} = Ledger.subscribe_postings(system, 73)

    assert Registry.keys(Postings.registry(), self()) == []
  end

  defp notify!(payload) do
    Sandbox.unboxed_run(Repo, fn ->
      SQL.query!(Repo, "SELECT pg_notify($1, $2)", [Postings.channel(), payload])
    end)
  end
end
