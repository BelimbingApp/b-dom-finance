defmodule BilimbiWeb.EinvoiceConsolidationLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.TestFixtures

  @view "finance.einvoice.view"
  @issue "finance.einvoice.documents.issue"
  @submit "finance.einvoice.documents.submit"
  # Inside September 2026's window: the month ended at 2026-09-30T16:00Z
  # and the window closes seven days later.
  @now ~U[2026-10-03 02:00:00Z]

  setup do
    signed_in_identity!()
    Bilimbi.Base.Integration.TestFixtures.create_exchanges_table!()
    Bilimbi.Base.Artifacts.TestFixtures.create_artifacts_table!()
    Bilimbi.Finance.Ledger.TestFixtures.create_ledger_tables!()
    TestFixtures.create_einvoice_tables!()
    {:ok, scope} = Tenancy.scope(41)
    :ok = TestFixtures.put_supplier_profile!(scope, 73)
    :ok = TestFixtures.put_credentials!(scope, 73)
    # Another user issues the documents, so the signed-in user 91 holds only
    # what each test grants.
    issuer = TestFixtures.sign_in!(scope, 73, 92, TestFixtures.capabilities())
    on_exit(fn -> Application.delete_env(:bilimbi_finance_einvoice, :clock) end)
    %{issuer: issuer}
  end

  defp set_clock!(now),
    do: Application.put_env(:bilimbi_finance_einvoice, :clock, fn -> now end)

  defp source!(issuer, code_number, issued_at, price \\ "100.00") do
    {:ok, document} =
      Einvoice.issue_document(
        issuer,
        73,
        TestFixtures.invoice_attributes(%{
          code_number: code_number,
          issued_at: issued_at,
          lines: [
            %{
              description: "Item",
              classification_code: "022",
              quantity: "1",
              unit_price: price,
              tax_type: "01",
              tax_rate: "6"
            }
          ]
        })
      )

    document
  end

  test "needs the view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/finance/einvoice/consolidation")
  end

  test "shows a month's documents, those kept out, and its window", %{conn: conn, issuer: issuer} do
    grant_capabilities!([@view, @issue])
    small = source!(issuer, "R-001", ~U[2026-09-02 04:00:00Z])
    large = source!(issuer, "R-002", ~U[2026-09-03 04:00:00Z], "10000.00")

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/einvoice/consolidation?month=2026-09")

    assert has_element?(view, "#einvoice-candidate-#{small.id}", "R-001")
    refute has_element?(view, "#einvoice-candidate-#{large.id}")
    assert has_element?(view, "#einvoice-refused-#{large.id}", "needs an individual e-invoice")
    assert has_element?(view, "#einvoice-consolidation-facts", "106.00")

    # September's window closed on 7 October, so nothing can be issued for it.
    assert has_element?(view, "#einvoice-consolidation-closed")
    refute has_element?(view, "#einvoice-consolidation-issue")

    view
    |> form("#einvoice-consolidation-month", %{month: "2026-08"})
    |> render_change()

    assert %{"month" => "2026-08"} = patched_params(view)
    refute has_element?(view, "#einvoice-candidate-#{small.id}")

    assert has_element?(
             view,
             "#einvoice-consolidation-candidates-table-empty",
             "No document of this month"
           )
  end

  describe "issuing from the page" do
    setup %{issuer: issuer} do
      set_clock!(@now)
      %{first: source!(issuer, "R-001", ~U[2026-09-02 04:00:00Z])}
    end

    defp issue_form(view, code_number),
      do: form(view, "#einvoice-consolidation-issue", issue: %{code_number: code_number})

    defp issued_document!(issuer, result) do
      assert {:error, {:live_redirect, %{to: "/finance/einvoice/documents/" <> id}}} = result
      {:ok, document} = Einvoice.get_document(issuer, 73, String.to_integer(id))
      document
    end

    test "covers the documents the page shows, not ones recorded after it loaded",
         %{conn: conn, issuer: issuer, first: first} do
      grant_capabilities!([@view, @issue])

      {:ok, view, _html} =
        conn |> log_in_as() |> live(~p"/finance/einvoice/consolidation?month=2026-09")

      assert has_element?(view, "#einvoice-consolidation-open")
      later = source!(issuer, "R-002", ~U[2026-09-03 04:00:00Z])

      document = issuer |> issued_document!(view |> issue_form("CON-2026-09") |> render_submit())

      assert Enum.map(document.sources, & &1.id) == [first.id]
      assert {:ok, %{status: "issued"}} = Einvoice.get_document(issuer, 73, later.id)
    end

    test "refuses a shown document that has since been consolidated",
         %{conn: conn, issuer: issuer, first: first} do
      grant_capabilities!([@view, @issue])

      {:ok, view, _html} =
        conn |> log_in_as() |> live(~p"/finance/einvoice/consolidation?month=2026-09")

      {:ok, other} =
        Einvoice.issue_consolidated_document(issuer, 73, %{
          month: "2026-09",
          code_number: "CON-OTHER"
        })

      html = view |> issue_form("CON-2026-09") |> render_submit()

      assert html =~ "Document ##{first.id} can no longer be consolidated"

      assert {:ok, %{consolidated_by: %{id: holder}}} =
               Einvoice.get_document(issuer, 73, first.id)

      assert holder == other.id
      refute has_element?(view, "#einvoice-candidate-#{first.id}")
    end
  end

  test "a consolidated document lists what it covers, and a covered one names it",
       %{conn: conn, issuer: issuer} do
    grant_capabilities!([@view, @submit])
    source = source!(issuer, "R-001", ~U[2026-09-02 04:00:00Z])

    set_clock!(@now)

    {:ok, consolidated} =
      Einvoice.issue_consolidated_document(
        issuer,
        73,
        %{month: "2026-09", code_number: "CON-2026-09"}
      )

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/einvoice/documents/#{consolidated.id}")

    assert has_element?(view, "#einvoice-document-consolidated", "2026-09")
    assert has_element?(view, "#einvoice-source-#{source.id}", "R-001")
    assert has_element?(view, "#einvoice-document-buyer", "General Public")
    assert has_element?(view, "#einvoice-document-submit")

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/einvoice/documents/#{source.id}")

    assert has_element?(view, "#einvoice-document-consolidated-by-link", "CON-2026-09")
    refute has_element?(view, "#einvoice-document-submit")
  end

  test "a self-billed document shows the supplier as the counterparty",
       %{conn: conn, issuer: issuer} do
    grant_capabilities!(@view)
    {:ok, document} = Einvoice.issue_document(issuer, 73, TestFixtures.self_billed_attributes())

    {:ok, view, _html} =
      conn |> log_in_as() |> live(~p"/finance/einvoice/documents/#{document.id}")

    assert has_element?(view, "#einvoice-document-self-billed")
    assert has_element?(view, "#einvoice-document-supplier", "Foreign Supplier's Name")
    # The company's own profile is the buyer.
    assert has_element?(view, "#einvoice-document-buyer", "C29702635060")

    {:ok, list, _html} = conn |> log_in_as() |> live(~p"/finance/einvoice/documents")
    assert has_element?(list, "#einvoice-document-#{document.id}", "Foreign Supplier's Name")
    assert has_element?(list, "#einvoice-document-#{document.id}", "Self-billed invoice")
  end
end
