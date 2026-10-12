defmodule Bilimbi.Finance.Einvoice.MyInvois.Client do
  @moduledoc """
  The MyInvois e-invoicing API, through `Bilimbi.Base.Integration`.

  Every call goes out through `Integration.request/3` with the caller's
  scope, so each exchange is recorded and redacted under the person it acts
  for; bodies and headers are not retained. A call takes the company's
  `credentials` (`Configuration.credentials/2`): the environment, the
  client ID and secret, and nothing else.

  Logging in (`POST /connect/token`, client credentials, scope
  `InvoicingAPI`) yields a token that lives an hour; `TokenCache` keeps it
  per company, environment, and client ID, and a 401 drops it. The other
  calls are the API's own: submit documents, read a submission's status,
  read a document's details, cancel a document, and validate a taxpayer's
  TIN.

  Results keep the authority's answer intact so a caller can store it as
  the record: `{:ok, %{status: http_status, body: decoded_body}}` for a 2xx
  answer and `{:error, reason}` otherwise, where a refusal the authority
  explains is `{:error, {:http, status, body}}`, a rate limit or duplicate
  submission carries the `Retry-After` seconds as
  `{:error, {:retry_after, seconds, status, body}}`, and a transport
  failure is `{:error, {:transport, exception}}`. Nothing here retries:
  resubmitting after a 2xx is never safe, so retries belong to the caller
  that recorded the submission first.

  The API's base URL per environment is a platform setting
  (`finance.einvoice.<environment>.api_url`), defaulting to the hosts the
  SDK documents.
  """

  alias Bilimbi.Base.Integration
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Einvoice.MyInvois.TokenCache

  @system "myinvois"
  @owner_type "finance/einvoice"
  @default_urls %{
    "sandbox" => "https://preprod-api.myinvois.hasil.gov.my",
    "production" => "https://api.myinvois.hasil.gov.my"
  }

  @type credentials :: %{
          required(:environment) => String.t(),
          required(:client_id) => String.t() | nil,
          required(:client_secret) => String.t() | nil,
          optional(atom()) => term()
        }
  @type result :: {:ok, %{status: pos_integer(), body: term()}} | {:error, term()}

  @doc "Platform settings for the API's base URL in each environment."
  @spec settings_definitions() :: %{String.t() => map()}
  def settings_definitions do
    Map.new(@default_urls, fn {environment, url} ->
      {"finance.einvoice.#{environment}.api_url",
       %{
         type: :string,
         scopes: [:global],
         default: url,
         label: "E-invoice #{environment} API URL",
         help:
           "Base URL of the MyInvois #{environment} API. Change it only when the authority publishes a new host.",
         editable: "operator",
         capability: "base.settings.global.manage",
         validator: {__MODULE__, :valid_url?, "must be an https URL without a path"}
       }}
    end)
  end

  @doc false
  def valid_url?(value) do
    match?(
      %URI{scheme: "https", host: host, path: path}
      when is_binary(host) and path in [nil, "", "/"],
      URI.parse(value)
    )
  end

  @doc """
  Logs in afresh, bypassing and then refreshing the token cache: the
  "Test connection" check.
  """
  @spec login(Scope.t(), pos_integer(), credentials()) :: result()
  def login(%Scope{} = scope, company_id, credentials) do
    with :ok <- complete(credentials) do
      TokenCache.delete(cache_key(company_id, credentials))
      fetch_token(scope, company_id, credentials)
    end
  end

  @doc """
  Submits signed documents: each `%{format: "JSON", document: bytes,
  code_number: code}`. The document is sent base64-encoded with the hex
  SHA-256 of its bytes. The authority answers 202 with a `submissionUid`
  and its accepted and rejected documents.
  """
  @spec submit(Scope.t(), pos_integer(), credentials(), [map()], keyword()) :: result()
  def submit(%Scope{} = scope, company_id, credentials, documents, options \\ []) do
    body = %{
      documents:
        Enum.map(documents, fn document ->
          %{
            format: document.format,
            document: Base.encode64(document.document),
            documentHash:
              :sha256 |> :crypto.hash(document.document) |> Base.encode16(case: :lower),
            codeNumber: document.code_number
          }
        end)
    }

    authorized(scope, company_id, credentials, "documents.submit", options,
      method: :post,
      url: "/api/v1.0/documentsubmissions/",
      json: body
    )
  end

  @doc "A submission's overall status and its documents' summaries, one page at a time."
  @spec submission_status(Scope.t(), pos_integer(), credentials(), String.t(), keyword()) ::
          result()
  def submission_status(%Scope{} = scope, company_id, credentials, submission_uid, options \\ []) do
    with {:ok, uid} <- path_segment(submission_uid) do
      authorized(scope, company_id, credentials, "submissions.status", options,
        method: :get,
        url: "/api/v1.0/documentsubmissions/#{uid}",
        params: [
          pageNo: Keyword.get(options, :page, 1),
          pageSize: Keyword.get(options, :page_size, 100)
        ]
      )
    end
  end

  @doc "A document's details, including its validation results and `longId`."
  @spec document_details(Scope.t(), pos_integer(), credentials(), String.t(), keyword()) ::
          result()
  def document_details(%Scope{} = scope, company_id, credentials, uuid, options \\ []) do
    with {:ok, uuid} <- path_segment(uuid) do
      authorized(scope, company_id, credentials, "documents.details", options,
        method: :get,
        url: "/api/v1.0/documents/#{uuid}/details"
      )
    end
  end

  @doc "Cancels an issued document with a reason of at most 300 characters."
  @spec cancel_document(
          Scope.t(),
          pos_integer(),
          credentials(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          result()
  def cancel_document(%Scope{} = scope, company_id, credentials, uuid, reason, options \\ []) do
    with {:ok, uuid} <- path_segment(uuid),
         :ok <- reason(reason) do
      authorized(scope, company_id, credentials, "documents.cancel", options,
        method: :put,
        url: "/api/v1.0/documents/state/#{uuid}/state",
        json: %{status: "cancelled", reason: reason}
      )
    end
  end

  @doc """
  Validates a taxpayer's TIN together with one identification:
  `id_type` is `"NRIC"`, `"PASSPORT"`, `"BRN"`, or `"ARMY"`. The authority
  answers 200 when they match and 404 when they do not.
  """
  @spec validate_tax_id(
          Scope.t(),
          pos_integer(),
          credentials(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: result()
  def validate_tax_id(
        %Scope{} = scope,
        company_id,
        credentials,
        tin,
        id_type,
        id_value,
        options \\ []
      ) do
    with {:ok, tin} <- path_segment(tin),
         true <- id_type in ["NRIC", "PASSPORT", "BRN", "ARMY"] || {:error, :invalid_id_type} do
      authorized(scope, company_id, credentials, "taxpayers.validate", options,
        method: :get,
        url: "/api/v1.0/taxpayer/validate/#{tin}",
        params: [idType: id_type, idValue: id_value]
      )
    end
  end

  ## Requests

  defp authorized(scope, company_id, credentials, operation, options, request) do
    with :ok <- complete(credentials),
         {:ok, token} <- token(scope, company_id, credentials) do
      case send_request(scope, company_id, credentials, operation, options, [
             {:auth, {:bearer, token}} | request
           ]) do
        {:error, {:http, 401, _body}} = refused ->
          TokenCache.delete(cache_key(company_id, credentials))
          refused

        result ->
          result
      end
    end
  end

  defp token(scope, company_id, credentials) do
    case TokenCache.fetch(cache_key(company_id, credentials)) do
      {:ok, token} ->
        {:ok, token}

      :error ->
        with {:ok, %{body: %{"access_token" => token}}} <-
               fetch_token(scope, company_id, credentials) do
          {:ok, token}
        end
    end
  end

  defp fetch_token(scope, company_id, credentials) do
    request = [
      method: :post,
      url: "/connect/token",
      form: [
        client_id: credentials.client_id,
        client_secret: credentials.client_secret,
        grant_type: "client_credentials",
        scope: "InvoicingAPI"
      ]
    ]

    case send_request(scope, company_id, credentials, "token", [], request) do
      {:ok, %{body: %{"access_token" => token, "expires_in" => expires_in}}} = result
      when is_binary(token) and is_integer(expires_in) and expires_in > 0 ->
        TokenCache.put(cache_key(company_id, credentials), token, expires_in)
        # The token goes to the caller that asked for it, never further.
        result

      {:ok, %{status: status}} ->
        {:error, {:unexpected_token_response, status}}

      error ->
        error
    end
  end

  defp send_request(scope, company_id, credentials, operation, options, request) do
    context = %{
      system: @system,
      operation: operation,
      owner_type: @owner_type,
      owner_id: Keyword.get(options, :owner_id, company_id)
    }

    # An absolute URL, not Req's base_url: Integration records the URL the
    # request carries before Req's steps would join a base onto it.
    request =
      request
      |> Keyword.update!(:url, &(api_url(credentials.environment) <> &1))
      |> Keyword.merge(Application.get_env(:bilimbi_finance_einvoice, :req_options, []))

    scope
    |> Integration.request(context, request)
    |> result()
  end

  defp result({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, %{status: status, body: body}}

  defp result({:ok, %{status: status, body: body} = response}) when status in [422, 429] do
    case retry_after(response) do
      nil -> {:error, {:http, status, body}}
      seconds -> {:error, {:retry_after, seconds, status, body}}
    end
  end

  defp result({:ok, %{status: status, body: body}}), do: {:error, {:http, status, body}}
  defp result({:error, exception}), do: {:error, {:transport, exception}}

  defp retry_after(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         {seconds, ""} when seconds >= 0 <- Integer.parse(String.trim(value)) do
      seconds
    else
      _other -> nil
    end
  end

  defp api_url(environment) do
    url =
      Settings.get("finance.einvoice.#{environment}.api_url") ||
        Map.fetch!(@default_urls, environment)

    String.trim_trailing(url, "/")
  end

  defp cache_key(company_id, credentials),
    do: {company_id, credentials.environment, credentials.client_id}

  defp complete(%{environment: environment, client_id: id, client_secret: secret})
       when is_map_key(@default_urls, environment) and is_binary(id) and id != "" and
              is_binary(secret) and secret != "",
       do: :ok

  defp complete(_credentials), do: {:error, :missing_credentials}

  # Identifiers the authority issued; anything else never reaches a URL path.
  defp path_segment(value) when is_binary(value) do
    if value =~ ~r/\A[A-Za-z0-9\-]{1,64}\z/, do: {:ok, value}, else: {:error, :invalid_identifier}
  end

  defp path_segment(_value), do: {:error, :invalid_identifier}

  defp reason(reason) when is_binary(reason) do
    if String.trim(reason) != "" and String.length(reason) <= 300,
      do: :ok,
      else: {:error, :invalid_reason}
  end

  defp reason(_reason), do: {:error, :invalid_reason}
end
