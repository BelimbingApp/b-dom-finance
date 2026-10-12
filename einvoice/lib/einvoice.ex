defmodule Bilimbi.Finance.Einvoice do
  @moduledoc """
  A company's fiscal documents, cleared by a tax authority: what it issued,
  what it submitted, and every answer the authority gave.

  Every function takes the validated `Bilimbi.Base.Tenancy.Scope` it was
  handed and an explicit company ID, and authorizes its capability for the
  scope's signed-in actor and the target company when it runs, through
  `Bilimbi.Core.Company.authorize_company_target/3`: a system scope, a
  missing grant, or a sibling company without tenant-wide reach is
  `{:error, :unauthorized}`, and a company the scope cannot see is
  `{:error, :company_not_found}`. A write holds
  `Bilimbi.Core.Company.lock_writable_company/2` for its transaction, so an
  archived company is `{:error, :company_archived}`.

  `issue_document/3` takes plain attributes, so a form, an import, an agent
  operation, and later receivables all issue through it. It derives every
  amount from the lines, checks the document against the authority's rules
  and the company's code lists, and records it with its lines, its supplier
  and buyer as they stood, and an `issued` status event. A recorded
  document is never edited or deleted: the database refuses it (see the
  migration), and a cancellation, a rejection, or any other answer from the
  authority is a new status event.

  Results are plain maps; the schemas stay private to this module.
  """

  import Ecto.Query

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Einvoice.Certificate
  alias Bilimbi.Finance.Einvoice.CodeLists
  alias Bilimbi.Finance.Einvoice.Configuration
  alias Bilimbi.Finance.Einvoice.{Document, Draft, Line, StatusEvent}
  alias Bilimbi.Finance.Einvoice.MyInvois.Client
  alias Ecto.Changeset

  @view "finance.einvoice.view"
  @issue "finance.einvoice.documents.issue"
  @settings "finance.einvoice.settings.manage"

  # The one authority this release clears documents with; see `Authority`.
  @authority Bilimbi.Finance.Einvoice.MyInvois

  @default_limit 50
  @max_limit 200
  @max_bigint 9_223_372_036_854_775_807

  # Events that move a document's status; any other event records an
  # answer without changing it.
  @status_events ~w(issued submitted refused valid invalid cancelled rejected)

  @type refusal :: :unauthorized | :company_not_found
  @type write_refusal :: refusal() | :company_archived

  @doc "The capability every read asks for."
  def view_capability, do: @view

  @doc "The capability that issues documents."
  def issue_capability, do: @issue

  @doc "The capability that manages the company's e-invoicing settings and code overrides."
  def settings_capability, do: @settings

  ## Documents

  @doc """
  Issues a document from plain attributes:

    * `document_type` (the authority's code; `01` for an invoice) and
      `code_number`, the company's own number for it, unique per environment;
    * optionally `issued_at` (UTC, not in the future; default now);
    * `currency_code` and, for a currency other than the authority's,
      `exchange_rate`;
    * `buyer`: `name`, `tax_id`, `registration_type` and
      `registration_number`, optional `sales_tax_registration`, `email`,
      `phone`, and `address` (`lines`, `city`, `postcode`, `state_code`,
      `country_code`);
    * optionally `payment_means_code`, `payment_terms`, and a billing period
      (`billing_period_start`, `billing_period_end`,
      `billing_period_description`);
    * `lines`, each with `description`, `classification_code`, `quantity`,
      `unit_price`, `tax_type`, and optionally `unit_code`, `tax_rate`,
      `discount_amount`, `charge_amount`, `tax_exemption_reason`,
      `tariff_code`, and `origin_country_code`.

  The supplier comes from the company's e-invoicing settings and the
  environment from its current setting. Amounts are derived, never taken:
  a line's subtotal is quantity times unit price, less its discount plus
  its charge, and its tax is that times the rate, each rounded half up to
  two places. Refusals are a changeset; `{:error, :code_number_taken}` when
  the company already issued that number in the environment.
  """
  @spec issue_document(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :code_number_taken | Changeset.t()}
  def issue_document(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @issue, fn company ->
      %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} =
        Scope.actor(scope)

      supplier = Configuration.supplier(scope, company_id, company.display_name)
      codes = code_lookup(scope, company_id)

      changeset =
        attributes
        |> Draft.changeset(DateTime.utc_now())
        |> validate_with_authority(supplier, codes)

      with {:ok, draft} <- Changeset.apply_action(changeset, :insert),
           :ok <- unused_code_number(scope, company_id, environment(scope, company_id), draft) do
        document =
          Repo.insert!(%Document{
            tenant_id: Scope.tenant_id(scope),
            company_id: company_id,
            authority: @authority.id(),
            environment: environment(scope, company_id),
            document_type: draft.document_type,
            code_number: draft.code_number,
            issued_at: draft.issued_at,
            currency_code: draft.currency_code,
            exchange_rate: draft.exchange_rate,
            supplier: supplier_snapshot(supplier),
            buyer: party_snapshot(draft.buyer),
            details: details(draft),
            line_extension_amount: draft.line_extension_amount,
            tax_exclusive_amount: draft.line_extension_amount,
            tax_amount: draft.tax_amount,
            tax_inclusive_amount: Decimal.add(draft.line_extension_amount, draft.tax_amount),
            payable_amount: Decimal.add(draft.line_extension_amount, draft.tax_amount),
            issued_by_user_id: user_id,
            issued_by_impersonator_id: impersonator_id
          })

        insert_lines(document, draft.lines)

        Repo.insert!(%StatusEvent{
          tenant_id: document.tenant_id,
          company_id: company_id,
          document_id: document.id,
          event: "issued",
          actor_type: "user",
          actor_user_id: user_id,
          actor_impersonator_id: impersonator_id
        })

        view = document_view(fetch_document(scope, company_id, document.id))

        record_action(scope, company_id, "finance.einvoice.document.issued", %{
          "document_id" => view.id,
          "document_type" => view.document_type,
          "code_number" => view.code_number,
          "environment" => view.environment
        })

        {:ok, view}
      end
    end)
  end

  @doc """
  One document with its lines, its status events in order, and its current
  `status`: the latest status-moving event (`issued`, `submitted`,
  `refused`, `valid`, `invalid`, `cancelled`, or `rejected`).
  """
  @spec get_document(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :document_not_found}
  def get_document(%Scope{} = scope, company_id, document_id) do
    with :ok <- authorize(scope, company_id, @view) do
      case fetch_document(scope, company_id, document_id) do
        nil -> {:error, :document_not_found}
        document -> {:ok, document_view(document)}
      end
    end
  end

  @doc """
  The company's documents, newest first, without lines or events. Options:
  `limit` (1 to #{@max_limit}, default #{@default_limit}) and `before`, the
  ID of the last document already read. A malformed option is
  `{:error, :invalid_option}`.
  """
  @spec list_documents(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_documents(%Scope{} = scope, company_id, options \\ []) when is_list(options) do
    limit = Keyword.get(options, :limit, @default_limit)
    before = Keyword.get(options, :before)

    with :ok <- authorize(scope, company_id, @view),
         true <-
           (is_integer(limit) and limit in 1..@max_limit and
              (is_nil(before) or (is_integer(before) and before in 1..@max_bigint))) ||
             {:error, :invalid_option} do
      documents =
        scope
        |> documents_query(company_id)
        |> then(fn query -> if before, do: where(query, [d], d.id < ^before), else: query end)
        |> order_by([d], desc: d.id)
        |> limit(^limit)
        |> Repo.all()

      statuses = statuses(scope, company_id, Enum.map(documents, & &1.id))
      {:ok, Enum.map(documents, &summary_view(&1, Map.get(statuses, &1.id)))}
    end
  end

  ## Code lists

  @doc "The company's active codes in one of the authority's lists, code to description."
  @spec list_codes(Scope.t(), term(), String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, refusal() | :unknown_list}
  def list_codes(%Scope{} = scope, company_id, list) do
    with :ok <- authorize(scope, company_id, @view) do
      if list in CodeLists.lists(@authority.id()),
        do: {:ok, CodeLists.codes(scope, company_id, @authority.id(), list)},
        else: {:error, :unknown_list}
    end
  end

  @doc """
  Overrides one code for the company: `description` renames it, or names a
  code the shipped list lacks, and `active: false` retires it.
  """
  @spec override_code(Scope.t(), term(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :unknown_list | Changeset.t()}
  def override_code(%Scope{} = scope, company_id, list, code, attributes)
      when is_binary(list) and is_binary(code) and is_map(attributes) do
    write(scope, company_id, @settings, fn _company ->
      CodeLists.put_override(scope, company_id, @authority.id(), list, code, attributes)
    end)
  end

  ## Setup

  @doc """
  What the company has configured, without any secret: the environment,
  which credentials are present, the client secret's expiry, the
  certificate's issuer, serial, subject numbers and validity, whether the
  private key matches it, and the supplier profile's missing fields.
  `expiring` lists what expires within the alert window (or already has):
  `:certificate` and `:client_secret`.
  """
  @spec setup(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, refusal()}
  def setup(%Scope{} = scope, company_id, now \\ DateTime.utc_now()) do
    with {:ok, company} <- authorize_company(scope, company_id, @settings) do
      credentials = Configuration.credentials(scope, company_id)
      supplier = Configuration.supplier(scope, company_id, company.display_name)
      certificate = certificate_summary(credentials, now)
      alert_days = credentials.expiry_alert_days

      secret_days =
        credentials.secret_expires_on &&
          Date.diff(credentials.secret_expires_on, DateTime.to_date(now))

      expiring =
        Enum.reject(
          [
            certificate[:days_until_expiry] && certificate.days_until_expiry <= alert_days &&
              :certificate,
            secret_days && secret_days <= alert_days && :client_secret
          ],
          &(&1 in [nil, false])
        )

      {:ok,
       %{
         environment: credentials.environment,
         client_id?: not is_nil(credentials.client_id),
         client_secret?: not is_nil(credentials.client_secret),
         client_secret_expires_on: credentials.secret_expires_on,
         certificate: certificate,
         expiry_alert_days: alert_days,
         expiring: expiring,
         supplier_missing: supplier_missing(supplier),
         tax_id_matches_certificate?:
           not is_nil(supplier.tax_id) and is_map(certificate) and
             certificate[:organization_identifier] == supplier.tax_id
       }}
    end
  end

  @doc """
  Logs in to the authority with the company's current environment and
  credentials, and records the outcome as the audit action
  `finance.einvoice.connection.tested`. `:ok`, or `{:error, reason}` where
  `reason` is `:missing_credentials`, `{:http, status, body}`, or
  `{:transport, exception}`.
  """
  @spec test_connection(Scope.t(), term()) :: :ok | {:error, term()}
  def test_connection(%Scope{} = scope, company_id) do
    with {:ok, _company} <- authorize_company(scope, company_id, @settings) do
      credentials = Configuration.credentials(scope, company_id)

      outcome =
        case Client.login(scope, company_id, credentials) do
          {:ok, _token} -> :ok
          {:error, reason} -> {:error, reason}
        end

      record_action(scope, company_id, "finance.einvoice.connection.tested", %{
        "environment" => credentials.environment,
        "outcome" => outcome_name(outcome)
      })

      outcome
    end
  end

  defp outcome_name(:ok), do: "succeeded"
  defp outcome_name({:error, :missing_credentials}), do: "missing_credentials"
  defp outcome_name({:error, {:http, status, _body}}), do: "refused_#{status}"
  defp outcome_name({:error, {:retry_after, _seconds, status, _body}}), do: "refused_#{status}"
  defp outcome_name({:error, {:transport, _exception}}), do: "unreachable"
  defp outcome_name({:error, _reason}), do: "failed"

  ## Authorization and writes

  defp authorize(scope, company_id, capability) do
    with {:ok, _company} <- authorize_company(scope, company_id, capability), do: :ok
  end

  # The actor's current grant and company reach decide every call.
  defp authorize_company(scope, company_id, capability) do
    case Company.authorize_company_target(scope, company_id, capability) do
      {:ok, _company} ->
        case Company.identity(scope, company_id) do
          {:ok, identity} -> {:ok, identity}
          {:error, :not_found} -> {:error, :company_not_found}
        end

      {:error, :not_found} ->
        {:error, :company_not_found}

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  defp write(scope, company_id, capability, fun) do
    with {:ok, company} <- authorize_company(scope, company_id, capability) do
      Repo.transact(fn ->
        case Company.lock_writable_company(scope, company_id) do
          {:ok, _proof} -> fun.(company)
          {:error, :not_found} -> {:error, :company_not_found}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  defp record_action(scope, company_id, event, payload) do
    actor = Scope.actor(scope)

    {:ok, _action} =
      Audit.record_action(scope, %{
        event: event,
        occurred_at: NaiveDateTime.utc_now(),
        actor_type: "user",
        actor_id: actor.user_id,
        impersonator_id: actor.impersonator_id,
        system_principal: nil,
        company_id: company_id,
        payload: payload
      })

    :ok
  end

  ## Issuing

  defp environment(scope, company_id), do: Configuration.environment(scope, company_id)

  # Every list once per issue, so each rule reads the same snapshot.
  defp code_lookup(scope, company_id) do
    codes = CodeLists.all_codes(scope, company_id, @authority.id())
    &Map.fetch!(codes, &1)
  end

  defp validate_with_authority(%{valid?: false} = changeset, _supplier, _codes), do: changeset

  defp validate_with_authority(changeset, supplier, codes),
    do: @authority.validate(changeset, supplier, codes)

  defp unused_code_number(scope, company_id, environment, draft) do
    taken? =
      scope
      |> documents_query(company_id)
      |> where([d], d.environment == ^environment and d.code_number == ^draft.code_number)
      |> Repo.exists?()

    if taken?, do: {:error, :code_number_taken}, else: :ok
  end

  defp insert_lines(document, lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.each(fn {line, number} ->
      Repo.insert!(%Line{
        tenant_id: document.tenant_id,
        company_id: document.company_id,
        document_id: document.id,
        line_number: number,
        description: line.description,
        classification_code: line.classification_code,
        tariff_code: line.tariff_code,
        origin_country_code: line.origin_country_code,
        quantity: line.quantity,
        unit_code: line.unit_code,
        unit_price: line.unit_price,
        subtotal: line.subtotal,
        discount_amount: line.discount_amount,
        charge_amount: line.charge_amount,
        line_extension_amount: line.line_extension_amount,
        tax_type: line.tax_type,
        tax_rate: line.tax_rate,
        tax_amount: line.tax_amount,
        tax_exemption_reason: line.tax_exemption_reason
      })
    end)
  end

  defp supplier_snapshot(supplier) do
    %{
      "name" => supplier.name,
      "tax_id" => supplier.tax_id,
      "registration_number" => supplier.registration_number,
      "sales_tax_registration" => supplier.sales_tax_registration,
      "tourism_tax_registration" => supplier.tourism_tax_registration,
      "industry_code" => supplier.industry_code,
      "business_activity" => supplier.business_activity,
      "phone" => supplier.phone,
      "email" => supplier.email,
      "address" => %{
        "lines" =>
          Enum.reject(
            [supplier.address_line1, supplier.address_line2, supplier.address_line3],
            &is_nil/1
          ),
        "city" => supplier.city,
        "postcode" => supplier.postcode,
        "state_code" => supplier.state_code,
        "country_code" => supplier.country_code
      }
    }
  end

  defp party_snapshot(party) do
    %{
      "name" => party.name,
      "tax_id" => party.tax_id,
      "registration_type" => party.registration_type,
      "registration_number" => party.registration_number,
      "sales_tax_registration" => party.sales_tax_registration,
      "email" => party.email,
      "phone" => party.phone,
      "address" => %{
        "lines" => party.address.lines,
        "city" => party.address.city,
        "postcode" => party.address.postcode,
        "state_code" => party.address.state_code,
        "country_code" => party.address.country_code
      }
    }
  end

  defp details(draft) do
    %{
      "payment_means_code" => draft.payment_means_code,
      "payment_terms" => draft.payment_terms,
      "billing_period_start" => draft.billing_period_start && Date.to_iso8601(draft.billing_period_start),
      "billing_period_end" => draft.billing_period_end && Date.to_iso8601(draft.billing_period_end),
      "billing_period_description" => draft.billing_period_description
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  ## Setup

  defp certificate_summary(%{certificate_pem: nil}, _now), do: nil

  defp certificate_summary(credentials, now) do
    case Certificate.parse(credentials.certificate_pem) do
      {:ok, certificate} ->
        key_matches? =
          case Certificate.private_key(credentials.private_key_pem) do
            {:ok, key} -> Certificate.key_matches?(certificate, key)
            {:error, _} -> false
          end

        %{
          issuer_name: certificate.issuer_name,
          subject_name: certificate.subject_name,
          serial_number: certificate.serial_number,
          organization_identifier: certificate.subject["organization_identifier"],
          registration_number: certificate.subject["serial_number"],
          not_before: certificate.not_before,
          not_after: certificate.not_after,
          days_until_expiry: Certificate.days_until_expiry(certificate, now),
          private_key_matches?: key_matches?
        }

      {:error, :invalid_certificate} ->
        %{invalid?: true}
    end
  end

  defp supplier_missing(supplier) do
    for field <- [
          :tax_id,
          :registration_number,
          :industry_code,
          :business_activity,
          :phone,
          :address_line1,
          :city,
          :state_code,
          :country_code
        ],
        is_nil(supplier[field]),
        do: field
  end

  ## Queries

  defp documents_query(scope, company_id) do
    from(d in Tenancy.scope_query(Document, scope), where: d.company_id == ^company_id)
  end

  defp fetch_document(scope, company_id, document_id) when is_integer(document_id) do
    lines = order_by(Tenancy.scope_query(Line, scope), [l], asc: l.line_number)

    scope
    |> documents_query(company_id)
    |> where([d], d.id == ^document_id)
    |> preload(lines: ^lines)
    |> Repo.one()
    |> case do
      nil -> nil
      document -> {document, events(scope, company_id, document.id)}
    end
  end

  defp fetch_document(_scope, _company_id, _document_id), do: nil

  defp events(scope, company_id, document_id) do
    from(e in Tenancy.scope_query(StatusEvent, scope),
      where: e.company_id == ^company_id and e.document_id == ^document_id,
      order_by: [asc: e.sequence]
    )
    |> Repo.all()
  end

  defp statuses(_scope, _company_id, []), do: %{}

  defp statuses(scope, company_id, document_ids) do
    from(e in Tenancy.scope_query(StatusEvent, scope),
      where:
        e.company_id == ^company_id and e.document_id in ^document_ids and
          e.event in ^@status_events,
      distinct: e.document_id,
      order_by: [asc: e.document_id, desc: e.sequence],
      select: {e.document_id, e.event}
    )
    |> Repo.all()
    |> Map.new()
  end

  ## Views

  @summary_fields [
    :id,
    :authority,
    :environment,
    :document_type,
    :code_number,
    :issued_at,
    :currency_code,
    :exchange_rate,
    :line_extension_amount,
    :tax_exclusive_amount,
    :tax_amount,
    :tax_inclusive_amount,
    :payable_amount,
    :original_document_id,
    :issued_by_user_id,
    :issued_by_impersonator_id,
    :recorded_at
  ]

  defp summary_view(document, status) do
    document
    |> Map.take(@summary_fields)
    |> Map.put(:buyer_name, document.buyer["name"])
    |> Map.put(:status, status)
  end

  defp document_view({document, events}) do
    status =
      events
      |> Enum.filter(&(&1.event in @status_events))
      |> List.last()

    document
    |> Map.take(@summary_fields ++ [:supplier, :buyer, :details])
    |> Map.put(:status, status && status.event)
    |> Map.put(
      :lines,
      Enum.map(
        document.lines,
        &Map.take(&1, [
          :line_number,
          :description,
          :classification_code,
          :tariff_code,
          :origin_country_code,
          :quantity,
          :unit_code,
          :unit_price,
          :subtotal,
          :discount_amount,
          :charge_amount,
          :line_extension_amount,
          :tax_type,
          :tax_rate,
          :tax_amount,
          :tax_exemption_reason
        ])
      )
    )
    |> Map.put(
      :events,
      Enum.map(
        events,
        &Map.take(&1, [
          :sequence,
          :event,
          :submission_id,
          :authority_status,
          :submission_uid,
          :document_uuid,
          :long_id,
          :reason,
          :http_status,
          :response,
          :actor_type,
          :actor_user_id,
          :actor_impersonator_id,
          :system_principal,
          :recorded_at
        ])
      )
    )
  end
end
