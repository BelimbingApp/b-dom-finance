defmodule Bilimbi.Finance.Einvoice.MyInvois.ClientTest do
  # The contribution registry snapshot and the token cache are node-global.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.Configuration
  alias Bilimbi.Finance.Einvoice.MyInvois.{Client, TokenCache}
  alias Bilimbi.Finance.Einvoice.TestFixtures
  alias Ecto.Adapters.SQL

  @host "preprod-api.myinvois.hasil.gov.my"

  setup do
    context = TestFixtures.setup_einvoice!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, TestFixtures.capabilities())
    :ok = TestFixtures.put_credentials!(context.first_scope, 73)
    TokenCache.delete({73, "sandbox", "test-client-id"})
    on_exit(fn -> TokenCache.delete({73, "sandbox", "test-client-id"}) end)

    credentials = Configuration.credentials(context.first_scope, 73)
    Map.merge(context, %{operator: operator, credentials: credentials})
  end

  # Answers like the authority and tells the test what each request carried.
  defp stub(responses) do
    test = self()

    Req.Test.stub(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn.method, conn.host, conn.request_path, conn.query_string, body,
                  Plug.Conn.get_req_header(conn, "authorization")})

      case Map.fetch(responses, {conn.method, conn.request_path}) do
        {:ok, respond} -> respond.(conn)
        :error -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end
    end)
  end

  defp token(conn),
    do: Req.Test.json(conn, %{access_token: "stub-token", expires_in: 3600, token_type: "Bearer"})

  test "logs in once and reuses the token until it nears expiry", %{operator: op} = context do
    stub(%{
      {"POST", "/connect/token"} => &token/1,
      {"GET", "/api/v1.0/documents/F9D425P6DS7D8IU/details"} =>
        &Req.Test.json(&1, %{uuid: "F9D425P6DS7D8IU", status: "Valid", longId: "LIJAF97HJJKH"})
    })

    for _ <- 1..2 do
      assert {:ok, %{status: 200, body: %{"status" => "Valid", "longId" => "LIJAF97HJJKH"}}} =
               Client.document_details(op, 73, context.credentials, "F9D425P6DS7D8IU")
    end

    assert_received {:request, "POST", @host, "/connect/token", "", form, []}

    assert URI.decode_query(form) == %{
             "client_id" => "test-client-id",
             "client_secret" => "test-client-secret",
             "grant_type" => "client_credentials",
             "scope" => "InvoicingAPI"
           }

    assert_received {:request, "GET", @host, "/api/v1.0/documents/F9D425P6DS7D8IU/details", _,
                     _, ["Bearer stub-token"]}

    assert_received {:request, "GET", _, "/api/v1.0/documents/F9D425P6DS7D8IU/details", _, _, _}
    refute_received {:request, "POST", _, "/connect/token", _, _, _}
  end

  test "submits each document base64-encoded with its SHA-256", %{operator: op} = context do
    stub(%{
      {"POST", "/connect/token"} => &token/1,
      {"POST", "/api/v1.0/documentsubmissions/"} => fn conn ->
        conn
        |> Plug.Conn.put_status(202)
        |> Req.Test.json(%{
          submissionUid: "HJSD135P2S7D8IU",
          acceptedDocuments: [%{uuid: "F9D425P6DS7D8IU", invoiceCodeNumber: "INV-1"}],
          rejectedDocuments: []
        })
      end
    })

    bytes = ~s({"Invoice":[{"ID":[{"_":"INV-1"}]}]})

    assert {:ok, %{status: 202, body: %{"submissionUid" => "HJSD135P2S7D8IU"}}} =
             Client.submit(op, 73, context.credentials, [
               %{format: "JSON", document: bytes, code_number: "INV-1"}
             ])

    assert_received {:request, "POST", _, "/api/v1.0/documentsubmissions/", _, body, _}

    assert %{"documents" => [document]} = Jason.decode!(body)

    assert document == %{
             "format" => "JSON",
             "document" => Base.encode64(bytes),
             "documentHash" => :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
             "codeNumber" => "INV-1"
           }
  end

  test "reads a submission's status a page at a time", %{operator: op} = context do
    stub(%{
      {"POST", "/connect/token"} => &token/1,
      {"GET", "/api/v1.0/documentsubmissions/HJSD135P2S7D8IU"} =>
        &Req.Test.json(&1, %{overallStatus: "in progress", documentSummary: []})
    })

    assert {:ok, %{body: %{"overallStatus" => "in progress"}}} =
             Client.submission_status(op, 73, context.credentials, "HJSD135P2S7D8IU", page: 2)

    assert_received {:request, "GET", _, "/api/v1.0/documentsubmissions/HJSD135P2S7D8IU",
                     "pageNo=2&pageSize=100", _, _}
  end

  test "cancels with a reason, and validates a TIN with one identification",
       %{operator: op} = context do
    stub(%{
      {"POST", "/connect/token"} => &token/1,
      {"PUT", "/api/v1.0/documents/state/F9D425P6DS7D8IU/state"} =>
        &Req.Test.json(&1, %{uuid: "F9D425P6DS7D8IU", status: "Cancelled"}),
      {"GET", "/api/v1.0/taxpayer/validate/C29702635060"} => &Req.Test.json(&1, %{})
    })

    assert {:ok, %{body: %{"status" => "Cancelled"}}} =
             Client.cancel_document(op, 73, context.credentials, "F9D425P6DS7D8IU", "Wrong buyer")

    assert_received {:request, "PUT", _, _, _, body, _}
    assert Jason.decode!(body) == %{"status" => "cancelled", "reason" => "Wrong buyer"}

    assert {:ok, %{status: 200}} =
             Client.validate_tax_id(op, 73, context.credentials, "C29702635060", "BRN", "D12345678")

    assert_received {:request, "GET", _, "/api/v1.0/taxpayer/validate/C29702635060",
                     "idType=BRN&idValue=D12345678", _, _}

    assert {:error, :invalid_reason} =
             Client.cancel_document(op, 73, context.credentials, "F9D425P6DS7D8IU", "")

    assert {:error, :invalid_id_type} =
             Client.validate_tax_id(op, 73, context.credentials, "C29702635060", "X", "1")

    assert {:error, :invalid_identifier} =
             Client.document_details(op, 73, context.credentials, "../tokens")
  end

  test "carries Retry-After on a duplicate or rate-limited request", %{operator: op} = context do
    stub(%{
      {"POST", "/connect/token"} => &token/1,
      {"POST", "/api/v1.0/documentsubmissions/"} => fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "600")
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{error: %{code: "DuplicateSubmission"}})
      end,
      {"GET", "/api/v1.0/documentsubmissions/HJSD135P2S7D8IU"} => fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "4")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{})
      end
    })

    document = %{format: "JSON", document: "{}", code_number: "INV-1"}

    assert {:error, {:retry_after, 600, 422, %{"error" => %{"code" => "DuplicateSubmission"}}}} =
             Client.submit(op, 73, context.credentials, [document])

    assert {:error, {:retry_after, 4, 429, _}} =
             Client.submission_status(op, 73, context.credentials, "HJSD135P2S7D8IU")
  end

  test "a refused token is dropped and fetched afresh next time", %{operator: op} = context do
    stub(%{
      {"POST", "/connect/token"} => &token/1,
      {"GET", "/api/v1.0/documents/F9D425P6DS7D8IU/details"} =>
        &(&1 |> Plug.Conn.put_status(401) |> Req.Test.json(%{}))
    })

    assert {:error, {:http, 401, _}} =
             Client.document_details(op, 73, context.credentials, "F9D425P6DS7D8IU")

    assert :error = TokenCache.fetch({73, "sandbox", "test-client-id"})
  end

  test "refuses to call without credentials, and reports transport failures",
       %{operator: op} = context do
    assert {:error, :missing_credentials} =
             Client.login(op, 73, %{context.credentials | client_secret: nil})

    Req.Test.stub(Client, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, {:transport, %Req.TransportError{reason: :econnrefused}}} =
             Client.login(op, 73, context.credentials)
  end

  test "records each exchange without its secrets or bodies", %{operator: op} = context do
    stub(%{{"POST", "/connect/token"} => &token/1})
    assert {:ok, _} = Client.login(op, 73, context.credentials)

    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT system, operation, host, path, person_id, request_body::text, response_body::text FROM base_integration_outbound_exchanges",
        []
      )

    assert [["myinvois", "token", @host, "/connect/token", 91, nil, nil]] = rows

    refute inspect(
             SQL.query!(Repo, "SELECT * FROM base_integration_outbound_exchanges", []).rows
           ) =~ ~r/test-client-secret|stub-token/
  end

  describe "test connection" do
    test "logs in and records the outcome as an audit action", %{operator: op} do
      stub(%{{"POST", "/connect/token"} => &token/1})
      assert :ok = Einvoice.test_connection(op, 73)

      Req.Test.stub(Client, &(&1 |> Plug.Conn.put_status(400) |> Req.Test.json(%{error: "invalid_client"})))
      assert {:error, {:http, 400, %{"error" => "invalid_client"}}} = Einvoice.test_connection(op, 73)

      assert [
               [%{"environment" => "sandbox", "outcome" => "succeeded"}],
               [%{"environment" => "sandbox", "outcome" => "refused_400"}]
             ] =
               Bilimbi.Base.Audit.TestFixtures.action_payloads("finance.einvoice.connection.tested")
    end

    test "needs the settings capability", %{first_scope: scope} do
      viewer = TestFixtures.sign_in!(scope, 73, 92, ["finance.einvoice.view"])
      assert {:error, :unauthorized} = Einvoice.test_connection(viewer, 73)
    end
  end
end
