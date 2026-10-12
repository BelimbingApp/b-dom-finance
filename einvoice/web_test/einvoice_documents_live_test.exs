defmodule BilimbiWeb.EinvoiceDocumentsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.MyInvois.{Client, TokenCache}
  alias Bilimbi.Finance.Einvoice.TestFixtures

  @view "finance.einvoice.view"
  @submit "finance.einvoice.documents.submit"
  @cancel "finance.einvoice.documents.cancel"

  setup do
    signed_in_identity!()
    Bilimbi.Base.Integration.TestFixtures.create_exchanges_table!()
    Bilimbi.Base.Artifacts.TestFixtures.create_artifacts_table!()
    Bilimbi.Finance.Ledger.TestFixtures.create_ledger_tables!()
    TestFixtures.create_einvoice_tables!()
    Req.Test.set_req_test_to_shared()
    TokenCache.delete({73, "sandbox", "test-client-id"})
    on_exit(fn -> TokenCache.delete({73, "sandbox", "test-client-id"}) end)
    {:ok, scope} = Tenancy.scope(41)
    :ok = TestFixtures.put_supplier_profile!(scope, 73)
    :ok = TestFixtures.put_credentials!(scope, 73)
    :ok = TestFixtures.put_settings!(scope, 73, %{"document_version" => "1.0"})
    # Another user issues the documents, so the signed-in user 91 holds only
    # what each test grants.
    issuer = TestFixtures.sign_in!(scope, 73, 92, TestFixtures.capabilities())
    %{scope: scope, issuer: issuer}
  end

  defp issue!(issuer, code_number) do
    {:ok, document} =
      Einvoice.issue_document(
        issuer,
        73,
        TestFixtures.invoice_attributes(%{code_number: code_number})
      )

    document
  end

  describe "the list" do
    test "needs the view capability", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/dashboard"}}} =
               conn |> log_in_as() |> live(~p"/finance/einvoice/documents")
    end

    test "lists the company's documents newest first and filters by status", %{
      conn: conn,
      issuer: issuer
    } do
      grant_capabilities!(@view)
      first = issue!(issuer, "INV-1")
      second = issue!(issuer, "INV-2")
      :ok = TestFixtures.validate!(issuer, 73, second.id)

      {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/einvoice/documents")

      assert has_element?(view, "#einvoice-document-#{first.id}", "INV-1")
      assert has_element?(view, "#einvoice-document-#{second.id}", "valid")
      assert has_element?(view, "#einvoice-documents-pagination-summary")

      view
      |> form("#einvoice-documents-filters", filters: %{status: "valid"})
      |> render_change()

      assert %{"status" => "valid"} = patched_params(view)
      refute has_element?(view, "#einvoice-document-#{first.id}")
      assert has_element?(view, "#einvoice-document-#{second.id}")

      view
      |> form("#einvoice-documents-filters", filters: %{status: "", search: "nothing"})
      |> render_change()

      assert has_element?(view, "#einvoice-documents-table", "No documents match")
    end
  end

  describe "the document page" do
    test "shows the record, withholds the actions without the grants, and never a secret", %{
      conn: conn,
      issuer: issuer
    } do
      grant_capabilities!(@view)
      document = issue!(issuer, "INV-1")

      {:ok, view, html} =
        conn |> log_in_as() |> live(~p"/finance/einvoice/documents/#{document.id}")

      assert has_element?(view, "#einvoice-document-supplier", "TIN C29702635060")
      assert has_element?(view, "#einvoice-document-buyer", "Buyer's Name")
      assert has_element?(view, "#einvoice-line-1", "Laptop Peripherals")
      assert has_element?(view, "#einvoice-event-1", "issued")
      assert has_element?(view, "#einvoice-document-no-link")
      refute has_element?(view, "#einvoice-document-submit")
      refute has_element?(view, "#einvoice-document-open-cancel")
      refute html =~ "test-client-secret"

      {:ok, missing, _html} = conn |> log_in_as() |> live(~p"/finance/einvoice/documents/0")
      assert has_element?(missing, "#einvoice-document-missing")
    end

    test "submits as the signed-in user and shows the queued submission", %{
      conn: conn,
      issuer: issuer
    } do
      grant_capabilities!([@view, @submit])
      document = issue!(issuer, "INV-1")

      {:ok, view, _html} =
        conn |> log_in_as() |> live(~p"/finance/einvoice/documents/#{document.id}")

      view |> element("#einvoice-document-submit") |> render_click()
      assert has_element?(view, "#flash-success", "Submission queued")
      assert [job] = Bilimbi.Base.Repo.all(Oban.Job)
      assert job.args == %{"company_id" => 73, "document_id" => document.id}
    end

    test "shows the validation link with its QR code, refreshes, and cancels with a reason", %{
      conn: conn,
      issuer: issuer
    } do
      grant_capabilities!([@view, @submit, @cancel])
      document = issue!(issuer, "INV-1")
      :ok = TestFixtures.validate!(issuer, 73, document.id)

      Req.Test.stub(Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/connect/token"} ->
            TestFixtures.token_response(conn)

          {"GET", "/api/v1.0/documents/F9D425P6DS7D8IU/details"} ->
            TestFixtures.details_response(conn, "Valid")

          {"PUT", "/api/v1.0/documents/state/F9D425P6DS7D8IU/state"} ->
            Req.Test.json(conn, %{uuid: "F9D425P6DS7D8IU", status: "Cancelled"})
        end
      end)

      {:ok, view, html} =
        conn |> log_in_as() |> live(~p"/finance/einvoice/documents/#{document.id}")

      link = "https://preprod.myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/LIJAF97HJJKH"
      assert has_element?(view, "#einvoice-document-validation-link", link)
      assert html =~ "<svg"
      assert has_element?(view, "#einvoice-document-copy-link[data-copy-text='#{link}']")
      assert has_element?(view, "#einvoice-document-authority-facts", "F9D425P6DS7D8IU")

      render_hook(view, "link-copied", %{"text" => link, "copied" => true})
      assert has_element?(view, "#einvoice-document-copied")

      view |> element("#einvoice-document-refresh") |> render_click()
      assert has_element?(view, "#flash-info", "valid")
      assert has_element?(view, "#einvoice-event-4", "status_checked")

      view |> element("#einvoice-document-open-cancel") |> render_click()
      assert has_element?(view, "#einvoice-document-cancel-modal")

      view
      |> form("#einvoice-document-cancel-form", cancel: %{reason: "Wrong buyer"})
      |> render_submit()

      assert has_element?(view, "#flash-success", "cancelled")
      refute has_element?(view, "#einvoice-document-cancel-modal")
      assert has_element?(view, "#einvoice-event-5", "cancelled")
      refute has_element?(view, "#einvoice-document-open-cancel")
    end

    test "generates a PDF through Base Artifacts and serves it as a download", %{
      conn: conn,
      issuer: issuer
    } do
      grant_capabilities!(@view)
      TestFixtures.put_artifacts_root!()
      document = issue!(issuer, "INV-1")

      {:ok, view, _html} =
        conn |> log_in_as() |> live(~p"/finance/einvoice/documents/#{document.id}")

      view |> element("#einvoice-document-generate-pdf") |> render_click()
      assert has_element?(view, "#flash-success", "PDF generated")

      {:ok, %{pdf_artifact_id: artifact_id}} = Einvoice.get_document(issuer, 73, document.id)
      assert has_element?(view, "#einvoice-document-download-pdf")

      response =
        conn
        |> log_in_as()
        |> get(~p"/finance/einvoice/documents/#{document.id}/pdf/#{artifact_id}")

      assert response.status == 200
      assert ["application/pdf" <> _] = Plug.Conn.get_resp_header(response, "content-type")
      assert <<"%PDF-", _::binary>> = response.resp_body
      assert ["private, no-store"] = Plug.Conn.get_resp_header(response, "cache-control")

      missing =
        conn
        |> log_in_as()
        |> get(~p"/finance/einvoice/documents/#{document.id}/pdf/#{Ecto.UUID.generate()}")

      assert missing.status == 404
    end
  end

  describe "reconciliation" do
    test "lists validated documents without a ledger entry", %{conn: conn, issuer: issuer} do
      grant_capabilities!(@view)
      document = issue!(issuer, "INV-1")
      :ok = TestFixtures.validate!(issuer, 73, document.id)

      {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/einvoice/reconciliation")
      assert has_element?(view, "#einvoice-unposted-#{document.id}", "INV-1")
      assert has_element?(view, "#einvoice-unreversed-table-empty", "has been reversed")
    end
  end
end
