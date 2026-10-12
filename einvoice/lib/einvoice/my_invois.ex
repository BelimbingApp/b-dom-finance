defmodule Bilimbi.Finance.Einvoice.MyInvois do
  @moduledoc """
  The MyInvois clearance authority: its rules for a document, the mapping
  from a recorded document to its UBL 2.1 JSON (`MyInvois.Builder`), the
  JSON XAdES signature (`MyInvois.Signer`), and its API
  (`MyInvois.Client`).

  Rules follow the authority's e-Invoice Guideline v4.8 (30 August 2026) and
  its SDK as read on 12 October 2026. Format version 1.1 turns on signature
  validation; version 1.0 is submitted unsigned, which is how a company
  tests the sandbox before its certificate arrives. Invoices (`01`) and the
  credit, debit, and refund notes that reference a validated original
  (`02` to `04`), their self-billed counterparts (`11` to `14`), which the
  company issues as the buyer, and the monthly consolidated invoice, in
  ringgit, are issued in this release; foreign currencies come later. The
  builder already writes every element the SDK's samples use.

  The consolidated invoice follows the Specific Guideline v4.9 (§3.6,
  §3.7): it reports a calendar month (Malaysian time) of sales no buyer
  asked an individual e-invoice for, to the general public buyer
  (`EI00000000010`) with classification `004`, issued within seven days
  after the month ends, and never covers a sale over RM10,000. A
  self-billed document (§8.3) names the supplier as the counterparty; a
  foreign supplier without a Malaysian TIN takes the general TIN
  `EI00000000030`.

  The API callbacks translate the authority's answers into the meta-terms
  the facade and workers record, keeping each raw response beside them:
  a 202 whose accepted list names the document is `:accepted`; a 202 that
  lists it as rejected is `:rejected`; `DuplicateSubmission` (422) is
  `:duplicate`; 429 is `:rate_limited`; a 5xx or transport failure is
  `:unavailable`; any other refusal is `:refused`. A document the
  authority may already hold is found again among the documents the
  taxpayer recently sent (up to #{30} days back), by its internal ID,
  which is the company's code number.
  """

  @behaviour Bilimbi.Finance.Einvoice.Authority

  import Ecto.Changeset

  alias Bilimbi.Base.Settings
  alias Bilimbi.Finance.Einvoice.MyInvois.{Builder, Client, Signer}

  @version "1.1"
  @versions [%{version: "1.1", signed: true}, %{version: "1.0", signed: false}]
  @invoice "01"
  @notes ["02", "03", "04"]
  @self_billed_invoice "11"
  @self_billed_notes ["12", "13", "14"]
  # The invoice type each note type corrects.
  @invoice_of %{
    "02" => @invoice,
    "03" => @invoice,
    "04" => @invoice,
    "12" => @self_billed_invoice,
    "13" => @self_billed_invoice,
    "14" => @self_billed_invoice
  }
  # The authority's general TINs (Specific Guideline §3.7 and §8.3): the
  # general public buyer of a consolidated invoice, and a foreign supplier
  # without a Malaysian TIN on a self-billed document.
  @general_public_tin "EI00000000010"
  @foreign_supplier_tin "EI00000000030"
  @home_country "MYS"
  @consolidated_classification "004"
  # A consolidated invoice is issued within seven days after its month ends,
  # in Malaysian time (UTC+8, no daylight saving), and covers no sale above
  # RM10,000, which needs an individual e-invoice.
  @local_offset_seconds 8 * 3600
  @consolidation_days 7
  @consolidation_limit Decimal.new("10000")
  @referable ["valid", "rejected"]
  @search_days 30
  @search_pages 10
  @portal_urls %{
    "sandbox" => "https://preprod.myinvois.hasil.gov.my",
    "production" => "https://myinvois.hasil.gov.my"
  }
  # The authority reports tax in ringgit, whatever the document currency.
  @tax_currency "MYR"
  @registration_types ["BRN", "NRIC", "PASSPORT", "ARMY"]
  @exempt "E"
  # Tax types that charge tax, so a rate above zero; and those that take none.
  @taxed ["01", "02", "03", "04", "05"]
  @untaxed ["06", @exempt]

  @supplier_required [
    tax_id: "supplier TIN",
    registration_number: "supplier registration number",
    industry_code: "industry classification code",
    business_activity: "business activity",
    phone: "supplier phone",
    address_line1: "address line 1",
    city: "city",
    state_code: "state code",
    country_code: "country code"
  ]

  @impl true
  def id, do: "myinvois"

  @impl true
  def issuable_document_types, do: [@invoice | @notes] ++ [@self_billed_invoice | @self_billed_notes]

  @impl true
  def note_document_types, do: @notes ++ @self_billed_notes

  @impl true
  def self_billed_document_types, do: [@self_billed_invoice | @self_billed_notes]

  # A sale debits the receivable and credits revenue and tax; a self-billed
  # purchase credits the payable and debits expense and purchase tax. A
  # credit note posts the mirror image, and a refund note settles in cash.
  @sale %{net: :revenue_account, tax: :tax_account}
  @purchase %{net: :expense_account, tax: :purchase_tax_account}

  @impl true
  def posting_rule("01"), do: Map.merge(@sale, %{side: :debit, counter: :receivable_account})
  def posting_rule("02"), do: Map.merge(@sale, %{side: :credit, counter: :receivable_account})
  def posting_rule("03"), do: Map.merge(@sale, %{side: :debit, counter: :receivable_account})
  def posting_rule("04"), do: Map.merge(@sale, %{side: :credit, counter: :settlement_account})
  def posting_rule("11"), do: Map.merge(@purchase, %{side: :credit, counter: :payable_account})
  def posting_rule("12"), do: Map.merge(@purchase, %{side: :debit, counter: :payable_account})
  def posting_rule("13"), do: Map.merge(@purchase, %{side: :credit, counter: :payable_account})
  def posting_rule("14"), do: Map.merge(@purchase, %{side: :debit, counter: :settlement_account})
  def posting_rule(_type), do: nil

  @impl true
  def document_type_name("01"), do: "Invoice"
  def document_type_name("02"), do: "Credit note"
  def document_type_name("03"), do: "Debit note"
  def document_type_name("04"), do: "Refund note"
  def document_type_name("11"), do: "Self-billed invoice"
  def document_type_name("12"), do: "Self-billed credit note"
  def document_type_name("13"), do: "Self-billed debit note"
  def document_type_name("14"), do: "Self-billed refund note"
  def document_type_name(type), do: "Document type #{type}"

  @impl true
  def cancellation_window_hours, do: 72

  @impl true
  def outage_notice_hours, do: 72

  ## Consolidated invoices

  # The general public buyer as the Specific Guideline (§3.7) writes it:
  # registration, contact, and address "NA", state "Not Applicable".
  @general_public_buyer %{
    name: "General Public",
    tax_id: @general_public_tin,
    registration_type: "BRN",
    registration_number: "NA",
    phone: "NA",
    address: %{lines: ["NA"], city: "NA", state_code: "17", country_code: @home_country}
  }

  @impl true
  def consolidation_window(%Date{} = month) do
    first = Date.beginning_of_month(month)
    until = first |> Date.end_of_month() |> Date.add(1) |> local_midnight()

    %{
      from: local_midnight(first),
      until: until,
      closes_at: DateTime.add(until, @consolidation_days * 86_400, :second)
    }
  end

  defp local_midnight(date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(-@local_offset_seconds, :second)
  end

  @impl true
  def consolidation_refusal(document) do
    cond do
      document.document_type != @invoice ->
        "is not an invoice"

      document.currency_code != @tax_currency ->
        "is not in #{@tax_currency}"

      Decimal.gt?(document.payable_amount, @consolidation_limit) ->
        "is above RM#{Decimal.to_string(@consolidation_limit)}, which needs an individual e-invoice"

      true ->
        nil
    end
  end

  @impl true
  def consolidated_document(%{code_number: code, issued_at: issued_at, month: month, lines: lines}) do
    %{
      document_type: @invoice,
      code_number: code,
      issued_at: issued_at,
      currency_code: @tax_currency,
      billing_period_start: Date.beginning_of_month(month),
      billing_period_end: Date.end_of_month(month),
      billing_period_description: "Monthly",
      buyer: @general_public_buyer,
      lines:
        Enum.map(lines, fn line ->
          %{
            description: line.description,
            classification_code: @consolidated_classification,
            quantity: "1",
            unit_code: "C62",
            unit_price: line.amount,
            tax_type: line.tax_type,
            tax_rate: line.tax_rate,
            tax_exemption_reason: line.tax_exemption_reason,
            tax_amount: line.tax_amount
          }
        end)
    }
  end

  @impl true
  def document_versions, do: @versions

  @doc "The UBL format version documents are built in when a company chose none."
  def version, do: @version

  @doc "Platform settings for the portal that shows validated documents, per environment."
  @spec portal_settings_definitions() :: %{String.t() => map()}
  def portal_settings_definitions do
    Map.new(@portal_urls, fn {environment, url} ->
      {"finance.einvoice.#{environment}.portal_url",
       %{
         type: :string,
         scopes: [:global],
         default: url,
         label: "E-invoice #{environment} portal URL",
         help:
           "Base URL of the MyInvois #{environment} portal that a document's validation link opens.",
         editable: "operator",
         capability: "base.settings.global.manage",
         validator: {Client, :valid_url?, "must be an https URL without a path"}
       }}
    end)
  end

  @impl true
  def validation_url(environment, document_uuid, long_id) do
    url =
      Settings.get("finance.einvoice.#{environment}.portal_url") ||
        Map.fetch!(@portal_urls, environment)

    "#{String.trim_trailing(url, "/")}/#{document_uuid}/share/#{long_id}"
  end

  @impl true
  def valid_format?(kind, value), do: is_binary(value) and value =~ format(kind).pattern

  @impl true
  def format_message(kind), do: format(kind).message

  # Supplier settings and buyer details alike are checked against these.
  defp format(:tax_id),
    do: %{
      pattern: ~r/\A[A-Z]{1,2}[0-9]{8,12}\z/,
      message: "must be one or two capital letters and 8 to 12 digits"
    }

  defp format(:phone),
    do: %{
      pattern: ~r/\A\+[0-9]{8,19}\z/,
      message: "must be a plus sign and 8 to 20 digits, 20 characters at most"
    }

  defp format(:industry_code), do: %{pattern: ~r/\A[0-9]{5}\z/, message: "must be five digits"}

  defp format(:registration_type),
    do: %{
      pattern: ~r/\A(BRN|NRIC|PASSPORT|ARMY)\z/,
      message: "must be BRN, NRIC, PASSPORT, or ARMY"
    }

  defp format(:state_code), do: %{pattern: ~r/\A[0-9]{2}\z/, message: "must be two digits"}

  defp format(:country_code),
    do: %{pattern: ~r/\A[A-Z]{3}\z/, message: "must be three capital letters"}

  @impl true
  def supplier_missing(supplier),
    do: for({field, _label} <- @supplier_required, is_nil(supplier[field]), do: field)

  @impl true
  def certificate_identity(subject),
    do: %{
      tax_id: subject["organization_identifier"],
      registration_number: subject["serial_number"]
    }

  @impl true
  def login(scope, company_id, credentials) do
    case Client.login(scope, company_id, credentials) do
      {:ok, _token} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def validate(changeset, %{supplier: profile, codes: codes} = context) do
    consolidated? = Map.get(context, :consolidated, false)

    # The company's profile is the supplier, or the buyer on a self-billed
    # document; either way it must carry what every document needs.
    profile_field =
      if get_field(changeset, :document_type) in self_billed_document_types(),
        do: :buyer,
        else: :supplier

    changeset
    |> validate_inclusion(:document_type, issuable_document_types(),
      message: "is not a document type this release issues"
    )
    |> validate_code(:document_type, codes.("document_type"))
    |> validate_code(:currency_code, codes.("currency"))
    |> validate_code(:payment_means_code, codes.("payment_means"))
    |> validate_tax_currency()
    |> validate_original(Map.get(context, :original))
    |> validate_profile(profile_field, profile, codes)
    |> update_embed(:buyer, &validate_party(&1, codes))
    |> update_embed(:supplier, &validate_supplier_party(&1, codes))
    |> update_embeds(:lines, &validate_line(&1, codes, consolidated?))
    |> validate_consolidated(consolidated?)
  end

  # A consolidated invoice goes to the general public buyer, whose contact
  # the authority writes as "NA"; only `Consolidation` builds one.
  defp validate_consolidated(changeset, false), do: changeset

  defp validate_consolidated(changeset, true) do
    buyer = get_field(changeset, :buyer)

    cond do
      get_field(changeset, :document_type) != @invoice ->
        add_error(changeset, :document_type, "must be an invoice for a consolidated document")

      is_nil(buyer) or buyer.tax_id != @general_public_tin ->
        add_error(changeset, :buyer, "must be the general public for a consolidated document")

      true ->
        changeset
    end
  end

  # A note references the validated original it corrects (Guideline
  # §2.4.5): the original must be valid at the authority (a buyer's
  # rejection request leaves it valid there), carry its UUID,
  # be an invoice rather than another note, and share the currency. An
  # invoice references nothing.
  defp validate_original(changeset, original) do
    type = get_field(changeset, :document_type)
    original_id = get_field(changeset, :original_document_id)
    notes = note_document_types()

    cond do
      type in notes and is_nil(original_id) ->
        add_error(changeset, :original_document_id, "is required for a note")

      type in notes and is_nil(original) ->
        add_error(changeset, :original_document_id, "is not a document of this company")

      type in notes and original.status not in @referable ->
        add_error(changeset, :original_document_id, "is not a validated document")

      type in notes and is_nil(original.document_uuid) ->
        add_error(changeset, :original_document_id, "has no document UUID from the authority")

      type in notes and original.document_type in notes ->
        add_error(changeset, :original_document_id, "is itself a note; reference the invoice")

      # A self-billed note corrects a self-billed invoice, and a note a sale.
      type in notes and original.document_type != @invoice_of[type] ->
        add_error(
          changeset,
          :original_document_id,
          "must be the #{String.downcase(document_type_name(@invoice_of[type]))} it corrects"
        )

      type in notes and original.currency_code != get_field(changeset, :currency_code) ->
        add_error(changeset, :currency_code, "must match the original document's currency")

      type not in notes and not is_nil(original_id) ->
        add_error(changeset, :original_document_id, "is only given for a note")

      true ->
        changeset
    end
  end

  # The SDK's foreign-currency sample writes tax amounts in ringgit beside
  # document-currency totals without saying how they convert; until the
  # sandbox confirms the rule, only ringgit documents are issued.
  defp validate_tax_currency(changeset) do
    validate_change(changeset, :currency_code, fn :currency_code, currency ->
      if currency == @tax_currency,
        do: [],
        else: [currency_code: "must be #{@tax_currency} in this release"]
    end)
  end

  defp validate_profile(changeset, field, profile, codes) do
    missing = for key <- supplier_missing(profile), do: @supplier_required[key]

    cond do
      missing != [] ->
        add_error(
          changeset,
          field,
          "is incomplete: set #{Enum.join(missing, ", ")} in the e-invoice settings"
        )

      not Map.has_key?(codes.("industry"), profile.industry_code) ->
        add_error(changeset, field, "industry classification code is not a known code")

      not Map.has_key?(codes.("state"), profile.state_code) ->
        add_error(changeset, field, "state code is not a known code")

      not Map.has_key?(codes.("country"), profile.country_code) ->
        add_error(changeset, field, "country code is not a known code")

      true ->
        changeset
    end
  end

  # The general public buyer's contact is "NA" (Specific Guideline §3.7).
  defp validate_party(party, codes) do
    general_public? = get_field(party, :tax_id) == @general_public_tin

    party
    |> validate_shape(:tax_id, :tax_id)
    |> validate_inclusion(:registration_type, @registration_types)
    |> validate_required([:phone])
    |> then(fn party ->
      if general_public? and get_field(party, :phone) == "NA",
        do: party,
        else: validate_shape(party, :phone, :phone)
    end)
    |> update_embed(:address, fn address ->
      address
      |> validate_code(:state_code, codes.("state"))
      |> validate_code(:country_code, codes.("country"))
    end)
  end

  # A self-billed document's supplier carries what a supplier profile does:
  # its industry code and activity (`00000`, "NOT APPLICABLE", for one
  # abroad). The foreign-supplier TIN is for a supplier outside Malaysia.
  defp validate_supplier_party(party, codes) do
    country = party |> get_field(:address) |> then(&(&1 && &1.country_code))

    party
    |> validate_party(codes)
    |> validate_required([:industry_code, :business_activity])
    |> validate_code(:industry_code, codes.("industry"))
    |> validate_change(:tax_id, fn :tax_id, tax_id ->
      if tax_id == @foreign_supplier_tin and country == @home_country,
        do: [tax_id: "is the general TIN for a supplier outside Malaysia"],
        else: []
    end)
  end

  defp validate_shape(changeset, field, kind) do
    validate_change(changeset, field, fn ^field, value ->
      if valid_format?(kind, value), do: [], else: [{field, format_message(kind)}]
    end)
  end

  defp validate_line(line, codes, consolidated?) do
    line
    |> validate_rate()
    |> validate_code(:classification_code, codes.("classification"))
    |> validate_change(:classification_code, fn :classification_code, code ->
      cond do
        consolidated? and code != @consolidated_classification ->
          [classification_code: "must be #{@consolidated_classification} on a consolidated document"]

        not consolidated? and code == @consolidated_classification ->
          [classification_code: "is for a consolidated document; consolidate the month instead"]

        true ->
          []
      end
    end)
    |> validate_code(:tax_type, codes.("tax_type"))
    |> validate_code(:unit_code, codes.("unit"))
    |> validate_code(:origin_country_code, codes.("country"))
    |> then(fn line ->
      if get_field(line, :tax_type) == @exempt and is_nil(get_field(line, :tax_exemption_reason)),
        do: add_error(line, :tax_exemption_reason, "is required for an exempt line"),
        else: line
    end)
  end

  defp validate_rate(line) do
    tax_type = get_field(line, :tax_type)
    rate = get_field(line, :tax_rate)

    cond do
      tax_type in @taxed and not Decimal.gt?(rate, 0) ->
        add_error(line, :tax_rate, "must be above 0 for this tax type")

      tax_type in @untaxed and not Decimal.eq?(rate, 0) ->
        add_error(line, :tax_rate, "must be 0 for this tax type")

      true ->
        line
    end
  end

  defp validate_code(changeset, field, codes) do
    validate_change(changeset, field, fn ^field, code ->
      if Map.has_key?(codes, code), do: [], else: [{field, "is not a known code"}]
    end)
  end

  defp update_embed(changeset, field, fun) do
    case get_change(changeset, field) do
      %Ecto.Changeset{} = embedded ->
        checked = fun.(embedded)

        changeset
        |> put_embed_change(field, checked)
        |> Map.update!(:valid?, &(&1 and checked.valid?))

      _other ->
        changeset
    end
  end

  defp update_embeds(changeset, field, fun) do
    case get_change(changeset, field) do
      embeds when is_list(embeds) ->
        checked = Enum.map(embeds, fun)

        changeset
        |> put_embed_change(field, checked)
        |> Map.update!(:valid?, &(&1 and Enum.all?(checked, fn line -> line.valid? end)))

      _other ->
        changeset
    end
  end

  # Swaps the checked embedded changesets in without re-casting them.
  defp put_embed_change(changeset, field, value),
    do: Map.update!(changeset, :changes, &Map.put(&1, field, value))

  ## Payload

  @impl true
  def payload(document, %{version: version} = options, %DateTime{} = signing_time) do
    case Enum.find(@versions, &(&1.version == version)) do
      %{signed: true} ->
        case options[:signing_key] do
          %{certificate: _, key: _} = signing_key ->
            bytes =
              document
              |> ubl(version)
              |> Builder.build()
              |> Signer.sign(signing_key, signing_time)

            {:ok, %{format: "JSON", version: version, bytes: bytes}}

          _none ->
            {:error, :signing_key_required}
        end

      %{signed: false} ->
        bytes = document |> ubl(version) |> Builder.build() |> Signer.document_bytes()
        {:ok, %{format: "JSON", version: version, bytes: bytes}}

      nil ->
        {:error, :unsupported_version}
    end
  end

  ## API answers, in meta-terms

  @impl true
  def submit(scope, company_id, credentials, %{format: format, bytes: bytes, code_number: code}) do
    document = %{format: format, document: bytes, code_number: code}

    case Client.submit(scope, company_id, credentials, [document], owner_id: company_id) do
      {:ok, %{status: status, body: body}} ->
        submission_outcome(code, status, body)

      {:error, {:retry_after, seconds, 422, body}} ->
        {:duplicate, answer(422, body, retry_after: seconds)}

      {:error, {:http, 422, body}} ->
        if error_code(body) == "DuplicateSubmission",
          do: {:duplicate, answer(422, body)},
          else: {:refused, answer(422, body)}

      error ->
        failure(error)
    end
  end

  # A 202 lists each document as accepted (with its UUID) or rejected
  # (with the authority's error); a document missing from both lists is
  # treated as rejected, never as accepted.
  defp submission_outcome(code, status, %{"submissionUid" => uid} = body) when is_binary(uid) do
    accepted =
      body
      |> Map.get("acceptedDocuments", [])
      |> List.wrap()
      |> Enum.find(&code_matches?(&1, code))

    rejected =
      body
      |> Map.get("rejectedDocuments", [])
      |> List.wrap()
      |> Enum.find(&code_matches?(&1, code))

    cond do
      is_map(accepted) and is_binary(accepted["uuid"]) ->
        {:accepted, answer(status, body, submission_uid: uid, document_uuid: accepted["uuid"])}

      is_map(rejected) ->
        {:rejected,
         answer(status, body, submission_uid: uid, reason: error_message(rejected["error"]))}

      true ->
        {:rejected, answer(status, body, submission_uid: uid, reason: "not listed as accepted")}
    end
  end

  defp submission_outcome(_code, status, body),
    do: {:refused, answer(status, body, reason: "no submission UID in the answer")}

  defp code_matches?(%{"invoiceCodeNumber" => code}, code), do: true
  defp code_matches?(_entry, _code), do: false

  @impl true
  def submission_progress(scope, company_id, credentials, submission_uid) do
    case Client.submission_status(scope, company_id, credentials, submission_uid,
           owner_id: company_id
         ) do
      {:ok, %{status: status, body: %{"overallStatus" => overall} = body}} ->
        if overall |> to_string() |> String.downcase() == "in progress",
          do: {:in_progress, answer(status, body)},
          else: {:done, answer(status, body)}

      {:ok, %{status: status, body: body}} ->
        {:refused, answer(status, body, reason: "no overall status in the answer")}

      error ->
        failure(error)
    end
  end

  @impl true
  def find_submission(
        scope,
        company_id,
        credentials,
        %{
          code_number: code,
          since: since,
          until: until
        } = lookup
      ) do
    from = Enum.max([since, DateTime.add(until, -@search_days * 86_400, :second)], DateTime)
    known = Map.get(lookup, :exclude, [])
    search_sent(scope, company_id, credentials, {code, known}, [from: from, to: until], 1)
  end

  defp search_sent(scope, company_id, credentials, {code, known} = wanted, window, page) do
    case Client.recent_documents(scope, company_id, credentials, window,
           owner_id: company_id,
           page: page
         ) do
      {:ok, %{status: status, body: %{"result" => results} = body}} when is_list(results) ->
        case results
             |> Enum.filter(&(&1["internalId"] == code and &1["uuid"] not in known))
             |> Enum.max_by(&to_string(&1["dateTimeReceived"]), fn -> nil end) do
          %{"uuid" => uuid, "submissionUid" => uid} = entry
          when is_binary(uuid) and is_binary(uid) ->
            {:found,
             answer(status, entry,
               submission_uid: uid,
               document_uuid: uuid,
               reason: "found at the authority by its code number"
             )}

          _none ->
            cond do
              not more_pages?(body, page) ->
                {:not_found, answer(status, body)}

              page < @search_pages ->
                search_sent(scope, company_id, credentials, wanted, window, page + 1)

              true ->
                {:refused, answer(status, body, reason: "search window too large to read")}
            end
        end

      {:ok, %{status: status, body: body}} ->
        {:refused, answer(status, body, reason: "no document list in the answer")}

      error ->
        failure(error)
    end
  end

  defp more_pages?(%{"metadata" => %{"totalPages" => total}}, page) when is_integer(total),
    do: page < total

  defp more_pages?(_body, _page), do: false

  @impl true
  def document_status(scope, company_id, credentials, document_uuid) do
    case Client.document_details(scope, company_id, credentials, document_uuid,
           owner_id: company_id
         ) do
      {:ok, %{status: http_status, body: %{"status" => status} = body}} ->
        case status_name(status) do
          nil ->
            {:refused, answer(http_status, body, reason: "unknown status #{inspect(status)}")}

          name ->
            {:ok,
             answer(http_status, body,
               status: name,
               long_id: blank_to_nil(body["longId"]),
               validated_at: instant(body["dateTimeValidated"]),
               cancelled_at: instant(body["cancelDateTime"]),
               rejection_requested_at: instant(body["rejectRequestDateTime"]),
               reason: blank_to_nil(body["documentStatusReason"])
             )}
        end

      {:ok, %{status: http_status, body: body}} ->
        {:refused, answer(http_status, body, reason: "no status in the answer")}

      error ->
        failure(error)
    end
  end

  @impl true
  def cancel(scope, company_id, credentials, document_uuid, reason) do
    case Client.cancel_document(scope, company_id, credentials, document_uuid, reason,
           owner_id: company_id
         ) do
      {:ok, %{status: status, body: body}} ->
        {:ok, answer(status, body)}

      {:error, {:http, status, body}} when status in 400..499 ->
        code = error_code(body)

        reason_code =
          case code do
            "OperationPeriodOver" -> :period_over
            "IncorrectState" -> :incorrect_state
            "ActiveReferencingDocuments" -> :active_referencing_documents
            _other -> :other
          end

        {:refused,
         answer(status, body, reason_code: reason_code, reason: error_message(body["error"]))}

      {:error, :invalid_reason} ->
        {:refused,
         %{http_status: nil, response: nil, reason_code: :other, reason: "invalid reason"}}

      error ->
        failure(error)
    end
  end

  defp failure({:error, {:retry_after, seconds, status, body}}),
    do: {:rate_limited, answer(status, body, retry_after: seconds)}

  defp failure({:error, {:http, 429, body}}), do: {:rate_limited, answer(429, body)}

  defp failure({:error, {:http, status, body}}) when status >= 500,
    do: {:unavailable, answer(status, body, reason: "HTTP #{status}")}

  defp failure({:error, {:http, status, body}}),
    do: {:refused, answer(status, body, reason: error_message(body) || "HTTP #{status}")}

  defp failure({:error, {:transport, exception}}),
    do: {:unavailable, %{http_status: nil, response: nil, reason: transport_reason(exception)}}

  defp failure({:error, {:unexpected_token_response, status}}),
    do: {:refused, %{http_status: status, response: nil, reason: "unexpected login answer"}}

  defp failure({:error, :missing_credentials}),
    do: {:refused, %{http_status: nil, response: nil, reason: "missing credentials"}}

  defp failure({:error, reason}),
    do: {:refused, %{http_status: nil, response: nil, reason: inspect(reason)}}

  defp answer(status, body, extra \\ []) do
    Map.merge(%{http_status: status, response: body}, Map.new(extra))
  end

  defp transport_reason(%{__struct__: module}), do: module |> Module.split() |> List.last()
  defp transport_reason(other), do: inspect(other)

  defp error_code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp error_code(_body), do: nil

  defp error_message(%{"error" => error}), do: error_message(error)

  defp error_message(%{"message" => message} = error) when is_binary(message) do
    details =
      error
      |> Map.get("details", [])
      |> List.wrap()
      |> Enum.map(& &1["message"])
      |> Enum.filter(&is_binary/1)

    [message | details] |> Enum.join("; ") |> String.slice(0, 300)
  end

  defp error_message(%{"code" => code}) when is_binary(code), do: code
  defp error_message(_other), do: nil

  defp status_name(status) when is_binary(status) do
    case String.downcase(status) do
      "submitted" -> :submitted
      "valid" -> :valid
      "invalid" -> :invalid
      "cancelled" -> :cancelled
      _other -> nil
    end
  end

  defp status_name(_status), do: nil

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, instant, _offset} -> instant
      _error -> nil
    end
  end

  defp instant(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil

  @doc """
  The builder's input for a recorded document (`Einvoice.get_document/3`'s
  map): parties from their snapshots, per-tax-type subtotals from the
  lines, and for a note the original's code number and UUID as the issue
  snapshotted them.
  """
  @spec ubl(map(), String.t()) :: map()
  def ubl(document, version \\ @version) do
    issued_at = DateTime.truncate(document.issued_at, :second)
    details = document.details

    %{
      id: document.code_number,
      issue_date: issued_at |> DateTime.to_date() |> Date.to_iso8601(),
      issue_time: (issued_at |> DateTime.to_time() |> Time.to_iso8601()) <> "Z",
      type_code: document.document_type,
      version: version,
      billing_references: billing_references(details),
      currency_code: document.currency_code,
      tax_currency_code: @tax_currency,
      tax_exchange_rate:
        if(document.currency_code != @tax_currency,
          do: %{
            source: document.currency_code,
            target: @tax_currency,
            rate: document.exchange_rate
          }
        ),
      invoice_period: invoice_period(details),
      payment_means:
        if(details["payment_means_code"], do: %{code: details["payment_means_code"]}),
      payment_terms: details["payment_terms"],
      supplier: supplier(document.supplier),
      buyer: buyer(document.buyer),
      tax_total: %{
        tax_amount: document.tax_amount,
        subtotals: tax_subtotals(document.lines)
      },
      totals: %{
        line_extension_amount: document.line_extension_amount,
        tax_exclusive_amount: document.tax_exclusive_amount,
        tax_inclusive_amount: document.tax_inclusive_amount,
        payable_amount: document.payable_amount
      },
      lines: Enum.map(document.lines, &line/1)
    }
  end

  defp billing_references(%{"original_code_number" => code, "original_document_uuid" => uuid})
       when is_binary(code) and is_binary(uuid),
       do: [%{id: code, uuid: uuid}]

  defp billing_references(_details), do: []

  defp invoice_period(%{"billing_period_start" => start} = details) when is_binary(start) do
    %{
      start_date: start,
      end_date: details["billing_period_end"],
      description: details["billing_period_description"]
    }
  end

  defp invoice_period(_details), do: nil

  defp supplier(supplier) do
    %{
      name: supplier["name"],
      industry_code: %{code: supplier["industry_code"], name: supplier["business_activity"]},
      identifications: [
        {"TIN", supplier["tax_id"]},
        {supplier["registration_type"] || "BRN", supplier["registration_number"]},
        {"SST", supplier["sales_tax_registration"] || "NA"},
        {"TTX", supplier["tourism_tax_registration"] || "NA"}
      ],
      address: address(supplier["address"]),
      phone: supplier["phone"],
      email: supplier["email"]
    }
  end

  # On a self-billed document the buyer is the company's own profile, whose
  # registration type may be blank (a business, BRN).
  defp buyer(buyer) do
    %{
      name: buyer["name"],
      identifications: [
        {"TIN", buyer["tax_id"]},
        {buyer["registration_type"] || "BRN", buyer["registration_number"]},
        {"SST", buyer["sales_tax_registration"] || "NA"},
        {"TTX", "NA"}
      ],
      address: address(buyer["address"]),
      phone: buyer["phone"],
      email: buyer["email"]
    }
  end

  defp address(address) do
    %{
      lines: address["lines"],
      city: address["city"],
      postcode: address["postcode"],
      state_code: address["state_code"],
      country_code: address["country_code"]
    }
  end

  defp tax_subtotals(lines) do
    lines
    |> Enum.group_by(& &1.tax_type)
    |> Enum.sort_by(fn {tax_type, _lines} -> tax_type end)
    |> Enum.map(fn {tax_type, lines} ->
      %{
        taxable_amount: sum(lines, :line_extension_amount),
        tax_amount: sum(lines, :tax_amount),
        tax_type: tax_type,
        exemption_reason:
          if(tax_type == @exempt, do: Enum.find_value(lines, & &1.tax_exemption_reason))
      }
    end)
  end

  defp line(line) do
    discount = discount_or_charge(false, "Discount", line.discount_amount)
    charge = discount_or_charge(true, "Charge", line.charge_amount)

    %{
      id: Integer.to_string(line.line_number),
      quantity: line.quantity,
      unit_code: line.unit_code,
      line_extension_amount: line.line_extension_amount,
      allowance_charges: Enum.reject([discount, charge], &is_nil/1),
      tax_total: %{
        tax_amount: line.tax_amount,
        subtotals: [
          %{
            taxable_amount: line.line_extension_amount,
            tax_amount: line.tax_amount,
            percent: line.tax_rate,
            tax_type: line.tax_type,
            exemption_reason: line.tax_exemption_reason
          }
        ]
      },
      classifications:
        Enum.reject([{"PTC", line.tariff_code}, {"CLASS", line.classification_code}], fn {_, code} ->
          is_nil(code)
        end),
      description: line.description,
      origin_country: line.origin_country_code,
      unit_price: line.unit_price,
      subtotal: line.subtotal
    }
  end

  defp discount_or_charge(charge?, reason, amount) do
    if Decimal.gt?(amount, 0), do: %{charge?: charge?, reason: reason, amount: amount}
  end

  defp sum(lines, field),
    do: Enum.reduce(lines, Decimal.new("0.00"), &Decimal.add(Map.fetch!(&1, field), &2))
end
