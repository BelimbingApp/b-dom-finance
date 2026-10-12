defmodule Bilimbi.Finance.Einvoice.Configuration do
  @moduledoc """
  A company's e-invoicing settings: the environment it submits to, the
  format version it submits in, the credentials the authority issued it
  for each environment, its signing certificate and private key, the
  supplier profile every document it issues carries, and the ledger
  accounts a validated document posts to.

  Every value is a company-scoped Base Setting in the editable group
  `finance.einvoice`, guarded by `finance.einvoice.settings.manage`, so the
  company's own operators set them on the Settings screen. The client
  secrets, certificate, and private key are encrypted settings: masked on
  screen and revealable only through Base Settings' password-checked reveal.
  Nothing here logs or returns a secret except `credentials/2`, which the
  authority client alone calls.

  Each company registers with the authority and holds its own certificate;
  no value has a default that names a country, a tax number, or a
  credential.
  """

  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Einvoice.Certificate

  @group "finance.einvoice"
  @capability "finance.einvoice.settings.manage"
  @environments ["sandbox", "production"]

  # The ledger accounts a validated document's entry names, by the account
  # codes of the company's own chart; none is a default.
  @posting_accounts [
    receivable_account:
      {"Receivable account",
       "Account code debited by a validated invoice or debit note and credited by a credit note."},
    revenue_account:
      {"Revenue account",
       "Account code credited with the tax-exclusive amount of a validated invoice or debit note."},
    tax_account:
      {"Tax account", "Account code credited with the tax of a validated invoice or debit note."},
    settlement_account:
      {"Settlement account",
       "Account code credited by a validated refund note, in place of the receivable account."}
  ]

  # The one authority this release clears documents with; see `Authority`.
  @authority Bilimbi.Finance.Einvoice.MyInvois

  @supplier_fields [
    name:
      {"Supplier name", "The registered name on documents. Blank uses the company's name.", 300,
       nil},
    tax_id:
      {"Supplier TIN",
       "The tax identification number the authority registered the company under.", 14, :tax_id},
    registration_type:
      {"Supplier registration type",
       "The kind of registration number: BRN for a business, NRIC, PASSPORT, or ARMY for an individual. Blank means BRN.",
       8, :registration_type},
    registration_number:
      {"Supplier registration number",
       "The business registration number, as on the signing certificate, or the individual's identification number.",
       20, nil},
    sales_tax_registration:
      {"Sales and service tax registration",
       "Up to two registration numbers separated by a semicolon. Blank when not registered.", 35,
       nil},
    tourism_tax_registration: {"Tourism tax registration", "Blank when not registered.", 17, nil},
    industry_code:
      {"Industry classification code", "The five-digit industry code the company registered.", 5,
       :industry_code},
    business_activity:
      {"Business activity", "The description of the business activity that goes with the code.",
       300, nil},
    phone: {"Supplier phone", "In international form, for example +60123456789.", 20, :phone},
    email: {"Supplier email", "Optional contact email on documents.", 320, nil},
    address_line1: {"Address line 1", "First line of the supplier address.", 150, nil},
    address_line2: {"Address line 2", "Optional second line.", 150, nil},
    address_line3: {"Address line 3", "Optional third line.", 150, nil},
    city: {"City", "City of the supplier address.", 50, nil},
    postcode: {"Postcode", "Postcode of the supplier address.", 50, nil},
    state_code:
      {"State code", "The authority's two-digit code for the state of the supplier address.", 2,
       :state_code},
    country_code:
      {"Country code", "Three-letter ISO 3166 code of the supplier address.", 3, :country_code}
  ]

  @doc "The editable settings group the Settings screen shows these under."
  def group, do: @group

  @doc "The capability that edits these settings and tests the connection."
  def capability, do: @capability

  @doc "The authority module every company's documents are cleared with."
  def authority, do: @authority

  @doc "The environments a company can submit to."
  def environments, do: @environments

  @doc "The ledger account settings, by field."
  def posting_account_fields, do: Keyword.keys(@posting_accounts)

  @doc "Setting definitions for the module's settings contribution."
  @spec definitions() :: %{String.t() => map()}
  def definitions do
    connection = %{
      "finance.einvoice.environment" =>
        editable(
          :string,
          "sandbox",
          "Environment",
          "Sandbox submits test documents; production submits documents the authority keeps.",
          validator: {__MODULE__, :valid_environment?, "must be sandbox or production"}
        ),
      "finance.einvoice.certificate_pem" =>
        editable(
          :string,
          nil,
          "Signing certificate (PEM)",
          "The company's X.509 signing certificate in PEM form.",
          nullable: true,
          encrypted: true,
          validator:
            {Certificate, :valid_certificate_pem?, "must be one PEM-encoded X.509 certificate"}
        ),
      "finance.einvoice.private_key_pem" =>
        editable(
          :string,
          nil,
          "Signing private key (PEM)",
          "The certificate's RSA private key in unencrypted PEM form.",
          nullable: true,
          encrypted: true,
          validator:
            {Certificate, :valid_private_key_pem?,
             "must be one unencrypted PEM-encoded RSA private key"}
        ),
      "finance.einvoice.expiry_alert_days" =>
        editable(
          :integer,
          30,
          "Expiry alert (days)",
          "Warn this many days before the certificate or a client secret expires.",
          minimum: 1,
          maximum: 365
        ),
      "finance.einvoice.document_version" =>
        editable(
          :string,
          @authority.version(),
          "Document format version",
          "The authority's format version documents are submitted in. " <>
            "A signed version needs the certificate and private key; an unsigned one is for sandbox testing before the certificate arrives.",
          validator:
            {__MODULE__, :valid_document_version?, "must be a version the authority accepts"}
        )
    }

    posting =
      Map.new(@posting_accounts, fn {field, {label, help}} ->
        {"finance.einvoice.posting.#{field}",
         editable(:string, nil, label, help,
           nullable: true,
           validator: {__MODULE__, :valid_text_50?, "must be at most 50 characters"}
         )}
      end)

    per_environment = @environments |> Enum.flat_map(&environment_definitions/1) |> Map.new()

    supplier =
      Map.new(@supplier_fields, fn {field, {label, help, max, validator}} ->
        options = [nullable: true, validator: supplier_validator(validator, max)]
        {"finance.einvoice.supplier.#{field}", editable(:string, nil, label, help, options)}
      end)

    connection |> Map.merge(per_environment) |> Map.merge(supplier) |> Map.merge(posting)
  end

  defp environment_definitions(environment) do
    title = String.capitalize(environment)
    prefix = "finance.einvoice.#{environment}"

    client_id_help = "The client ID the authority issued for #{environment} ERP access."
    secret_help = "The client secret issued with the #{environment} client ID."
    expiry_help = "The date the #{environment} client secret expires, as YYYY-MM-DD."
    date = {__MODULE__, :valid_date?, "must be a date as YYYY-MM-DD"}

    [
      {"#{prefix}.client_id",
       editable(:string, nil, "#{title} client ID", client_id_help, nullable: true)},
      {"#{prefix}.client_secret",
       editable(:string, nil, "#{title} client secret", secret_help,
         nullable: true,
         encrypted: true
       )},
      {"#{prefix}.secret_expires_on",
       editable(:string, nil, "#{title} secret expiry date", expiry_help,
         nullable: true,
         validator: date
       )}
    ]
  end

  defp supplier_validator(nil, max),
    do: {__MODULE__, :"valid_text_#{max}?", "must be at most #{max} characters"}

  defp supplier_validator(kind, _max),
    do: {__MODULE__, :"valid_#{kind}?", @authority.format_message(kind)}

  defp editable(type, default, label, help, options) do
    Map.merge(
      %{
        type: type,
        scopes: [:company],
        default: default,
        label: label,
        help: help,
        editable: @group,
        capability: @capability
      },
      Map.new(options)
    )
  end

  ## Validators. Each takes a value the definition's type already accepts.

  def valid_environment?(value), do: value in @environments

  def valid_document_version?(value),
    do: Enum.any?(@authority.document_versions(), &(&1.version == value))

  def valid_date?(value), do: is_binary(value) and match?({:ok, _}, Date.from_iso8601(value))

  for kind <- [:tax_id, :industry_code, :phone, :state_code, :country_code, :registration_type] do
    def unquote(:"valid_#{kind}?")(value), do: @authority.valid_format?(unquote(kind), value)
  end

  for max <- [2, 3, 5, 14, 17, 20, 35, 50, 150, 300, 320] do
    def unquote(:"valid_text_#{max}?")(value),
      do: is_binary(value) and String.length(String.trim(value)) in 1..unquote(max)
  end

  ## Reads

  @doc """
  The company's supplier profile: every `finance.einvoice.supplier.*` value
  by field, blank ones as `nil`, with `name` falling back to `company_name`.
  """
  @spec supplier(Scope.t(), pos_integer(), String.t()) :: %{atom() => String.t() | nil}
  def supplier(%Scope{} = scope, company_id, company_name) do
    keys = Enum.map(@supplier_fields, fn {field, _} -> "finance.einvoice.supplier.#{field}" end)
    values = Settings.get_many(keys, settings_scope(scope, company_id))

    profile =
      Map.new(@supplier_fields, fn {field, _} ->
        {field, blank_to_nil(Map.get(values, "finance.einvoice.supplier.#{field}"))}
      end)

    profile
    |> Map.update!(:name, &(&1 || company_name))
    |> Map.update!(:registration_type, &(&1 || "BRN"))
  end

  @doc """
  The ledger account codes a validated document posts to, blank ones as
  `nil`: `receivable_account`, `revenue_account`, `tax_account`, and
  `settlement_account`.
  """
  @spec posting_accounts(Scope.t(), pos_integer()) :: %{atom() => String.t() | nil}
  def posting_accounts(%Scope{} = scope, company_id) do
    keys = Enum.map(@posting_accounts, fn {field, _} -> "finance.einvoice.posting.#{field}" end)
    values = Settings.get_many(keys, settings_scope(scope, company_id))

    Map.new(@posting_accounts, fn {field, _} ->
      {field, blank_to_nil(Map.get(values, "finance.einvoice.posting.#{field}"))}
    end)
  end

  @doc "The format version the company submits documents in."
  @spec document_version(Scope.t(), pos_integer()) :: String.t()
  def document_version(%Scope{} = scope, company_id),
    do: Settings.get("finance.einvoice.document_version", settings_scope(scope, company_id))

  @doc """
  The company's credentials for `environment` (its current one by
  default), secrets included. Only the authority client and the setup
  page's checks call this; never log or render the result.
  """
  @spec credentials(Scope.t(), pos_integer(), String.t() | nil) :: map()
  def credentials(%Scope{} = scope, company_id, environment \\ nil) do
    settings_scope = settings_scope(scope, company_id)
    environment = environment || Settings.get("finance.einvoice.environment", settings_scope)

    values =
      Settings.get_many(
        [
          "finance.einvoice.#{environment}.client_id",
          "finance.einvoice.#{environment}.client_secret",
          "finance.einvoice.#{environment}.secret_expires_on",
          "finance.einvoice.certificate_pem",
          "finance.einvoice.private_key_pem",
          "finance.einvoice.expiry_alert_days"
        ],
        settings_scope
      )

    %{
      environment: environment,
      client_id: blank_to_nil(values["finance.einvoice.#{environment}.client_id"]),
      client_secret: blank_to_nil(values["finance.einvoice.#{environment}.client_secret"]),
      secret_expires_on: date(values["finance.einvoice.#{environment}.secret_expires_on"]),
      certificate_pem: blank_to_nil(values["finance.einvoice.certificate_pem"]),
      private_key_pem: blank_to_nil(values["finance.einvoice.private_key_pem"]),
      expiry_alert_days: values["finance.einvoice.expiry_alert_days"]
    }
  end

  @doc "The company's current environment."
  @spec environment(Scope.t(), pos_integer()) :: String.t()
  def environment(%Scope{} = scope, company_id),
    do: Settings.get("finance.einvoice.environment", settings_scope(scope, company_id))

  defp settings_scope(scope, company_id),
    do: Settings.Scope.company(company_id, Scope.tenant_id(scope))

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp date(_value), do: nil
end
