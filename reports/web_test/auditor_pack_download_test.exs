defmodule BilimbiWeb.FinanceAuditorPackDownloadTest do
  use BilimbiWeb.ConnCase, async: false
  alias Bilimbi.Base.{Artifacts, Settings, Tenancy}
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Reports.ArtifactOwner

  setup do
    signed_in_identity!()
    Code.ensure_loaded!(Artifacts.TestFixtures)
    Artifacts.TestFixtures.create_artifacts_table!()
    root = Path.join(System.tmp_dir!(), "finance-web-artifacts-#{Ecto.UUID.generate()}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _} = Settings.put("artifacts.storage_root", root)
    {:ok, _} = Settings.put("artifacts.retention_days", 30)
    {:ok, system} = Tenancy.scope(41)

    operator =
      LedgerFixtures.sign_in!(
        system,
        73,
        91,
        ~w(finance.reports.reports-export finance.ledger.view finance.receivables.view finance.payables.view finance.reconciliation.view finance.einvoice.view finance.payroll.view finance.sst.view finance.fixed-assets.view finance.attachments.view)
      )

    %{operator: operator, system: system}
  end

  test "downloads authorized bytes privately and refuses revoked source access", context do
    {:ok, {_name, bytes}} = :zip.create(~c"pack.zip", [{~c"evidence.csv", "safe"}], [:memory])

    {:ok, artifact} =
      Artifacts.put(
        context.operator,
        73,
        ArtifactOwner,
        %{subject: Ecto.UUID.generate(), kind: "auditor-pack"},
        bytes,
        "application/zip"
      )

    conn = context.conn |> log_in_as() |> get(~p"/finance/reports/auditor-packs/#{artifact.id}")
    assert response(conn, 200) == bytes
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert hd(get_resp_header(conn, "content-disposition")) =~ "attachment; filename="

    LedgerFixtures.revoke!(context.system, 73, 91, "finance.payables.view")
    denied = context.conn |> log_in_as() |> get(~p"/finance/reports/auditor-packs/#{artifact.id}")
    assert response(denied, 404) == "Not found"
  end
end
