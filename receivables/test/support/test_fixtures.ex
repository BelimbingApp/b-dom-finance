defmodule Bilimbi.Finance.Receivables.TestFixtures do
  @moduledoc """
  Receivables and ledger tables, authorization, two tenants' companies, and
  an open book with a small chart for module tests.

  The receivables tables are temporary copies of the migration's,
  constraints and triggers included, so a test that makes PostgreSQL refuse
  proves the migration's rule. Keep them in step with
  `priv/repo/migrations/`; `test/schema_contract_test.exs` checks the real
  migration itself. The ledger's tables come from its own fixtures.
  """

  alias Bilimbi.Base.Authz
  alias Bilimbi.Base.Authz.ContributionValidator
  alias Bilimbi.Base.Authz.TestFixtures, as: AuthzFixtures
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Authentication
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company.TestFixtures, as: CompanyFixtures
  alias Bilimbi.Finance.Ledger
  alias Bilimbi.Finance.Ledger.TestFixtures, as: LedgerFixtures
  alias Bilimbi.Finance.Receivables
  alias Ecto.Adapters.SQL

  @ledger ["finance.ledger.view", "finance.ledger.accounts.manage", "finance.ledger.entries.post"]

  @doc "Every ledger capability, which receivables' own calls into the ledger need."
  def ledger_capabilities, do: @ledger

  @doc "Every receivables capability."
  def receivables_capabilities do
    [
      Receivables.view_capability(),
      Receivables.manage_setup_capability(),
      Receivables.manage_customers_capability(),
      Receivables.manage_documents_capability(),
      Receivables.issue_documents_capability(),
      Receivables.post_payments_capability()
    ]
  end

  @doc """
  Tenant 41 with companies 73 and 74, and tenant 42 with company 75, the
  tables, and an Authz snapshot. Signs in user 91 at company 73 with every
  ledger and receivables capability, opens company 73's book in `XTS` with
  two minor units, and creates its chart: cash (1000), receivable (1100),
  tax payable (2100), equity (3000), and two income accounts (4000, 4100).
  Returns the scopes and the accounts.
  """
  def setup_receivables! do
    CompanyFixtures.create_company_identity_tables!()
    AuthzFixtures.create_authz_tables!()
    LedgerFixtures.create_ledger_tables!()
    create_receivables_tables!()
    install_authz!()

    CompanyFixtures.insert_tenant!(%{id: 41, name: "First tenant"})
    CompanyFixtures.insert_tenant!(%{id: 42, name: "Second tenant", is_platform_operator: false})
    CompanyFixtures.insert_company!(%{id: 73, tenant_id: 41, code: "first_company"})
    CompanyFixtures.insert_company!(%{id: 74, tenant_id: 41, code: "sibling_company"})
    CompanyFixtures.insert_company!(%{id: 75, tenant_id: 42, code: "other_tenant_company"})

    {:ok, first} = Tenancy.scope(41)
    {:ok, second} = Tenancy.scope(42)
    operator = sign_in!(first, 73, 91, @ledger ++ receivables_capabilities())

    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})

    accounts =
      Map.new(
        [
          cash: {"1000", "asset"},
          receivable: {"1100", "asset"},
          tax: {"2100", "liability"},
          equity: {"3000", "equity"},
          income: {"4000", "income"},
          other_income: {"4100", "income"}
        ],
        fn {key, {code, type}} ->
          {:ok, account} =
            Ledger.create_account(operator, 73, %{
              code: code,
              name: "Account #{code}",
              account_type: type
            })

          {key, account}
        end
      )

    %{first_scope: first, second_scope: second, operator: operator, accounts: accounts}
  end

  @doc """
  Configures company 73 with the fixture accounts, an invoice, credit note,
  and payment series, a 10% and a 6% tax code, and two customers. Returns
  them merged into `context`.
  """
  def configure_receivables!(%{operator: operator, accounts: accounts} = context) do
    {:ok, _setup} =
      Receivables.configure(operator, 73, %{
        receivable_account_id: accounts.receivable.id,
        income_account_id: accounts.income.id
      })

    series =
      for {key, code, kind, prefix} <- [
            {:invoice_series, "INV", "invoice", "INV-"},
            {:credit_series, "CN", "credit_note", "CN-"},
            {:payment_series, "RCP", "payment", "RCP-"}
          ],
          into: %{} do
        {:ok, series} =
          Receivables.create_series(operator, 73, %{
            code: code,
            name: "#{kind} series",
            kind: kind,
            prefix: prefix,
            number_width: 4
          })

        {key, series}
      end

    {:ok, standard} =
      Receivables.create_tax_code(operator, 73, %{
        code: "T10",
        name: "Ten percent",
        rate: "10",
        account_id: accounts.tax.id
      })

    {:ok, reduced} =
      Receivables.create_tax_code(operator, 73, %{
        code: "T6",
        name: "Six percent",
        rate: "6",
        account_id: accounts.tax.id
      })

    {:ok, customer} =
      Receivables.create_customer(operator, 73, %{
        code: "C001",
        name: "Example Customer",
        tax_identifier: "TAX-0001",
        line1: "1 Example Road",
        locality: "Example Town",
        country_iso: "XX",
        payment_terms_days: 30
      })

    {:ok, other_customer} =
      Receivables.create_customer(operator, 73, %{code: "C002", name: "Second Customer"})

    context
    |> Map.merge(series)
    |> Map.merge(%{
      standard_tax: standard,
      reduced_tax: reduced,
      customer: customer,
      other_customer: other_customer
    })
  end

  @doc "An Authz snapshot over the platform's, the ledger's, and receivables' capabilities."
  def install_authz! do
    entries =
      for {id, app, provider} <- [
            {"base/authz", :bilimbi_base_authz, Bilimbi.Base.Authz.Contributions},
            {"core/company", :bilimbi_core_company, Bilimbi.Core.Company.Contributions},
            {"finance/ledger", :bilimbi_finance_ledger, Ledger.Contributions},
            {"finance/receivables", :bilimbi_finance_receivables, Receivables.Contributions}
          ],
          do: %{descriptor: %{id: id, otp_app: app}, payload: provider.contributions().authz}

    ContributionRegistry.put_consumers_for_test!(
      %{authz: ContributionValidator.validate_contributions!(entries)},
      "finance-receivables-test"
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

  @doc "Makes PostgreSQL run the deferred ledger and payment checks now."
  def check_deferred_constraints! do
    SQL.query!(Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
  end

  def create_receivables_tables! do
    Enum.each(statements(), &SQL.query!(Repo, &1, []))
  end

  @tables [
    "finance_receivables_setups",
    "finance_receivables_setup_changes",
    "finance_receivables_series",
    "finance_receivables_tax_codes",
    "finance_receivables_customers",
    "finance_receivables_documents",
    "finance_receivables_document_lines",
    "finance_receivables_document_tax_lines",
    "finance_receivables_payments",
    "finance_receivables_allocations",
    "finance_receivables_payment_reversals"
  ]

  defp statements do
    tables() ++ functions() ++ triggers()
  end

  defp tables do
    [
      """
      CREATE TEMPORARY TABLE finance_receivables_setups (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        receivable_account_id bigint NOT NULL, income_account_id bigint NOT NULL,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_setups_company_unique
        ON finance_receivables_setups (company_id)
      """,
      """
      CREATE TEMPORARY TABLE finance_receivables_setup_changes (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        field varchar(32) NOT NULL, old_value bigint, new_value bigint NOT NULL,
        changed_by_user_id bigint NOT NULL, changed_by_impersonator_id bigint,
        changed_at timestamp(6) NOT NULL,
        CONSTRAINT finance_receivables_setup_changes_field
          CHECK (field IN ('receivable_account_id', 'income_account_id'))
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE TEMPORARY TABLE finance_receivables_series (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        code varchar(50) NOT NULL, name varchar(200) NOT NULL, kind varchar(16) NOT NULL,
        prefix varchar(20) NOT NULL, number_width smallint NOT NULL,
        active boolean NOT NULL DEFAULT true,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT finance_receivables_series_kind
          CHECK (kind IN ('invoice', 'credit_note', 'payment')),
        CONSTRAINT finance_receivables_series_number_width CHECK (number_width BETWEEN 1 AND 12)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_series_id_company_unique
        ON finance_receivables_series (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_series_id_company_kind_unique
        ON finance_receivables_series (id, company_id, kind)
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_series_company_code_unique
        ON finance_receivables_series (company_id, code)
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_series_company_prefix_unique
        ON finance_receivables_series (company_id, prefix)
      """,
      """
      CREATE TEMPORARY TABLE finance_receivables_tax_codes (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        code varchar(50) NOT NULL, name varchar(200) NOT NULL, rate numeric(9, 4) NOT NULL,
        account_id bigint NOT NULL, active boolean NOT NULL DEFAULT true,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT finance_receivables_tax_codes_rate CHECK (rate >= 0 AND rate < 1000)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_tax_codes_id_company_unique
        ON finance_receivables_tax_codes (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_tax_codes_company_code_unique
        ON finance_receivables_tax_codes (company_id, code)
      """,
      """
      CREATE TEMPORARY TABLE finance_receivables_customers (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        code varchar(50) NOT NULL, name varchar(200) NOT NULL,
        tax_identifier varchar(50), registration_identifier varchar(50),
        email varchar(255), phone varchar(50),
        line1 varchar(255), line2 varchar(255), line3 varchar(255),
        locality varchar(100), postcode varchar(20), admin1_code varchar(20),
        country_iso varchar(2), payment_terms_days integer NOT NULL DEFAULT 0,
        active boolean NOT NULL DEFAULT true,
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT finance_receivables_customers_country_iso CHECK (country_iso ~ '^[A-Z]{2}$'),
        CONSTRAINT finance_receivables_customers_payment_terms_days
          CHECK (payment_terms_days BETWEEN 0 AND 3650)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_customers_id_company_unique
        ON finance_receivables_customers (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_customers_company_code_unique
        ON finance_receivables_customers (company_id, code)
      """,
      """
      CREATE TEMPORARY TABLE finance_receivables_documents (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        kind varchar(16) NOT NULL, status varchar(16) NOT NULL,
        series_id bigint NOT NULL, customer_id bigint NOT NULL, credited_document_id bigint,
        receivable_account_id bigint,
        currency_code varchar(3) NOT NULL, issue_date date, due_date date,
        description varchar(500),
        subtotal numeric(20, 4) NOT NULL, tax_total numeric(20, 4) NOT NULL,
        total numeric(20, 4) NOT NULL,
        document_number bigint, document_reference varchar(50),
        party_name varchar(200), party_tax_identifier varchar(50),
        party_registration_identifier varchar(50), party_email varchar(255),
        party_phone varchar(50), party_line1 varchar(255), party_line2 varchar(255),
        party_line3 varchar(255), party_locality varchar(100), party_postcode varchar(20),
        party_admin1_code varchar(20), party_country_iso varchar(2),
        ledger_entry_id bigint, ledger_entry_number bigint,
        issued_by_user_id bigint, issued_by_impersonator_id bigint, issued_at timestamp(6),
        discarded_by_user_id bigint, discarded_at timestamp(6),
        inserted_at timestamp(0) NOT NULL, updated_at timestamp(0) NOT NULL,
        CONSTRAINT finance_receivables_documents_series_fkey
          FOREIGN KEY (series_id, company_id, kind)
          REFERENCES finance_receivables_series (id, company_id, kind) ON DELETE RESTRICT,
        CONSTRAINT finance_receivables_documents_customer_fkey FOREIGN KEY (customer_id, company_id)
          REFERENCES finance_receivables_customers (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_receivables_documents_kind CHECK (kind IN ('invoice', 'credit_note')),
        CONSTRAINT finance_receivables_documents_status
          CHECK (status IN ('draft', 'issued', 'discarded')),
        CONSTRAINT finance_receivables_documents_credited
          CHECK ((kind = 'credit_note') = (credited_document_id IS NOT NULL)),
        CONSTRAINT finance_receivables_documents_amounts
          CHECK (subtotal >= 0 AND tax_total >= 0 AND total = subtotal + tax_total),
        CONSTRAINT finance_receivables_documents_due_date
          CHECK (due_date IS NULL OR due_date >= issue_date),
        CONSTRAINT finance_receivables_documents_issued CHECK (
          (status = 'issued') = (document_number IS NOT NULL)
          AND (status <> 'issued' OR (
            document_number > 0 AND document_reference IS NOT NULL
            AND issue_date IS NOT NULL AND (kind <> 'invoice' OR due_date IS NOT NULL)
            AND total > 0 AND party_name IS NOT NULL AND receivable_account_id IS NOT NULL
            AND ledger_entry_id IS NOT NULL AND ledger_entry_number IS NOT NULL
            AND issued_by_user_id IS NOT NULL AND issued_at IS NOT NULL))),
        CONSTRAINT finance_receivables_documents_discarded CHECK (
          (status = 'discarded') = (discarded_at IS NOT NULL)
          AND (status <> 'discarded' OR discarded_by_user_id IS NOT NULL))
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_documents_id_company_unique
        ON finance_receivables_documents (id, company_id)
      """,
      """
      ALTER TABLE finance_receivables_documents
        ADD CONSTRAINT finance_receivables_documents_credited_fkey
        FOREIGN KEY (credited_document_id, company_id)
        REFERENCES finance_receivables_documents (id, company_id) ON DELETE RESTRICT
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_documents_series_number_unique
        ON finance_receivables_documents (series_id, document_number)
        WHERE document_number IS NOT NULL
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_documents_company_reference_unique
        ON finance_receivables_documents (company_id, document_reference)
        WHERE document_reference IS NOT NULL
      """,
      """
      CREATE TEMPORARY TABLE finance_receivables_document_lines (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        document_id bigint NOT NULL, line_number integer NOT NULL,
        description varchar(500) NOT NULL, quantity numeric(20, 4) NOT NULL,
        unit_price numeric(20, 4) NOT NULL, amount numeric(20, 4) NOT NULL,
        account_id bigint NOT NULL, tax_code_id bigint, tax_rate numeric(9, 4),
        tax_amount numeric(20, 4) NOT NULL,
        CONSTRAINT finance_receivables_document_lines_document_fkey
          FOREIGN KEY (document_id, company_id)
          REFERENCES finance_receivables_documents (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_receivables_document_lines_tax_code_fkey
          FOREIGN KEY (tax_code_id, company_id)
          REFERENCES finance_receivables_tax_codes (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_receivables_document_lines_line_number CHECK (line_number > 0),
        CONSTRAINT finance_receivables_document_lines_amounts
          CHECK (quantity > 0 AND unit_price >= 0 AND amount >= 0 AND tax_amount >= 0),
        CONSTRAINT finance_receivables_document_lines_tax
          CHECK ((tax_code_id IS NULL) = (tax_rate IS NULL)
            AND (tax_code_id IS NOT NULL OR tax_amount = 0))
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_document_lines_document_line_unique
        ON finance_receivables_document_lines (document_id, line_number)
      """,
      """
      CREATE TEMPORARY TABLE finance_receivables_document_tax_lines (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        document_id bigint NOT NULL, tax_code_id bigint NOT NULL,
        tax_code varchar(50) NOT NULL, tax_rate numeric(9, 4) NOT NULL,
        taxable_amount numeric(20, 4) NOT NULL, tax_amount numeric(20, 4) NOT NULL,
        account_id bigint NOT NULL,
        CONSTRAINT finance_receivables_document_tax_lines_document_fkey
          FOREIGN KEY (document_id, company_id)
          REFERENCES finance_receivables_documents (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_receivables_document_tax_lines_tax_code_fkey
          FOREIGN KEY (tax_code_id, company_id)
          REFERENCES finance_receivables_tax_codes (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_receivables_document_tax_lines_amounts
          CHECK (taxable_amount >= 0 AND tax_amount >= 0)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_document_tax_lines_document_tax_code_unique
        ON finance_receivables_document_tax_lines (document_id, tax_code_id)
      """,
      """
      CREATE TEMPORARY TABLE finance_receivables_payments (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        series_id bigint NOT NULL, customer_id bigint NOT NULL,
        payment_number bigint NOT NULL, payment_reference varchar(50) NOT NULL,
        payment_date date NOT NULL, amount numeric(20, 4) NOT NULL,
        currency_code varchar(3) NOT NULL, deposit_account_id bigint NOT NULL,
        reference varchar(100), description varchar(500),
        ledger_entry_id bigint NOT NULL, ledger_entry_number bigint NOT NULL,
        recorded_by_user_id bigint NOT NULL, recorded_by_impersonator_id bigint,
        recorded_at timestamp(6) NOT NULL,
        CONSTRAINT finance_receivables_payments_series_fkey FOREIGN KEY (series_id, company_id)
          REFERENCES finance_receivables_series (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_receivables_payments_customer_fkey FOREIGN KEY (customer_id, company_id)
          REFERENCES finance_receivables_customers (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_receivables_payments_amount CHECK (amount > 0 AND payment_number > 0)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_payments_id_company_unique
        ON finance_receivables_payments (id, company_id)
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_payments_series_number_unique
        ON finance_receivables_payments (series_id, payment_number)
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_payments_company_reference_unique
        ON finance_receivables_payments (company_id, payment_reference)
      """,
      """
      CREATE TEMPORARY TABLE finance_receivables_allocations (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        payment_id bigint NOT NULL, document_id bigint NOT NULL, amount numeric(20, 4) NOT NULL,
        CONSTRAINT finance_receivables_allocations_payment_fkey FOREIGN KEY (payment_id, company_id)
          REFERENCES finance_receivables_payments (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_receivables_allocations_document_fkey
          FOREIGN KEY (document_id, company_id)
          REFERENCES finance_receivables_documents (id, company_id) ON DELETE RESTRICT,
        CONSTRAINT finance_receivables_allocations_amount CHECK (amount > 0)
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_allocations_payment_document_unique
        ON finance_receivables_allocations (payment_id, document_id)
      """,
      """
      CREATE TEMPORARY TABLE finance_receivables_payment_reversals (
        id bigserial PRIMARY KEY, tenant_id bigint NOT NULL, company_id bigint NOT NULL,
        payment_id bigint NOT NULL, reversal_date date NOT NULL, reason varchar(500) NOT NULL,
        ledger_entry_id bigint NOT NULL, ledger_entry_number bigint NOT NULL,
        reversed_by_user_id bigint NOT NULL, reversed_by_impersonator_id bigint,
        reversed_at timestamp(6) NOT NULL,
        CONSTRAINT finance_receivables_payment_reversals_payment_fkey
          FOREIGN KEY (payment_id, company_id)
          REFERENCES finance_receivables_payments (id, company_id) ON DELETE RESTRICT
      ) ON COMMIT PRESERVE ROWS
      """,
      """
      CREATE UNIQUE INDEX finance_receivables_payment_reversals_payment_unique
        ON finance_receivables_payment_reversals (payment_id)
      """
    ]
  end

  # The migration's functions, in pg_temp; a pg_temp function is only found
  # by its qualified name.
  defp functions do
    [
      """
      CREATE FUNCTION pg_temp.finance_receivables_refuse_change() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'finance receivables keeps % rows: % is refused',
          TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'restrict_violation';
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_receivables_keep_identity() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        kept text;
      BEGIN
        FOREACH kept IN ARRAY TG_ARGV LOOP
          IF to_jsonb(NEW) -> kept IS DISTINCT FROM to_jsonb(OLD) -> kept THEN
            RAISE EXCEPTION 'finance receivables keeps % of % rows', kept, TG_TABLE_NAME
              USING ERRCODE = 'restrict_violation';
          END IF;
        END LOOP;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_receivables_outstanding(invoice_id bigint) RETURNS numeric
      LANGUAGE sql STABLE AS $$
        SELECT d.total
          - COALESCE((SELECT sum(c.total) FROM finance_receivables_documents c
                      WHERE c.credited_document_id = d.id AND c.status = 'issued'), 0)
          - COALESCE((SELECT sum(a.amount) FROM finance_receivables_allocations a
                      WHERE a.document_id = d.id
                        AND NOT EXISTS (SELECT 1 FROM finance_receivables_payment_reversals r
                                        WHERE r.payment_id = a.payment_id)), 0)
        FROM finance_receivables_documents d
        WHERE d.id = invoice_id
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_receivables_guard_document() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        credited finance_receivables_documents%ROWTYPE;
      BEGIN
        IF OLD.status <> 'draft' THEN
          RAISE EXCEPTION 'finance receivables document % is %: it is never changed; issue a credit note',
            OLD.id, OLD.status
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF NEW.tenant_id <> OLD.tenant_id OR NEW.company_id <> OLD.company_id
          OR NEW.kind <> OLD.kind THEN
          RAISE EXCEPTION 'a finance receivables document keeps its company and kind'
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF NEW.status = 'discarded' THEN
          NEW.discarded_at := clock_timestamp() AT TIME ZONE 'UTC';
        ELSIF NEW.status = 'issued' THEN
          IF NEW.document_number IS DISTINCT FROM COALESCE(
            (SELECT max(document_number) FROM finance_receivables_documents
             WHERE series_id = NEW.series_id), 0) + 1 THEN
            RAISE EXCEPTION 'document % is not the next number in series %',
              NEW.document_number, NEW.series_id
              USING ERRCODE = 'check_violation';
          END IF;

          IF NOT EXISTS (SELECT 1 FROM finance_receivables_document_lines WHERE document_id = NEW.id)
            OR NEW.subtotal <> (SELECT sum(amount) FROM finance_receivables_document_lines
                                WHERE document_id = NEW.id)
            OR NEW.tax_total <> (SELECT sum(tax_amount) FROM finance_receivables_document_lines
                                 WHERE document_id = NEW.id)
            OR NEW.tax_total <> COALESCE((SELECT sum(tax_amount)
                                          FROM finance_receivables_document_tax_lines
                                          WHERE document_id = NEW.id), 0) THEN
            RAISE EXCEPTION 'document % totals do not equal its lines', NEW.id
              USING ERRCODE = 'check_violation';
          END IF;

          IF NEW.kind = 'credit_note' THEN
            SELECT * INTO credited FROM finance_receivables_documents
            WHERE id = NEW.credited_document_id;

            IF credited.kind <> 'invoice' OR credited.status <> 'issued'
              OR credited.customer_id <> NEW.customer_id THEN
              RAISE EXCEPTION 'a credit note credits an issued invoice of the same customer'
                USING ERRCODE = 'check_violation';
            END IF;

            IF NEW.receivable_account_id IS DISTINCT FROM credited.receivable_account_id THEN
              RAISE EXCEPTION 'a credit note posts to the receivable account of its invoice'
                USING ERRCODE = 'check_violation';
            END IF;

            IF pg_temp.finance_receivables_outstanding(credited.id) < NEW.total THEN
              RAISE EXCEPTION 'credit note % exceeds what invoice % still owes', NEW.id, credited.id
                USING ERRCODE = 'check_violation';
            END IF;
          END IF;

          NEW.issued_at := clock_timestamp() AT TIME ZONE 'UTC';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_receivables_insert_draft() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.status <> 'draft' THEN
          RAISE EXCEPTION 'a finance receivables document is created as a draft'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_receivables_guard_draft_line() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        parent_id bigint;
      BEGIN
        IF TG_OP = 'DELETE' THEN
          parent_id := OLD.document_id;
        ELSE
          parent_id := NEW.document_id;
        END IF;

        IF TG_OP = 'UPDATE' AND NEW.document_id <> OLD.document_id THEN
          RAISE EXCEPTION 'a line keeps its document'
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF (SELECT status FROM finance_receivables_documents WHERE id = parent_id) <> 'draft' THEN
          RAISE EXCEPTION 'finance receivables document % is no longer a draft: its lines are kept',
            parent_id
            USING ERRCODE = 'restrict_violation';
        END IF;

        IF TG_OP = 'DELETE' THEN
          RETURN OLD;
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_receivables_number_payment() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF (SELECT kind FROM finance_receivables_series WHERE id = NEW.series_id) <> 'payment' THEN
          RAISE EXCEPTION 'a payment is numbered by a payment series'
            USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.payment_number IS DISTINCT FROM COALESCE(
          (SELECT max(payment_number) FROM finance_receivables_payments
           WHERE series_id = NEW.series_id), 0) + 1 THEN
          RAISE EXCEPTION 'payment % is not the next number in series %',
            NEW.payment_number, NEW.series_id
            USING ERRCODE = 'check_violation';
        END IF;

        NEW.recorded_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_receivables_check_allocation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM finance_receivables_documents d
          JOIN finance_receivables_payments p ON p.id = NEW.payment_id
          WHERE d.id = NEW.document_id AND d.kind = 'invoice' AND d.status = 'issued'
            AND d.customer_id = p.customer_id
        ) THEN
          RAISE EXCEPTION 'a payment is allocated to an issued invoice of its customer'
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_receivables_setup_change_stamp() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        NEW.changed_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_receivables_reversal_stamp() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        NEW.reversed_at := clock_timestamp() AT TIME ZONE 'UTC';
        RETURN NEW;
      END
      $$
      """,
      """
      CREATE FUNCTION pg_temp.finance_receivables_check_payment() RETURNS trigger
      LANGUAGE plpgsql AS $$
      DECLARE
        checked_id bigint;
      BEGIN
        IF TG_TABLE_NAME = 'finance_receivables_payments' THEN
          checked_id := NEW.id;
        ELSE
          checked_id := NEW.payment_id;
        END IF;

        IF (SELECT p.amount - COALESCE(sum(a.amount), 0)
            FROM finance_receivables_payments p
            LEFT JOIN finance_receivables_allocations a ON a.payment_id = p.id
            WHERE p.id = checked_id GROUP BY p.amount) <> 0 THEN
          RAISE EXCEPTION 'payment % allocations do not equal its amount', checked_id
            USING ERRCODE = 'check_violation';
        END IF;

        IF EXISTS (
          SELECT 1 FROM finance_receivables_allocations a
          WHERE a.payment_id = checked_id
            AND pg_temp.finance_receivables_outstanding(a.document_id) < 0
        ) THEN
          RAISE EXCEPTION 'payment % settles an invoice beyond what it owes', checked_id
            USING ERRCODE = 'check_violation';
        END IF;

        RETURN NULL;
      END
      $$
      """
    ]
  end

  defp triggers do
    identity =
      for {table, kept} <- [
            {"finance_receivables_setups", ~w(tenant_id company_id)},
            {"finance_receivables_series",
             ~w(tenant_id company_id code kind prefix number_width)},
            {"finance_receivables_tax_codes", ~w(tenant_id company_id code rate)},
            {"finance_receivables_customers", ~w(tenant_id company_id code)}
          ] do
        arguments = Enum.map_join(kept, ", ", &"'#{&1}'")

        [
          "CREATE TRIGGER #{table}_identity BEFORE UPDATE ON #{table} FOR EACH ROW " <>
            "EXECUTE FUNCTION pg_temp.finance_receivables_keep_identity(#{arguments})",
          "CREATE TRIGGER #{table}_kept BEFORE DELETE ON #{table} FOR EACH ROW " <>
            "EXECUTE FUNCTION pg_temp.finance_receivables_refuse_change()"
        ]
      end

    append_only =
      for table <- [
            "finance_receivables_setup_changes",
            "finance_receivables_payments",
            "finance_receivables_allocations",
            "finance_receivables_payment_reversals"
          ] do
        "CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table} " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_receivables_refuse_change()"
      end

    no_truncate =
      for table <- @tables do
        "CREATE TRIGGER #{table}_no_truncate BEFORE TRUNCATE ON #{table} " <>
          "FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.finance_receivables_refuse_change()"
      end

    draft_lines =
      for table <- [
            "finance_receivables_document_lines",
            "finance_receivables_document_tax_lines"
          ] do
        "CREATE TRIGGER #{table}_draft_only BEFORE INSERT OR UPDATE OR DELETE ON #{table} " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_receivables_guard_draft_line()"
      end

    settled =
      for table <- ["finance_receivables_payments", "finance_receivables_allocations"] do
        "CREATE CONSTRAINT TRIGGER #{table}_settled AFTER INSERT ON #{table} " <>
          "DEFERRABLE INITIALLY DEFERRED " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_receivables_check_payment()"
      end

    List.flatten(identity) ++
      append_only ++
      no_truncate ++
      draft_lines ++
      settled ++
      [
        "CREATE TRIGGER finance_receivables_documents_kept BEFORE DELETE ON finance_receivables_documents " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_receivables_refuse_change()",
        "CREATE TRIGGER finance_receivables_documents_guard BEFORE UPDATE ON finance_receivables_documents " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_receivables_guard_document()",
        "CREATE TRIGGER finance_receivables_documents_draft BEFORE INSERT ON finance_receivables_documents " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_receivables_insert_draft()",
        "CREATE TRIGGER finance_receivables_payments_number BEFORE INSERT ON finance_receivables_payments " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_receivables_number_payment()",
        "CREATE TRIGGER finance_receivables_allocations_invoice BEFORE INSERT ON finance_receivables_allocations " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_receivables_check_allocation()",
        "CREATE TRIGGER finance_receivables_setup_changes_stamp BEFORE INSERT ON finance_receivables_setup_changes " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_receivables_setup_change_stamp()",
        "CREATE TRIGGER finance_receivables_payment_reversals_stamp BEFORE INSERT ON finance_receivables_payment_reversals " <>
          "FOR EACH ROW EXECUTE FUNCTION pg_temp.finance_receivables_reversal_stamp()"
      ]
  end
end
