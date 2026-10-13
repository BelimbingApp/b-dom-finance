defmodule Bilimbi.Finance.Einvoice.TestFixtures do
  @moduledoc """
  E-invoicing tables, settings, code lists, authorization, two tenants'
  companies, and generated certificates for module tests.

  The tables are temporary copies of the migration's, constraints and
  triggers included, so a test that makes PostgreSQL refuse proves the
  migration's rule. The first migration's are a copy: keep them in step
  with `priv/repo/migrations/`; the consolidation and source links
  migrations' are their own SQL (`statements(temporary: true)`).
  `test/schema_contract_test.exs` checks the real migrations themselves.

  Party data is the authority's SDK sample data ("Supplier's Name", the
  SDK's dummy TIN, the general-public buyer TIN), never a real taxpayer.
  """

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.ContributionValidator, as: AuthzValidator
  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Settings.ContributionValidator, as: SettingsValidator
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Finance.Einvoice.Contributions
  alias Bilimbi.Finance.Einvoice.Documents
  alias Bilimbi.Finance.Einvoice.MyInvois.Client
  alias Bilimbi.Finance.Ledger
  alias Ecto.Adapters.SQL

  @view "finance.einvoice.view"
  @issue "finance.einvoice.documents.issue"
  @submit "finance.einvoice.documents.submit"
  @cancel "finance.einvoice.documents.cancel"
  @settings "finance.einvoice.settings.manage"

  @ledger_capabilities [
    "finance.ledger.view",
    "finance.ledger.accounts.manage",
    "finance.ledger.entries.post"
  ]

  @doc "Every capability the module declares."
  def capabilities, do: [@view, @issue, @submit, @cancel, @settings]

  @doc "The ledger capabilities a user needs for the posting bridge."
  def ledger_capabilities, do: @ledger_capabilities

  @doc """
  Tenant 41 with companies 73 and 74, and tenant 42 with company 75, the
  e-invoicing, ledger, artifacts, settings, audit, exchange and Authz
  tables, and a contribution snapshot with the module's capabilities and
  settings. Returns the two tenants' system scopes.
  """
  def setup_einvoice! do
    CompanyFixtures.create_company_identity_tables!()
    AuthzFixtures.create_authz_tables!()
    Bilimbi.Base.Settings.TestFixtures.create_settings_table!()
    Bilimbi.Base.Audit.TestFixtures.create_audit_tables!()
    Bilimbi.Base.Integration.TestFixtures.create_exchanges_table!()
    Bilimbi.Base.Artifacts.TestFixtures.create_artifacts_table!()
    Ledger.TestFixtures.create_ledger_tables!()
    create_einvoice_tables!()
    install_contributions!()

    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})

    CompanyFixtures.insert_company!(%{
      id: 73,
      tenant_id: 41,
      code: "first_company",
      name: "Supplier's Name"
    })

    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "sibling_company"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "other_tenant_company"})

    {:ok, first} = Tenancy.scope(41)
    {:ok, second} = Tenancy.scope(42)
    %{first_scope: first, second_scope: second}
  end

  @doc "A contribution snapshot with the platform's, the ledger's, and this module's Authz and Settings."
  def install_contributions! do
    providers = [
      {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
      {"base/artifacts", :bilimbi_base_artifacts, Bilimbi.Base.Artifacts.Contributions},
      {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
      {"finance/ledger", :bilimbi_finance_ledger, Ledger.Contributions},
      {"finance/einvoice", :bilimbi_finance_einvoice, Contributions}
    ]

    entries = fn key ->
      for {id, app, provider} <- providers,
          payload = Map.get(provider.contributions(), key),
          payload != nil,
          do: %{descriptor: %{id: id, otp_app: app}, payload: payload}
    end

    ContributionRegistry.put_consumers_for_test!(
      %{
        authz: AuthzValidator.validate_contributions!(entries.(:authz)),
        settings: SettingsValidator.validate_contributions!(entries.(:settings))
      },
      "finance-einvoice-test"
    )
  end

  @doc """
  A scope signed in as the user, after granting the capabilities directly
  in the company. Tests are the only module code that calls the edge.
  """
  def sign_in!(%Scope{} = scope, company_id, user_id, capabilities) do
    for capability <- capabilities do
      {:ok, :stored} =
        Authz.put_principal_capability(scope, company_id, :user, user_id, capability, true)
    end

    Authentication.sign_in(scope, user_id, company_id)
  end

  @doc "The company's settings scope."
  def settings_scope(%Scope{} = scope, company_id),
    do: Settings.Scope.company(company_id, Scope.tenant_id(scope))

  @doc "Stores each `{key suffix, value}` as the company's `finance.einvoice.*` setting."
  def put_settings!(%Scope{} = scope, company_id, values) do
    for {key, value} <- values do
      {:ok, _} = Settings.put("finance.einvoice.#{key}", value, settings_scope(scope, company_id))
    end

    :ok
  end

  @doc "A complete supplier profile from the SDK's sample values."
  def put_supplier_profile!(%Scope{} = scope, company_id) do
    put_settings!(scope, company_id, %{
      "supplier.tax_id" => "C29702635060",
      "supplier.registration_number" => "D12345678",
      "supplier.industry_code" => "46510",
      "supplier.business_activity" => "Wholesale of computer hardware, software and peripherals",
      "supplier.phone" => "+60123456789",
      "supplier.email" => "supplier@email.com",
      "supplier.address_line1" => "Lot 66",
      "supplier.address_line2" => "Bangunan Merdeka",
      "supplier.address_line3" => "Persiaran Jaya",
      "supplier.city" => "Kuala Lumpur",
      "supplier.postcode" => "50480",
      "supplier.state_code" => "10",
      "supplier.country_code" => "MYS"
    })
  end

  @doc "Sandbox credentials that are obviously not real."
  def put_credentials!(%Scope{} = scope, company_id) do
    put_settings!(scope, company_id, %{
      "sandbox.client_id" => "test-client-id",
      "sandbox.client_secret" => "test-client-secret"
    })
  end

  @doc """
  Opens the company's ringgit book as `operator`, adds the four accounts
  the posting bridge names, and stores their codes as the posting
  settings. Returns the accounts by role.
  """
  def open_posting_book!(%Scope{} = operator, company_id) do
    {:ok, _book} = Ledger.open_book(operator, company_id, %{currency_code: "MYR", minor_units: 2})

    accounts =
      Map.new(
        [
          receivable_account: {"1100", "Trade receivables", "asset"},
          settlement_account: {"1000", "Bank", "asset"},
          tax_account: {"2200", "Tax payable", "liability"},
          revenue_account: {"4000", "Sales", "income"}
        ],
        fn {role, {code, name, type}} ->
          {:ok, account} =
            Ledger.create_account(operator, company_id, %{
              code: code,
              name: name,
              account_type: type
            })

          {role, account}
        end
      )

    :ok =
      put_settings!(
        operator,
        company_id,
        Map.new(accounts, fn {role, account} -> {"posting.#{role}", account.code} end)
      )

    accounts
  end

  @doc """
  Points Base Artifacts at a fresh private directory for this test, with a
  retention period, so a PDF can be stored.
  """
  def put_artifacts_root! do
    root = Path.join(System.tmp_dir!(), "einvoice-pdf-" <> Ecto.UUID.generate())
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _} = Settings.put("artifacts.storage_root", root)
    {:ok, _} = Settings.put("artifacts.retention_days", 30)
    root
  end

  @doc """
  Records the events a submission and validation would have, without the
  authority: `submitted` with the UIDs, then `valid` with the long ID and
  a validation instant, as the given scope's actor.
  """
  def validate!(%Scope{} = scope, company_id, document_id, options \\ []) do
    uuid = Keyword.get(options, :uuid, "F9D425P6DS7D8IU")
    long_id = Keyword.get(options, :long_id, "LIJAF97HJJKH")
    validated_at = Keyword.get(options, :validated_at, DateTime.utc_now())

    Documents.record_event!(scope, company_id, document_id, %{
      event: "submitted",
      authority_status: "Submitted",
      submission_uid: Keyword.get(options, :submission_uid, "HJSD135P2S7D8IU"),
      document_uuid: uuid,
      http_status: 202,
      response: %{"submissionUid" => "HJSD135P2S7D8IU"}
    })

    Documents.record_event!(scope, company_id, document_id, %{
      event: "valid",
      authority_status: "Valid",
      document_uuid: uuid,
      long_id: long_id,
      http_status: 200,
      response: %{
        "uuid" => uuid,
        "longId" => long_id,
        "status" => "Valid",
        "dateTimeValidated" => DateTime.to_iso8601(validated_at)
      }
    })

    :ok
  end

  @doc """
  Answers like the authority: `responses` maps `{method, path}` to a
  function of the conn, and every request is sent to the test process as
  `{:request, method, path, decoded_body}`. An unlisted path answers 404.
  """
  def stub_authority!(responses) do
    test = self()

    Req.Test.stub(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = if body == "", do: nil, else: decode_body(body)
      send(test, {:request, conn.method, conn.request_path, decoded})

      case Map.fetch(responses, {conn.method, conn.request_path}) do
        {:ok, respond} -> respond.(conn)
        :error -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)
  end

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  @doc "The token answer every stubbed authority call starts with."
  def token_response(conn),
    do: Req.Test.json(conn, %{access_token: "stub-token", expires_in: 3600, token_type: "Bearer"})

  @doc "A 202 that accepts the document with these identifiers."
  def accepted_response(
        conn,
        code_number,
        uuid \\ "F9D425P6DS7D8IU",
        submission_uid \\ "HJSD135P2S7D8IU"
      ) do
    conn
    |> Plug.Conn.put_status(202)
    |> Req.Test.json(%{
      submissionUid: submission_uid,
      acceptedDocuments: [%{uuid: uuid, invoiceCodeNumber: code_number}],
      rejectedDocuments: []
    })
  end

  @doc "A submission status answer with this overall status."
  def progress_response(conn, overall, document_status \\ "Valid") do
    Req.Test.json(conn, %{
      submissionUid: "HJSD135P2S7D8IU",
      overallStatus: overall,
      documentCount: 1,
      documentSummary: [%{uuid: "F9D425P6DS7D8IU", status: document_status}]
    })
  end

  @doc "A document details answer with this status and the extra fields."
  def details_response(conn, status, extra \\ %{}) do
    Req.Test.json(
      conn,
      Map.merge(
        %{
          uuid: "F9D425P6DS7D8IU",
          submissionUid: "HJSD135P2S7D8IU",
          longId: "LIJAF97HJJKH",
          status: status,
          dateTimeValidated: "2026-10-01T01:00:00Z"
        },
        extra
      )
    )
  end

  @doc """
  An invoice's attributes in the SDK sample's terms: one line of 10 units at
  17.00 with 6% tax, to the general-public buyer.
  """
  def invoice_attributes(overrides \\ %{}) do
    Map.merge(
      %{
        document_type: "01",
        code_number: "JSON-INV12345",
        issued_at: ~U[2026-10-01 00:30:00Z],
        currency_code: "MYR",
        buyer: %{
          name: "Buyer's Name",
          tax_id: "EI00000000010",
          registration_type: "BRN",
          registration_number: "NA",
          email: "buyer@email.com",
          phone: "+60123456789",
          address: %{
            lines: ["Lot 66", "Bangunan Merdeka", "Persiaran Jaya"],
            city: "Kuala Lumpur",
            postcode: "50480",
            state_code: "10",
            country_code: "MYS"
          }
        },
        lines: [
          %{
            description: "Laptop Peripherals",
            classification_code: "003",
            quantity: "10",
            unit_code: "C62",
            unit_price: "17.00",
            tax_type: "01",
            tax_rate: "6"
          }
        ]
      },
      overrides
    )
  end

  @doc """
  A self-billed invoice's attributes: one line of 2 units at 50.00 with no
  tax, from a foreign supplier without a Malaysian TIN (the authority's
  general foreign-supplier TIN and placeholder details).
  """
  def self_billed_attributes(overrides \\ %{}) do
    Map.merge(
      %{
        document_type: "11",
        code_number: "SB-0001",
        issued_at: ~U[2026-10-01 00:30:00Z],
        currency_code: "MYR",
        supplier: %{
          name: "Foreign Supplier's Name",
          tax_id: "EI00000000030",
          registration_type: "BRN",
          registration_number: "NA",
          email: "supplier@example.com",
          phone: "+14155550100",
          industry_code: "00000",
          business_activity: "NOT APPLICABLE",
          address: %{
            lines: ["1 Example Street"],
            city: "Example City",
            postcode: "94000",
            state_code: "17",
            country_code: "USA"
          }
        },
        lines: [
          %{
            description: "Software subscription",
            classification_code: "022",
            quantity: "2",
            unit_code: "C62",
            unit_price: "50.00",
            tax_type: "06",
            tax_rate: "0"
          }
        ]
      },
      overrides
    )
  end

  @doc """
  Adds the payable, expense, and purchase tax accounts a self-billed
  document posts to, to a book `open_posting_book!/2` opened, and stores
  their codes. Returns them by role.
  """
  def add_purchase_accounts!(%Scope{} = operator, company_id) do
    accounts =
      Map.new(
        [
          payable_account: {"2100", "Trade payables", "liability"},
          expense_account: {"5000", "Purchases", "expense"},
          purchase_tax_account: {"5100", "Purchase tax", "expense"}
        ],
        fn {role, {code, name, type}} ->
          {:ok, account} =
            Ledger.create_account(operator, company_id, %{
              code: code,
              name: name,
              account_type: type
            })

          {role, account}
        end
      )

    :ok =
      put_settings!(
        operator,
        company_id,
        Map.new(accounts, fn {role, account} -> {"posting.#{role}", account.code} end)
      )

    accounts
  end

  ## Certificates

  @doc """
  A self-signed RSA certificate and its key, generated once per test run:
  `%{certificate_pem, private_key_pem, key}`. The subject carries the SDK's
  dummy TIN and registration number the way an authority-issued
  certificate does. `not_after` sets the expiry.
  """
  def test_certificate!(options \\ []) do
    not_after = Keyword.get(options, :not_after, ~U[2036-01-01 00:00:00Z])
    key = test_key!()
    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = key
    sha256_rsa = {1, 2, 840, 113_549, 1, 1, 11}

    issuer =
      name([
        {{2, 5, 4, 6}, ~c"MY"},
        {{2, 5, 4, 10}, {:utf8String, "Test Certificate Authority"}},
        {{2, 5, 4, 3}, {:utf8String, "Test Issuing CA"}}
      ])

    subject =
      name([
        {{2, 5, 4, 6}, ~c"MY"},
        {{2, 5, 4, 10}, {:utf8String, "Supplier's Name"}},
        {{2, 5, 4, 97}, {:asn1_OPENTYPE, <<0x0C, 12, "C29702635060">>}},
        {{2, 5, 4, 3}, {:utf8String, "Supplier's Name"}},
        {{2, 5, 4, 5}, ~c"D12345678"}
      ])

    tbs =
      {:OTPTBSCertificate, :v3, 162_880_276_254_639_189_035_871_514_749_820_882_117,
       {:SignatureAlgorithm, sha256_rsa, {:asn1_OPENTYPE, <<5, 0>>}}, issuer,
       {:Validity, {:generalTime, ~c"20260101000000Z"}, {:generalTime, general_time(not_after)}},
       subject,
       {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, {1, 2, 840, 113_549, 1, 1, 1}, :NULL},
        {:RSAPublicKey, modulus, exponent}}, :asn1_NOVALUE, :asn1_NOVALUE, :asn1_NOVALUE}

    der = :public_key.pkix_sign(tbs, key)

    %{
      certificate_pem: :public_key.pem_encode([{:Certificate, der, :not_encrypted}]),
      private_key_pem:
        :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)]),
      key: key
    }
  end

  @doc "A second RSA key, for a certificate it does not belong to."
  def other_key! do
    cached(:other_key, fn -> :public_key.generate_key({:rsa, 2048, 65_537}) end)
  end

  defp test_key!, do: cached(:key, fn -> :public_key.generate_key({:rsa, 2048, 65_537}) end)

  defp cached(name, fun) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        value = fun.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  defp name(attributes) do
    {:rdnSequence,
     Enum.map(attributes, fn {oid, value} -> [{:AttributeTypeAndValue, oid, value}] end)}
  end

  defp general_time(%DateTime{} = time),
    do: time |> Calendar.strftime("%Y%m%d%H%M%SZ") |> String.to_charlist()

  ## Tables

  @doc "Makes PostgreSQL run the deferred totals check now."
  def check_deferred_constraints! do
    SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
  end

  def create_einvoice_tables! do
    Enum.each(statements(), &SQL.query!(Repo, &1, []))

    # The migrations are loaded at run time, so the calls are dynamic.
    for module <- [consolidation_migration(), source_links_migration()],
        statement <- apply(module, :statements, [[temporary: true]]) do
      SQL.query!(Repo, statement, [])
    end
  end

  @migrations_path Path.expand("../../priv/repo/migrations", __DIR__)

  @consolidation_migration "20261013221500_add_finance_einvoice_consolidation.exs"
  @source_links_migration "20261015150400_add_finance_einvoice_source_links.exs"

  @doc "The consolidation migration's module, loaded from its file once."
  def consolidation_migration,
    do:
      load_migration(
        Bilimbi.Finance.Einvoice.Migrations.AddConsolidation,
        @consolidation_migration
      )

  @doc "The source links migration's module, loaded from its file once."
  def source_links_migration,
    do:
      load_migration(Bilimbi.Finance.Einvoice.Migrations.AddSourceLinks, @source_links_migration)

  defp load_migration(module, file) do
    unless Code.ensure_loaded?(module),
      do: Code.require_file(Path.join(@migrations_path, file))

    module
  end

  @records [
    "finance_einvoice_documents",
    "finance_einvoice_document_lines",
    "finance_einvoice_submissions",
    "finance_einvoice_status_events"
  ]

  @actor_columns """
  actor_type varchar(16) NOT NULL, actor_user_id bigint, actor_impersonator_id bigint,
  system_principal varchar(100)
  """

  @actor_check """
  ((actor_type = 'user' AND actor_user_id IS NOT NULL AND system_principal IS NULL)
   OR (actor_type = 'system' AND actor_user_id IS NULL AND actor_impersonator_id IS NULL
       AND system_principal IS NOT NULL))
  """

  defp statements do
    [
      """
      CREATE TEMPORARY TABLE finance_einvoice_documents (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        authority varchar(32) NOT NULL, environment varchar(16) NOT NULL,
        document_type varchar(8) NOT NULL, code_number varchar(50) NOT NULL,
        issued_at timestamp(0) NOT NULL, currency_code varchar(3) NOT NULL,
        exchange_rate numeric(20, 6), supplier jsonb NOT NULL, buyer jsonb NOT NULL,
        details jsonb NOT NULL DEFAULT '{}', original_document_id bigint,
        line_extension_amount numeric(20, 2) NOT NULL, tax_exclusive_amount numeric(20, 2) NOT NULL,
        tax_amount numeric(20, 2) NOT NULL, tax_inclusive_amount numeric(20, 2) NOT NULL,
        payable_amount numeric(20, 2) NOT NULL, issued_by_user_id bigint NOT NULL,
        issued_by_impersonator_id bigint, recorded_at timestamp(6) NOT NULL,
        CONSTRAINT finance_einvoice_documents_environment
          CHECK (environment IN ('sandbox', 'production')),
        CONSTRAINT finance_einvoice_documents_currency_code CHECK (currency_code ~ '^[A-Z]{3}$'),
        CONSTRAINT finance_einvoice_documents_exchange_rate
          CHECK (exchange_rate IS NULL OR exchange_rate > 0),
        CONSTRAINT finance_einvoice_documents_not_own_original
          CHECK (original_document_id IS NULL OR original_document_id <> id),
        CONSTRAINT finance_einvoice_documents_totals CHECK (
          line_extension_amount >= 0 AND tax_amount >= 0
          AND tax_exclusive_amount = line_extension_amount
          AND tax_inclusive_amount = tax_exclusive_amount + tax_amount
          AND payable_amount = tax_inclusive_amount)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_einvoice_documents_id_company_unique
        ON finance_einvoice_documents (id, company_id)
      """,
      """
      ALTER TABLE finance_einvoice_documents ADD CONSTRAINT finance_einvoice_documents_original_fkey
        FOREIGN KEY (original_document_id, company_id)
        REFERENCES finance_einvoice_documents (id, company_id) ON DELETE RESTRICT
      """,
      """
      CREATE UNIQUE INDEX finance_einvoice_documents_code_number_unique
        ON finance_einvoice_documents (company_id, environment, code_number)
      """,
      """
      CREATE TEMPORARY TABLE finance_einvoice_document_lines (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        document_id bigint NOT NULL, line_number integer NOT NULL,
        description varchar(300) NOT NULL, classification_code varchar(16) NOT NULL,
        tariff_code varchar(32), origin_country_code varchar(3),
        quantity numeric(20, 6) NOT NULL, unit_code varchar(16), unit_price numeric(20, 6) NOT NULL,
        subtotal numeric(20, 2) NOT NULL, discount_amount numeric(20, 2) NOT NULL DEFAULT 0,
        charge_amount numeric(20, 2) NOT NULL DEFAULT 0,
        line_extension_amount numeric(20, 2) NOT NULL, tax_type varchar(8) NOT NULL,
        tax_rate numeric(9, 4), tax_amount numeric(20, 2) NOT NULL,
        tax_exemption_reason varchar(300),
        CONSTRAINT finance_einvoice_document_lines_document_fkey FOREIGN KEY (document_id, company_id)
          REFERENCES finance_einvoice_documents (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_einvoice_document_lines_line_number CHECK (line_number > 0),
        CONSTRAINT finance_einvoice_document_lines_amounts CHECK (
          quantity > 0 AND unit_price >= 0 AND subtotal >= 0
          AND discount_amount >= 0 AND charge_amount >= 0 AND tax_amount >= 0
          AND line_extension_amount >= 0
          AND line_extension_amount = subtotal - discount_amount + charge_amount),
        CONSTRAINT finance_einvoice_document_lines_tax_rate
          CHECK (tax_rate IS NULL OR (tax_rate >= 0 AND tax_rate <= 100))
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_einvoice_document_lines_document_line_unique
        ON finance_einvoice_document_lines (document_id, line_number)
      """,
      """
      CREATE TEMPORARY TABLE finance_einvoice_submissions (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        document_id bigint NOT NULL, environment varchar(16) NOT NULL, format varchar(8) NOT NULL,
        document_version varchar(8) NOT NULL, payload bytea NOT NULL,
        payload_sha256 varchar(64) NOT NULL, #{@actor_columns},
        recorded_at timestamp(6) NOT NULL,
        CONSTRAINT finance_einvoice_submissions_document_fkey FOREIGN KEY (document_id, company_id)
          REFERENCES finance_einvoice_documents (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_einvoice_submissions_environment
          CHECK (environment IN ('sandbox', 'production')),
        CONSTRAINT finance_einvoice_submissions_format CHECK (format IN ('JSON', 'XML')),
        CONSTRAINT finance_einvoice_submissions_payload_sha256
          CHECK (octet_length(payload) > 0 AND payload_sha256 = encode(sha256(payload), 'hex')),
        CONSTRAINT finance_einvoice_submissions_actor CHECK #{@actor_check}
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_einvoice_submissions_id_company_unique
        ON finance_einvoice_submissions (id, company_id)
      """,
      """
      CREATE TEMPORARY TABLE finance_einvoice_status_events (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        document_id bigint NOT NULL, sequence integer NOT NULL, submission_id bigint,
        event varchar(32) NOT NULL, authority_status varchar(32), submission_uid varchar(64),
        document_uuid varchar(64), long_id varchar(128), reason varchar(300),
        http_status integer, response jsonb, ledger_entry_id bigint, #{@actor_columns},
        recorded_at timestamp(6) NOT NULL,
        CONSTRAINT finance_einvoice_status_events_document_fkey FOREIGN KEY (document_id, company_id)
          REFERENCES finance_einvoice_documents (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_einvoice_status_events_submission_fkey
          FOREIGN KEY (submission_id, company_id)
          REFERENCES finance_einvoice_submissions (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_einvoice_status_events_event CHECK (event ~ '^[a-z][a-z_]*$'),
        CONSTRAINT finance_einvoice_status_events_http_status
          CHECK (http_status IS NULL OR (http_status >= 100 AND http_status <= 599)),
        CONSTRAINT finance_einvoice_status_events_ledger_entry_id
          CHECK (ledger_entry_id IS NULL OR ledger_entry_id > 0),
        CONSTRAINT finance_einvoice_status_events_actor CHECK #{@actor_check}
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_einvoice_status_events_document_sequence_unique
        ON finance_einvoice_status_events (document_id, sequence)
      """,
      """
      CREATE UNIQUE INDEX finance_einvoice_status_events_posted_unique
        ON finance_einvoice_status_events (document_id) WHERE event = 'posted'
      """,
      """
      CREATE UNIQUE INDEX finance_einvoice_status_events_reversed_unique
        ON finance_einvoice_status_events (document_id) WHERE event = 'posting_reversed'
      """,
      """
      CREATE TEMPORARY TABLE finance_einvoice_code_overrides (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        authority varchar(32) NOT NULL, list varchar(32) NOT NULL, code varchar(16) NOT NULL,
        description varchar(500), active boolean NOT NULL DEFAULT true,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_einvoice_code_overrides_unique
        ON finance_einvoice_code_overrides (company_id, authority, list, code)
      """,
      """
      CREATE FUNCTION pg_temp.finance_einvoice_refuse_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'finance e-invoicing keeps % rows: % is refused; record a new status event',
          TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_einvoice_stamp_recorded_at() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        NEW.recorded_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_einvoice_number_status_event() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        NEW.sequence := COALESCE(
          (SELECT max(sequence) FROM finance_einvoice_status_events
           WHERE document_id = NEW.document_id), 0) + 1;
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_einvoice_refuse_recorded_line() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM finance_einvoice_documents
          WHERE id = NEW.document_id
            AND pg_xact_status(
                  ((pg_current_xact_id()::text::bigint >> 32 << 32) | xmin::text::bigint)::text::xid8
                ) IS DISTINCT FROM 'in progress'
        ) THEN
          RAISE EXCEPTION 'document % is already recorded: a line cannot be added; issue a note',
            NEW.document_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_einvoice_check_totals() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        checked_id bigint;
        document finance_einvoice_documents%ROWTYPE;
      BEGIN
        IF TG_TABLE_NAME = 'finance_einvoice_documents' THEN
          checked_id := NEW.id;
        ELSE
          checked_id := NEW.document_id;
        END IF;

        SELECT * INTO document FROM finance_einvoice_documents WHERE id = checked_id;

        IF NOT EXISTS (
          SELECT 1 FROM finance_einvoice_document_lines WHERE document_id = checked_id
        ) THEN
          RAISE EXCEPTION 'document % has no lines', checked_id
            USING ERRCODE = 'check_violation';
        END IF;

        IF (SELECT sum(line_extension_amount) FROM finance_einvoice_document_lines
            WHERE document_id = checked_id) <> document.line_extension_amount
          OR (SELECT sum(tax_amount) FROM finance_einvoice_document_lines
              WHERE document_id = checked_id) <> document.tax_amount THEN
          RAISE EXCEPTION 'document % totals differ from its lines', checked_id
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NULL;
      END
      $$
      """,
      """
      CREATE TRIGGER finance_einvoice_status_events_number
        BEFORE INSERT ON finance_einvoice_status_events
        FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_einvoice_number_status_event()
      """,
      """
      CREATE TRIGGER finance_einvoice_document_lines_recorded_document
        BEFORE INSERT ON finance_einvoice_document_lines
        FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_einvoice_refuse_recorded_line()
      """
    ] ++
      Enum.flat_map(@records, fn table ->
        [
          "CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table} " <>
            "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_einvoice_refuse_change()",
          "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} " <>
            "FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.finance_einvoice_refuse_change()"
        ]
      end) ++
      for(
        table <- [
          "finance_einvoice_documents",
          "finance_einvoice_submissions",
          "finance_einvoice_status_events"
        ],
        do:
          "CREATE TRIGGER #{table}_recorded_at BEFORE INSERT ON #{table} " <>
            "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_einvoice_stamp_recorded_at()"
      ) ++
      for table <- ["finance_einvoice_documents", "finance_einvoice_document_lines"] do
        "CREATE CONSTRAINT TRIGGER #{table}_match_lines AFTER INSERT ON #{table} " <>
          "DEFERRABLE INITIALLY DEFERRED " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_einvoice_check_totals()"
      end
  end
end
