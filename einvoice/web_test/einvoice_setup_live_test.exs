defmodule BilimbiWeb.EinvoiceSetupLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Einvoice.MyInvois.{Client, TokenCache}
  alias Bilimbi.Finance.Einvoice.TestFixtures

  @settings "finance.einvoice.settings.manage"

  setup do
    signed_in_identity!()
    Bilimbi.Base.Integration.TestFixtures.create_exchanges_table!()
    Req.Test.set_req_test_to_shared()
    TokenCache.delete({73, "sandbox", "test-client-id"})
    on_exit(fn -> TokenCache.delete({73, "sandbox", "test-client-id"}) end)
    {:ok, scope} = Tenancy.scope(41)
    %{scope: scope}
  end

  test "needs the settings capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/finance/einvoice/setup")
  end

  test "says what a fresh company still lacks", %{conn: conn} do
    grant_capabilities!(@settings)
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/einvoice/setup")

    assert has_element?(view, "#einvoice-connection-facts", "Not set")
    assert has_element?(view, "#einvoice-certificate-missing")
    assert has_element?(view, "#einvoice-supplier-incomplete", "supplier TIN")
    refute has_element?(view, "#einvoice-expiry-alert")
  end

  test "shows the certificate and its expiry, and never a secret", %{conn: conn, scope: scope} do
    grant_capabilities!(@settings)

    generated =
      TestFixtures.test_certificate!(not_after: DateTime.add(DateTime.utc_now(), 10 * 86_400))

    :ok = TestFixtures.put_supplier_profile!(scope, 73)
    :ok = TestFixtures.put_credentials!(scope, 73)

    :ok =
      TestFixtures.put_settings!(scope, 73, %{
        "certificate_pem" => generated.certificate_pem,
        "private_key_pem" => generated.private_key_pem
      })

    {:ok, view, html} = conn |> log_in_as() |> live(~p"/finance/einvoice/setup")

    assert has_element?(view, "#einvoice-certificate-facts", "C29702635060")
    assert has_element?(view, "#einvoice-certificate-facts", "Matches the certificate")
    assert has_element?(view, "#einvoice-expiry-alert", "The certificate")
    assert has_element?(view, "#einvoice-supplier-complete")
    refute html =~ "test-client-secret"
    refute html =~ "PRIVATE KEY"
  end

  test "tests the connection and reports the outcome", %{conn: conn, scope: scope} do
    grant_capabilities!(@settings)
    :ok = TestFixtures.put_credentials!(scope, 73)
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/einvoice/setup")

    Req.Test.stub(Client, &Req.Test.json(&1, %{access_token: "stub-token", expires_in: 3600}))
    view |> element("#einvoice-test-connection") |> render_click()
    assert render(view) =~ "Connected: the authority accepted the sandbox credentials."

    Req.Test.stub(Client, &(&1 |> Plug.Conn.put_status(401) |> Req.Test.json(%{})))
    view |> element("#einvoice-test-connection") |> render_click()
    assert render(view) =~ "The authority refused the login (HTTP 401)."
  end
end
