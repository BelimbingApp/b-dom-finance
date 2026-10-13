defmodule Bilimbi.Finance.Reports.EvidenceCompletenessTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Finance.{Ledger, Receivables, Payables, Reconciliation, Einvoice}

  @owners [
    {:bilimbi_finance_ledger, Ledger.Evidence},
    {:bilimbi_finance_receivables, Receivables.Evidence},
    {:bilimbi_finance_payables, Payables.Evidence},
    {:bilimbi_finance_reconciliation, Reconciliation.Evidence},
    {:bilimbi_finance_einvoice, Einvoice.Evidence}
  ]

  @excluded %{
    "finance_reports_issued" =>
      "the pack writes it itself as issued-reports.csv, with the stored snapshot content"
  }

  test "every table of the Finance modules the pack covers is exported or excluded with a reason" do
    exported = Enum.flat_map(@owners, fn {_app, evidence} -> evidence.tables() end)

    tables =
      for app <- [:bilimbi_finance_reports | Keyword.keys(@owners)],
          :ok == ensure_loaded(app),
          module <- Application.spec(app, :modules),
          Code.ensure_loaded?(module),
          function_exported?(module, :__schema__, 1),
          source = module.__schema__(:source),
          do: source

    assert "finance_ledger_journal_events" in tables
    assert "finance_payables_payment_request_events" in tables

    missing = Enum.sort(tables -- (exported ++ Map.keys(@excluded)))
    assert missing == [], "tables neither in the auditor pack nor excluded: #{inspect(missing)}"

    for {table, reason} <- @excluded do
      assert table in tables
      assert reason != ""
      refute table in exported
    end

    assert exported == Enum.uniq(exported)
  end

  defp ensure_loaded(app) do
    case Application.load(app) do
      result when result in [:ok, {:error, {:already_loaded, ^app}}] -> :ok
      other -> other
    end
  end
end
