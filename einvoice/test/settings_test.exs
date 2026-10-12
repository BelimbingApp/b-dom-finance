defmodule Bilimbi.Finance.Einvoice.SettingsTest do
  # The contribution registry snapshot is process-global.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.Form
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.{Certificate, TestFixtures}

  setup do
    context = TestFixtures.setup_einvoice!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, TestFixtures.capabilities())

    Map.merge(context, %{
      operator: operator,
      settings: TestFixtures.settings_scope(context.first_scope, 73)
    })
  end

  describe "definitions" do
    test "are company settings on the e-invoice screen, secrets encrypted", %{settings: scope} do
      fields = Form.fields(["finance.einvoice"], scope)
      keys = Enum.map(fields, & &1.key)

      assert "finance.einvoice.environment" in keys
      assert "finance.einvoice.supplier.industry_code" in keys

      encrypted = for field <- fields, field.encrypted?, do: field.key

      assert Enum.sort(encrypted) == [
               "finance.einvoice.certificate_pem",
               "finance.einvoice.private_key_pem",
               "finance.einvoice.production.client_secret",
               "finance.einvoice.sandbox.client_secret"
             ]

      assert Enum.all?(fields, &(&1.definition.scopes == [:company]))
      assert Enum.all?(fields, &(&1.definition.capability == "finance.einvoice.settings.manage"))
    end

    test "a stored secret never reaches the screen", %{first_scope: scope, settings: settings} do
      :ok = TestFixtures.put_credentials!(scope, 73)

      field =
        Enum.find(
          Form.fields(["finance.einvoice"], settings),
          &(&1.key =~ "sandbox.client_secret")
        )

      assert field.value == Form.secret_mask()

      assert Settings.get("finance.einvoice.sandbox.client_secret", settings) ==
               "test-client-secret"
    end

    test "refuse malformed values", %{settings: scope} do
      for {key, value} <- [
            {"environment", "staging"},
            {"certificate_pem", "-----BEGIN CERTIFICATE-----\nnope\n-----END CERTIFICATE-----"},
            {"private_key_pem", TestFixtures.test_certificate!().certificate_pem},
            {"supplier.industry_code", "4651"},
            {"supplier.phone", "0123456789"},
            {"supplier.state_code", "Selangor"},
            {"supplier.tax_id", "123"},
            {"sandbox.secret_expires_on", "next year"}
          ] do
        assert {:error, %Ecto.Changeset{}} = Settings.put("finance.einvoice.#{key}", value, scope),
               "#{key} accepted #{inspect(value)}"
      end
    end

    test "supplier settings and buyer details follow the authority's rules" do
      authority = Einvoice.Configuration.authority()

      for {kind, field, valid, invalid} <- [
            {:tax_id, :valid_tax_id?, ["C29702635060", "IG12345678901"], ["123", "c29702635060"]},
            {:phone, :valid_phone?,
             ["+60123456789", "+12345678", "+" <> String.duplicate("1", 19)],
             ["0123456789", "+6012345", "+" <> String.duplicate("1", 20)]},
            {:industry_code, :valid_industry_code?, ["46510"], ["4651"]},
            {:state_code, :valid_state_code?, ["10"], ["Selangor"]},
            {:country_code, :valid_country_code?, ["MYS"], ["my"]}
          ] do
        for value <- valid do
          assert authority.valid_format?(kind, value), "#{kind} refused #{value}"
          assert apply(Einvoice.Configuration, field, [value])
        end

        for value <- invalid do
          refute authority.valid_format?(kind, value), "#{kind} accepted #{value}"
          refute apply(Einvoice.Configuration, field, [value])
        end

        definition = Einvoice.Configuration.definitions()["finance.einvoice.supplier.#{kind}"]
        assert {Einvoice.Configuration, ^field, message} = definition.validator
        assert message == authority.format_message(kind)
      end
    end

    test "the API URLs are platform settings with the SDK's hosts" do
      assert Settings.get("finance.einvoice.sandbox.api_url") ==
               "https://preprod-api.myinvois.hasil.gov.my"

      assert {:error, _} =
               Settings.put("finance.einvoice.production.api_url", "http://example.com/x")
    end
  end

  describe "certificate" do
    test "reads PEM, the subject's numbers, and whether a key belongs to it" do
      generated = TestFixtures.test_certificate!()
      assert {:ok, certificate} = Certificate.parse(generated.certificate_pem)

      assert certificate.issuer_name == "CN=Test Issuing CA, O=Test Certificate Authority, C=MY"

      assert certificate.subject == %{
               "organization_identifier" => "C29702635060",
               "serial_number" => "D12345678"
             }

      assert {:ok, key} = Certificate.private_key(generated.private_key_pem)
      assert Certificate.key_matches?(certificate, key)
      refute Certificate.key_matches?(certificate, TestFixtures.other_key!())

      pkcs8 = :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])
      assert {:ok, ^key} = Certificate.private_key(pkcs8)

      ec = :public_key.generate_key({:namedCurve, :secp256r1})
      ec_pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec)])
      assert {:error, :invalid_private_key} = Certificate.private_key(ec_pem)
    end

    test "quotes an issuer value the way .NET does" do
      generated = TestFixtures.test_certificate!()
      {:ok, certificate} = Certificate.parse(generated.certificate_pem)
      refute certificate.issuer_name =~ "\""
    end
  end

  describe "setup" do
    test "reports what is set without any secret", %{first_scope: scope, operator: op} do
      generated = TestFixtures.test_certificate!(not_after: ~U[2026-11-01 00:00:00Z])
      :ok = TestFixtures.put_supplier_profile!(scope, 73)
      :ok = TestFixtures.put_credentials!(scope, 73)

      :ok =
        TestFixtures.put_settings!(scope, 73, %{
          "certificate_pem" => generated.certificate_pem,
          "private_key_pem" => generated.private_key_pem,
          "sandbox.secret_expires_on" => "2027-06-30"
        })

      assert {:ok, setup} = Einvoice.setup(op, 73, ~U[2026-10-12 00:00:00Z])

      assert %{
               environment: "sandbox",
               client_id?: true,
               client_secret?: true,
               client_secret_expires_on: ~D[2027-06-30],
               expiry_alert_days: 30,
               expiring: [:certificate],
               supplier_missing: [],
               tax_id_matches_certificate?: true,
               certificate: %{
                 tax_id: "C29702635060",
                 days_until_expiry: 20,
                 private_key_matches?: true
               }
             } = setup

      refute inspect(setup) =~ ~r/test-client-secret|PRIVATE KEY|BEGIN CERTIFICATE/
    end

    test "names what is missing on a fresh company", %{operator: op} do
      assert {:ok,
              %{certificate: nil, client_id?: false, expiring: [], supplier_missing: missing}} =
               Einvoice.setup(op, 73)

      assert :tax_id in missing and :industry_code in missing
    end

    test "needs the settings capability", %{first_scope: scope} do
      viewer = TestFixtures.sign_in!(scope, 73, 92, ["finance.einvoice.view"])
      assert {:error, :unauthorized} = Einvoice.setup(viewer, 73)
    end
  end
end
