defmodule Bilimbi.Finance.Reports.EvidenceCompletenessTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Finance.{
    Attachments,
    Ledger,
    Receivables,
    Payables,
    Reconciliation,
    Einvoice,
    Payroll,
    Sst,
    FixedAssets
  }

  @owners [
    {:bilimbi_finance_ledger, Ledger.Evidence},
    {:bilimbi_finance_receivables, Receivables.Evidence},
    {:bilimbi_finance_payables, Payables.Evidence},
    {:bilimbi_finance_reconciliation, Reconciliation.Evidence},
    {:bilimbi_finance_einvoice, Einvoice.Evidence},
    {:bilimbi_finance_payroll, Payroll.Evidence},
    {:bilimbi_finance_sst, Sst.Evidence},
    {:bilimbi_finance_fixed_assets, FixedAssets.Evidence},
    {:bilimbi_finance_attachments, Attachments.Evidence}
  ]

  @excluded %{
    "finance_reports_issued" =>
      "the pack writes it itself as issued-reports.csv, with the stored snapshot content"
  }

  test "every table of every Finance module is exported by the pack or excluded with a reason" do
    for {app, evidence} <- @owners do
      assert Application.load(app) in [:ok, {:error, {:already_loaded, app}}]
      assert schema_tables(app) != [], "#{app} has no schema to check"
      assert evidence.tables() != [], "#{app} exports no table"
    end

    assert Application.load(:bilimbi_finance_reports) in [
             :ok,
             {:error, {:already_loaded, :bilimbi_finance_reports}}
           ]

    # The composition metadata includes modules outside Reports' dependency closure.
    # A newly installed Finance module must be covered, even before adding its edge.
    descriptor = Application.fetch_env!(:bilimbi_finance_reports, :bilimbi_module)
    finance_ids = Enum.filter(descriptor.graph_module_ids, &String.starts_with?(&1, "finance/"))

    covered_ids = [
      descriptor.id
      | Enum.map(@owners, fn {app, _} ->
          Application.fetch_env!(app, :bilimbi_module).id
        end)
    ]

    assert Enum.sort(finance_ids) == Enum.sort(covered_ids)

    exported = Enum.flat_map(@owners, fn {_app, evidence} -> evidence.tables() end)
    assert exported == Enum.uniq(exported)

    tables =
      [:bilimbi_finance_reports | Enum.map(@owners, &elem(&1, 0))]
      |> Enum.flat_map(&schema_tables/1)

    missing = Enum.sort(tables -- (exported ++ Map.keys(@excluded)))
    assert missing == [], "tables neither in the auditor pack nor excluded: #{inspect(missing)}"

    for {table, reason} <- @excluded do
      assert table in tables
      assert reason != ""
      refute table in exported
    end

    for table <- exported, do: assert(table in tables)
  end

  test "the pack reads every module that owns Finance tables" do
    assert Enum.sort(Bilimbi.Finance.Reports.AuditorPack.sources()) ==
             Enum.sort([
               Ledger,
               Receivables,
               Payables,
               Reconciliation,
               Einvoice,
               Payroll,
               Sst,
               FixedAssets,
               Attachments
             ])
  end

  defp schema_tables(app) do
    for module <- Application.spec(app, :modules),
        Code.ensure_loaded?(module),
        function_exported?(module, :__schema__, 1),
        source = module.__schema__(:source),
        do: source
  end
end
