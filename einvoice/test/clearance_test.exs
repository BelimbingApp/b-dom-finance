defmodule Bilimbi.Finance.Einvoice.ClearanceTest do
  # The contribution registry snapshot and the token cache are node-global.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Queue.Execution
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.{Clearance, PollWorker, Submission, SubmitWorker, TestFixtures}
  alias Bilimbi.Finance.Einvoice.MyInvois.TokenCache
  alias Bilimbi.Finance.Ledger
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @submit_path "/api/v1.0/documentsubmissions/"
  @progress_path "/api/v1.0/documentsubmissions/HJSD135P2S7D8IU"
  @details_path "/api/v1.0/documents/F9D425P6DS7D8IU/details"
  @cancel_path "/api/v1.0/documents/state/F9D425P6DS7D8IU/state"
  @recent_path "/api/v1.0/documents/recent"

  setup do
    context = TestFixtures.setup_einvoice!()
    on_exit(&ContributionRegistry.clear_for_test!/0)

    operator =
      TestFixtures.sign_in!(
        context.first_scope,
        73,
        91,
        TestFixtures.capabilities() ++ TestFixtures.ledger_capabilities()
      )

    :ok = TestFixtures.put_supplier_profile!(context.first_scope, 73)
    :ok = TestFixtures.put_credentials!(context.first_scope, 73)
    :ok = TestFixtures.put_settings!(context.first_scope, 73, %{"document_version" => "1.0"})
    TokenCache.delete({73, "sandbox", "test-client-id"})
    on_exit(fn -> TokenCache.delete({73, "sandbox", "test-client-id"}) end)
    Application.put_env(:bilimbi_finance_einvoice, :poll_interval_ms, 0)
    on_exit(fn -> Application.delete_env(:bilimbi_finance_einvoice, :poll_interval_ms) end)

    {:ok, document} = Einvoice.issue_document(operator, 73, TestFixtures.invoice_attributes())
    Map.merge(context, %{operator: operator, document: document})
  end

  defp execution(scope),
    do: %Execution{job_id: 1, attempt: 1, max_attempts: 20, queue: "default", scope: scope}

  defp args(document), do: %{"company_id" => 73, "document_id" => document.id}

  defp events(operator, document) do
    {:ok, view} = Einvoice.get_document(operator, 73, document.id)
    Enum.map(view.events, &{&1.event, &1})
  end

  defp action_events(scope) do
    {:ok, actions} = Audit.list_actions(scope)
    Enum.map(actions, & &1.event)
  end

  defp duplicate_response(conn) do
    conn
    |> Plug.Conn.put_status(422)
    |> Plug.Conn.put_resp_header("retry-after", "300")
    |> Req.Test.json(%{error: %{code: "DuplicateSubmission", message: "Duplicate"}})
  end

  defp recent_response(conn, results) do
    Req.Test.json(conn, %{
      result: results,
      metadata: %{totalPages: 1, totalCount: length(results)}
    })
  end

  defp held_by_authority do
    [
      %{internalId: "OTHER-1", uuid: "OTHERUUID", submissionUid: "OTHERSUB"},
      %{
        internalId: "JSON-INV12345",
        uuid: "F9D425P6DS7D8IU",
        submissionUid: "HJSD135P2S7D8IU",
        status: "Submitted"
      }
    ]
  end

  defp drain_requests do
    receive do
      {:request, _method, _path, _body} -> drain_requests()
    after
      0 -> :ok
    end
  end

  defp query_instant(conn, key) do
    {:ok, instant, _offset} =
      conn
      |> Plug.Conn.fetch_query_params()
      |> Map.fetch!(:query_params)
      |> Map.fetch!(key)
      |> DateTime.from_iso8601()

    instant
  end

  defp stub_outage! do
    TestFixtures.stub_authority!(%{
      {"POST", "/connect/token"} => &TestFixtures.token_response/1,
      {"POST", @submit_path} => &Req.Test.transport_error(&1, :timeout),
      {"GET", @recent_path} => &recent_response(&1, [])
    })
  end

  describe "queuing a submission" do
    test "queues the submit job as the user and records the request", %{
      operator: op,
      document: document
    } do
      assert {:ok, %{job_id: job_id}} = Einvoice.submit_document(op, 73, document.id)

      job = Repo.get!(Oban.Job, job_id)
      assert job.args == %{"company_id" => 73, "document_id" => document.id}
      assert job.worker == "Bilimbi.Finance.Einvoice.SubmitWorker.ObanAdapter"
      # The actor rides in metadata the caller cannot write, never in the arguments.
      assert is_binary(job.meta["bilimbi_delegated_actor"])

      assert "finance.einvoice.submission.queued" in action_events(op)
    end

    test "refuses before queuing what the job could not do",
         %{operator: op, document: document} = context do
      :ok = TestFixtures.put_settings!(context.first_scope, 73, %{"sandbox.client_secret" => " "})
      assert {:error, :missing_credentials} = Einvoice.submit_document(op, 73, document.id)

      :ok = TestFixtures.put_credentials!(context.first_scope, 73)
      :ok = TestFixtures.put_settings!(context.first_scope, 73, %{"document_version" => "1.1"})
      assert {:error, :signing_key_required} = Einvoice.submit_document(op, 73, document.id)

      generated = TestFixtures.test_certificate!()

      :ok =
        TestFixtures.put_settings!(context.first_scope, 73, %{
          "certificate_pem" => generated.certificate_pem,
          "private_key_pem" => generated.private_key_pem
        })

      assert {:ok, _job} = Einvoice.submit_document(op, 73, document.id)
      assert {:error, :document_not_found} = Einvoice.submit_document(op, 73, document.id + 1000)
    end

    test "needs the submit capability", %{document: document} = context do
      viewer = TestFixtures.sign_in!(context.first_scope, 73, 92, ["finance.einvoice.view"])
      assert {:error, :unauthorized} = Einvoice.submit_document(viewer, 73, document.id)
      assert {:error, :unauthorized} = Einvoice.refresh_status(viewer, 73, document.id)
      assert {:error, :unauthorized} = Einvoice.cancel_document(viewer, 73, document.id, "x")
      assert {:cancel, :unauthorized} = SubmitWorker.handle_job(args(document), execution(viewer))
    end
  end

  describe "the submit job" do
    test "stores the bytes before calling, records the acceptance, and queues the poll", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &TestFixtures.accepted_response(&1, "JSON-INV12345")
      })

      assert :ok = SubmitWorker.handle_job(args(document), execution(op))

      assert_received {:request, "POST", @submit_path, %{"documents" => [sent]}}
      assert [submission] = Repo.all(Submission)
      assert submission.document_id == document.id
      assert submission.document_version == "1.0"
      assert submission.actor_type == "user" and submission.actor_user_id == 91
      assert Base.decode64!(sent["document"]) == submission.payload
      assert sent["documentHash"] == submission.payload_sha256
      refute submission.payload =~ "UBLExtensions"

      assert [{"issued", _}, {"submitted", submitted}] = events(op, document)

      assert %{
               submission_id: submission_id,
               authority_status: "Submitted",
               submission_uid: "HJSD135P2S7D8IU",
               document_uuid: "F9D425P6DS7D8IU",
               http_status: 202,
               actor_user_id: 91
             } = submitted

      assert submission_id == submission.id
      assert "finance.einvoice.submitted" in action_events(op)

      assert [job] = Repo.all(Oban.Job)
      assert job.worker == "Bilimbi.Finance.Einvoice.PollWorker.ObanAdapter"
      assert job.args == %{"company_id" => 73, "document_id" => document.id}

      assert {:ok, %{status: "submitted", submission_uid: "HJSD135P2S7D8IU"}} =
               Einvoice.get_document(op, 73, document.id)

      # A submitted document is never sent again, whatever queued the job.
      assert :ok = SubmitWorker.handle_job(args(document), execution(op))
      refute_received {:request, "POST", @submit_path, _}
      assert {:error, :not_submittable} = Einvoice.submit_document(op, 73, document.id)
    end

    test "records a document the authority listed as rejected as refused", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => fn conn ->
          conn
          |> Plug.Conn.put_status(202)
          |> Req.Test.json(%{
            submissionUid: "HJSD135P2S7D8IU",
            acceptedDocuments: [],
            rejectedDocuments: [
              %{
                invoiceCodeNumber: "JSON-INV12345",
                error: %{
                  code: "CF321",
                  message: "Document is invalid",
                  details: [%{message: "TIN mismatch"}]
                }
              }
            ]
          })
        end
      })

      assert :ok = SubmitWorker.handle_job(args(document), execution(op))

      assert [{"issued", _}, {"refused", refused}] = events(op, document)
      assert refused.reason == "Document is invalid; TIN mismatch"
      assert refused.submission_uid == "HJSD135P2S7D8IU"
      assert "finance.einvoice.refused" in action_events(op)
      assert Repo.all(Oban.Job) == []
      # A refused document can be submitted again once the cause is fixed.
      assert {:ok, _job} = Einvoice.submit_document(op, 73, document.id)
    end

    test "records a refusal the authority explained", %{operator: op, document: document} do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => fn conn ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{error: %{code: "BadArgument", message: "Bad structure"}})
        end
      })

      assert :ok = SubmitWorker.handle_job(args(document), execution(op))

      assert [{"issued", _}, {"refused", %{http_status: 400, reason: "Bad structure"}}] =
               events(op, document)
    end

    test "never resubmits after a duplicate: the job stops for an operator", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => fn conn ->
          conn
          |> Plug.Conn.put_status(422)
          |> Plug.Conn.put_resp_header("retry-after", "300")
          |> Req.Test.json(%{error: %{code: "DuplicateSubmission", message: "Duplicate"}})
        end,
        {"GET", @recent_path} => &recent_response(&1, [])
      })

      assert {:cancel, :duplicate_submission} =
               SubmitWorker.handle_job(args(document), execution(op))

      assert [{"issued", _}, {"duplicate", %{http_status: 422}}] = events(op, document)
      assert "finance.einvoice.submission.duplicate" in action_events(op)
    end

    test "reads a duplicate back from the authority instead of resubmitting", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &duplicate_response/1,
        {"GET", @recent_path} => &recent_response(&1, held_by_authority())
      })

      assert :ok = SubmitWorker.handle_job(args(document), execution(op))

      assert_received {:request, "POST", @submit_path, _}
      assert_received {:request, "GET", @recent_path, _}
      refute_received {:request, "POST", @submit_path, _}

      assert [{"issued", _}, {"submitted", submitted}] = events(op, document)

      assert %{
               submission_uid: "HJSD135P2S7D8IU",
               document_uuid: "F9D425P6DS7D8IU",
               authority_status: "Submitted",
               http_status: 200,
               response: %{"internalId" => "JSON-INV12345"}
             } = submitted

      assert "finance.einvoice.submitted" in action_events(op)
      refute "finance.einvoice.submission.duplicate" in action_events(op)

      assert [job] = Repo.all(Oban.Job)
      assert job.worker == "Bilimbi.Finance.Einvoice.PollWorker.ObanAdapter"

      assert {:ok, %{status: "submitted", submission_uid: "HJSD135P2S7D8IU"}} =
               Einvoice.get_document(op, 73, document.id)
    end

    test "keeps the duplicate and stops when the authority holds no such document", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &duplicate_response/1,
        {"GET", @recent_path} =>
          &recent_response(&1, [%{internalId: "OTHER-1", uuid: "U", submissionUid: "S"}])
      })

      assert {:cancel, :duplicate_submission} =
               SubmitWorker.handle_job(args(document), execution(op))

      assert_received {:request, "GET", @recent_path, _}
      assert [{"issued", _}, {"duplicate", %{http_status: 422}}] = events(op, document)
      assert "finance.einvoice.submission.duplicate" in action_events(op)
      assert Repo.all(Oban.Job) == []
    end

    test "defers a duplicate whose lookup the authority could not answer", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &duplicate_response/1,
        {"GET", @recent_path} => &(&1 |> Plug.Conn.put_status(503) |> Req.Test.json(%{}))
      })

      assert {:retry, :authority_unavailable} =
               SubmitWorker.handle_job(args(document), execution(op))

      assert [{"issued", _}, {"search_deferred", %{http_status: 503}}] = events(op, document)
      assert {:ok, %{status: "issued"}} = Einvoice.get_document(op, 73, document.id)
    end

    test "looks for a submission an outage may have hidden before retrying", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &Req.Test.transport_error(&1, :timeout),
        {"GET", @recent_path} => &recent_response(&1, held_by_authority())
      })

      assert :ok = SubmitWorker.handle_job(args(document), execution(op))

      assert [{"issued", _}, {"submitted", %{document_uuid: "F9D425P6DS7D8IU"}}] =
               events(op, document)

      assert [_poll_job] = Repo.all(Oban.Job)

      {:ok, fresh} =
        Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes(%{code_number: "INV-2"}))

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &Req.Test.transport_error(&1, :timeout),
        {"GET", @recent_path} => &recent_response(&1, [])
      })

      assert {:retry, :authority_unavailable} =
               SubmitWorker.handle_job(args(fresh), execution(op))

      assert [{"issued", _}, {"unavailable", %{reason: "TransportError"}}] = events(op, fresh)
    end

    test "searches a window that reaches past the job's start", %{
      operator: op,
      document: document
    } do
      started = DateTime.add(DateTime.utc_now(), -3600, :second)
      asked_at = DateTime.truncate(DateTime.utc_now(), :second)

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &Req.Test.transport_error(&1, :timeout),
        {"GET", @recent_path} => fn conn ->
          if DateTime.compare(query_instant(conn, "submissionDateTo"), asked_at) == :lt,
            do: recent_response(conn, []),
            else: recent_response(conn, held_by_authority())
        end
      })

      assert :ok = Clearance.submit(op, 73, document.id, started)

      assert [{"issued", _}, {"submitted", %{document_uuid: "F9D425P6DS7D8IU"}}] =
               events(op, document)
    end

    test "a retry after an outage finds the earlier attempt accepted and does not send again", %{
      operator: op,
      document: document
    } do
      stub_outage!()

      assert {:retry, :authority_unavailable} =
               SubmitWorker.handle_job(args(document), execution(op))

      drain_requests()

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &TestFixtures.accepted_response(&1, "JSON-INV12345"),
        {"GET", @recent_path} => &recent_response(&1, held_by_authority())
      })

      assert :ok = SubmitWorker.handle_job(args(document), execution(op))

      assert_received {:request, "GET", @recent_path, _}
      refute_received {:request, "POST", @submit_path, _}

      assert [
               {"issued", _},
               {"unavailable", _},
               {"submitted", %{submission_uid: "HJSD135P2S7D8IU"}}
             ] =
               events(op, document)

      assert length(Repo.all(Submission)) == 1
      assert [_poll_job] = Repo.all(Oban.Job)
    end

    test "a retry after an outage does not send while the search cannot answer", %{
      operator: op,
      document: document
    } do
      stub_outage!()

      assert {:retry, :authority_unavailable} =
               SubmitWorker.handle_job(args(document), execution(op))

      drain_requests()

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &TestFixtures.accepted_response(&1, "JSON-INV12345"),
        {"GET", @recent_path} => &(&1 |> Plug.Conn.put_status(503) |> Req.Test.json(%{}))
      })

      assert {:retry, :authority_unavailable} =
               SubmitWorker.handle_job(args(document), execution(op))

      refute_received {:request, "POST", @submit_path, _}

      assert [{"issued", _}, {"unavailable", _}, {"search_deferred", %{http_status: 503}}] =
               events(op, document)

      assert length(Repo.all(Submission)) == 1

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &TestFixtures.accepted_response(&1, "JSON-INV12345"),
        {"GET", @recent_path} => &recent_response(&1, [])
      })

      assert :ok = SubmitWorker.handle_job(args(document), execution(op))
      assert_received {:request, "POST", @submit_path, _}
      assert length(Repo.all(Submission)) == 2
    end

    test "a retry after an outage does not send while the search is rate limited", %{
      operator: op,
      document: document
    } do
      stub_outage!()

      assert {:retry, :authority_unavailable} =
               SubmitWorker.handle_job(args(document), execution(op))

      drain_requests()

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &TestFixtures.accepted_response(&1, "JSON-INV12345"),
        {"GET", @recent_path} => &(&1 |> Plug.Conn.put_status(429) |> Req.Test.json(%{}))
      })

      for _run <- 1..2 do
        assert {:retry, :rate_limited} = SubmitWorker.handle_job(args(document), execution(op))
      end

      refute_received {:request, "POST", @submit_path, _}
      assert length(Repo.all(Submission)) == 1
    end

    test "a retry after an outage does not send when the search is refused", %{
      operator: op,
      document: document
    } do
      stub_outage!()

      assert {:retry, :authority_unavailable} =
               SubmitWorker.handle_job(args(document), execution(op))

      drain_requests()

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &TestFixtures.accepted_response(&1, "JSON-INV12345"),
        {"GET", @recent_path} => &(&1 |> Plug.Conn.put_status(403) |> Req.Test.json(%{}))
      })

      assert {:retry, :authority_unavailable} =
               SubmitWorker.handle_job(args(document), execution(op))

      refute_received {:request, "POST", @submit_path, _}
      assert [_, _, {"search_deferred", %{http_status: 403}}] = events(op, document)
    end

    test "a search never recovers an earlier cycle's document for a new attempt", %{
      operator: op,
      document: document
    } do
      documents = Bilimbi.Finance.Einvoice.Documents

      documents.record_event!(op, 73, document.id, %{
        event: "submitted",
        submission_uid: "OLDSUB",
        document_uuid: "OLDUUID1",
        authority_status: "Submitted"
      })

      documents.record_event!(op, 73, document.id, %{
        event: "invalid",
        document_uuid: "OLDUUID1",
        authority_status: "Invalid",
        reason: "fixed since"
      })

      stub_outage!()

      assert {:retry, :authority_unavailable} =
               SubmitWorker.handle_job(args(document), execution(op))

      drain_requests()

      old = %{
        internalId: "JSON-INV12345",
        uuid: "OLDUUID1",
        submissionUid: "OLDSUB",
        dateTimeReceived: "2026-12-01T00:00:00Z"
      }

      stub = fn results ->
        TestFixtures.stub_authority!(%{
          {"POST", "/connect/token"} => &TestFixtures.token_response/1,
          {"POST", @submit_path} => &TestFixtures.accepted_response(&1, "JSON-INV12345"),
          {"GET", @recent_path} => &recent_response(&1, results)
        })
      end

      stub.([old])
      assert :ok = SubmitWorker.handle_job(args(document), execution(op))
      assert_received {:request, "POST", @submit_path, _}

      assert {:ok, %{status: "submitted", document_uuid: "F9D425P6DS7D8IU"}} =
               Einvoice.get_document(op, 73, document.id)
    end

    test "a search recovers the new attempt's document beside an earlier cycle's", %{
      operator: op,
      document: document
    } do
      documents = Bilimbi.Finance.Einvoice.Documents

      documents.record_event!(op, 73, document.id, %{
        event: "submitted",
        submission_uid: "OLDSUB",
        document_uuid: "OLDUUID1",
        authority_status: "Submitted"
      })

      documents.record_event!(op, 73, document.id, %{
        event: "invalid",
        document_uuid: "OLDUUID1",
        authority_status: "Invalid",
        reason: "fixed since"
      })

      stub_outage!()

      assert {:retry, :authority_unavailable} =
               SubmitWorker.handle_job(args(document), execution(op))

      drain_requests()

      results = [
        %{
          internalId: "JSON-INV12345",
          uuid: "OLDUUID1",
          submissionUid: "OLDSUB",
          dateTimeReceived: "2026-12-01T00:00:00Z"
        },
        %{
          internalId: "JSON-INV12345",
          uuid: "NEWUUID2",
          submissionUid: "NEWSUB",
          dateTimeReceived: "2026-10-02T00:00:00Z"
        }
      ]

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &TestFixtures.accepted_response(&1, "JSON-INV12345"),
        {"GET", @recent_path} => &recent_response(&1, results)
      })

      assert :ok = SubmitWorker.handle_job(args(document), execution(op))
      refute_received {:request, "POST", @submit_path, _}

      assert {:ok, %{status: "submitted", submission_uid: "NEWSUB", document_uuid: "NEWUUID2"}} =
               Einvoice.get_document(op, 73, document.id)
    end

    test "a retry after an outage sends again when the search finds nothing", %{
      operator: op,
      document: document
    } do
      stub_outage!()

      assert {:retry, :authority_unavailable} =
               SubmitWorker.handle_job(args(document), execution(op))

      drain_requests()

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &TestFixtures.accepted_response(&1, "JSON-INV12345"),
        {"GET", @recent_path} => &recent_response(&1, [])
      })

      assert :ok = SubmitWorker.handle_job(args(document), execution(op))

      assert_received {:request, "POST", @submit_path, _}
      assert [{"issued", _}, {"unavailable", _}, {"submitted", _}] = events(op, document)
      assert length(Repo.all(Submission)) == 2
    end

    test "retries a rate limit and an outage, and notices a 72-hour outage once", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => fn conn ->
          conn
          |> Plug.Conn.put_status(429)
          |> Plug.Conn.put_resp_header("retry-after", "7")
          |> Req.Test.json(%{})
        end
      })

      assert {:retry, :rate_limited} = SubmitWorker.handle_job(args(document), execution(op))

      assert [{"issued", _}, {"rate_limited", %{reason: "rate limited; retry after 7 seconds"}}] =
               events(op, document)

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &(&1 |> Plug.Conn.put_status(503) |> Req.Test.json(%{})),
        {"GET", @recent_path} => &recent_response(&1, [])
      })

      now = DateTime.utc_now()
      assert {:retry, :authority_unavailable} = Clearance.submit(op, 73, document.id, now)

      assert [_, _, {"unavailable", %{http_status: 503, reason: "HTTP 503"}}] =
               events(op, document)

      refute "finance.einvoice.submission.overdue" in action_events(op)

      later = DateTime.add(now, 72 * 3600 + 1, :second)
      assert {:retry, :authority_unavailable} = Clearance.submit(op, 73, document.id, later)
      assert [_, _, _, {"unavailable", _}, {"overdue", _}] = events(op, document)
      assert "finance.einvoice.submission.overdue" in action_events(op)

      assert {:retry, :authority_unavailable} =
               Clearance.submit(op, 73, document.id, DateTime.add(later, 3600, :second))

      assert [_, _, _, _, _, {"unavailable", _}] = events(op, document)

      assert {:ok, %{status: "issued", attention: [:overdue]}} =
               Einvoice.get_document(op, 73, document.id)

      # Each attempt kept the bytes it sent.
      assert length(Repo.all(Submission)) == 4
    end

    test "stops a job whose company has no credentials for the document's environment",
         %{operator: op} = context do
      :ok = TestFixtures.put_settings!(context.first_scope, 73, %{"environment" => "production"})

      {:ok, document} =
        Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes(%{code_number: "PROD-1"}))

      assert document.environment == "production"

      assert {:cancel, :missing_credentials} =
               SubmitWorker.handle_job(args(document), execution(op))

      assert [{"issued", _}, {"unsendable", %{reason: "cannot submit: missing_credentials"}}] =
               events(op, document)
    end

    test "refuses arguments that are not identifiers" do
      assert {:error, :invalid_document} =
               SubmitWorker.validate_args(%{"company_id" => 73, "document_id" => "1"})

      assert {:error, :invalid_document} =
               SubmitWorker.validate_args(%{
                 "company_id" => 73,
                 "document_id" => 1,
                 "secret" => "x"
               })

      assert {:ok, %{"company_id" => 73, "document_id" => 1}} =
               SubmitWorker.validate_args(%{"company_id" => 73, "document_id" => 1})

      assert {:cancel, :actor_unavailable} =
               SubmitWorker.handle_job(%{"company_id" => 73, "document_id" => 1}, %Execution{
                 job_id: 1,
                 attempt: 1,
                 max_attempts: 1,
                 queue: "default",
                 scope: nil
               })
    end
  end

  describe "the poll job" do
    setup %{operator: op, document: document} do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"POST", @submit_path} => &TestFixtures.accepted_response(&1, "JSON-INV12345")
      })

      :ok = SubmitWorker.handle_job(args(document), execution(op))
      :ok
    end

    test "waits while in progress, then records a valid document and posts it", %{
      operator: op,
      document: document
    } do
      TestFixtures.open_posting_book!(op, 73)
      test = self()

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @progress_path} => fn conn ->
          send(test, :progress_read)
          overall = if Process.get(:reads, 0) >= 2, do: "valid", else: "in progress"
          Process.put(:reads, Process.get(:reads, 0) + 1)
          TestFixtures.progress_response(conn, overall)
        end,
        {"GET", @details_path} => &TestFixtures.details_response(&1, "Valid")
      })

      assert :ok = PollWorker.handle_job(args(document), execution(op))

      assert [{"issued", _}, {"submitted", _}, {"valid", valid}, {"posted", posted}] =
               events(op, document)

      assert %{
               long_id: "LIJAF97HJJKH",
               document_uuid: "F9D425P6DS7D8IU",
               authority_status: "Valid"
             } = valid

      assert is_integer(posted.ledger_entry_id)
      assert "finance.einvoice.validated" in action_events(op)

      assert {:ok, view} = Einvoice.get_document(op, 73, document.id)
      assert view.status == "valid"
      assert view.validated_at == ~U[2026-10-01 01:00:00Z]
      assert view.cancellable_until == ~U[2026-10-04 01:00:00Z]

      assert view.validation_url ==
               "https://preprod.myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/LIJAF97HJJKH"

      assert view.ledger_entry_id == posted.ledger_entry_id
      assert view.attention == []

      # Nothing to poll afterwards.
      assert :ok = PollWorker.handle_job(args(document), execution(op))
    end

    test "retries when the authority is still processing after the job's reads", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @progress_path} => &TestFixtures.progress_response(&1, "in progress")
      })

      assert {:retry, :in_progress} = PollWorker.handle_job(args(document), execution(op))
      assert [{"issued", _}, {"submitted", _}] = events(op, document)
    end

    test "records an invalid document with the authority's validation errors", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @progress_path} => &TestFixtures.progress_response(&1, "invalid", "Invalid"),
        {"GET", @details_path} =>
          &TestFixtures.details_response(&1, "Invalid", %{
            validationResults: %{
              status: "Invalid",
              validationSteps: [
                %{name: "Step04-Code Field Validator", status: "Valid"},
                %{
                  name: "Step05-Taxpayer Profile Validator",
                  status: "Invalid",
                  error: %{
                    error: "Step05-Invalid Taxpayer Profile Validator",
                    errorCode: "Error05",
                    innerError: [
                      %{
                        error:
                          "Where specific TIN provided, NA is not allowed for NRIC/ARMY Please refer to https://sdk.example/ERR203",
                        errorCode: "ERR203",
                        propertyName: "SupplierIdentity"
                      }
                    ]
                  }
                }
              ]
            }
          })
      })

      assert :ok = PollWorker.handle_job(args(document), execution(op))
      assert [{"issued", _}, {"submitted", _}, {"invalid", invalid}] = events(op, document)

      assert invalid.reason ==
               "Step05-Taxpayer Profile Validator: Error05 Step05-Invalid Taxpayer Profile Validator: " <>
                 "ERR203 Where specific TIN provided, NA is not allowed for NRIC/ARMY"

      assert "finance.einvoice.invalid" in action_events(op)
      assert {:ok, %{status: "invalid"}} = Einvoice.get_document(op, 73, document.id)
      # An invalid document can be corrected through settings and submitted again.
      assert {:ok, _job} = Einvoice.submit_document(op, 73, document.id)
    end

    test "records a valid document whose posting could not happen", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @progress_path} => &TestFixtures.progress_response(&1, "valid"),
        {"GET", @details_path} => &TestFixtures.details_response(&1, "Valid")
      })

      assert :ok = PollWorker.handle_job(args(document), execution(op))
      assert [_, _, {"valid", _}, {"posting_failed", failed}] = events(op, document)
      assert failed.reason == "the company's book is not open"

      assert {:ok, %{status: "valid", attention: [:posting_failed]}} =
               Einvoice.get_document(op, 73, document.id)
    end

    test "a ledger refusal leaves the valid event committed and is recorded once", %{
      operator: op,
      document: document
    } do
      accounts = TestFixtures.open_posting_book!(op, 73)

      {:ok, _account} =
        Ledger.update_account(op, 73, accounts.revenue_account.id, %{active: false})

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @progress_path} => &TestFixtures.progress_response(&1, "valid"),
        {"GET", @details_path} => &TestFixtures.details_response(&1, "Valid")
      })

      assert :ok = PollWorker.handle_job(args(document), execution(op))

      assert [
               {"issued", _},
               {"submitted", _},
               {"valid", _},
               {"posting_failed", failed}
             ] = events(op, document)

      assert failed.reason =~ ~r/^lines\[\d+\] account_id /
      assert "finance.einvoice.validated" in action_events(op)

      assert {:ok, %{status: "valid", attention: [:posting_failed]}} =
               Einvoice.refresh_status(op, 73, document.id)

      assert [_, _, _, {"posting_failed", _}, {"status_checked", _}] = events(op, document)

      assert {:error, {:failed, _reason}} = Einvoice.retry_posting(op, 73, document.id)
      assert "finance.einvoice.posting.retried" in action_events(op)

      {:ok, _account} =
        Ledger.update_account(op, 73, accounts.revenue_account.id, %{active: true})

      assert {:ok, %{ledger_entry_id: entry_id, attention: []}} =
               Einvoice.retry_posting(op, 73, document.id)

      assert is_integer(entry_id)
    end

    test "a refresh that lands during the poll is not recorded twice", %{
      operator: op,
      document: document
    } do
      TestFixtures.open_posting_book!(op, 73)
      test = self()

      responses = %{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @details_path} => &TestFixtures.details_response(&1, "Valid")
      }

      TestFixtures.stub_authority!(
        Map.put(responses, {"GET", @progress_path}, fn conn ->
          # The user's refresh finishes while the poll holds the earlier view.
          unless Process.get(:refreshed) do
            Process.put(:refreshed, true)
            send(test, {:refreshed, Einvoice.refresh_status(op, 73, document.id)})
          end

          TestFixtures.progress_response(conn, "valid")
        end)
      )

      assert :ok = PollWorker.handle_job(args(document), execution(op))
      assert_received {:refreshed, {:ok, %{status: "valid"}}}

      assert [{"issued", _}, {"submitted", _}, {"valid", _}, {"posted", _}, {"status_checked", _}] =
               events(op, document)

      validated = Enum.count(action_events(op), &(&1 == "finance.einvoice.validated"))
      assert validated == 1
    end

    test "retries on a rate limit or outage and stops when the status is unreadable", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @progress_path} =>
          &(&1
            |> Plug.Conn.put_status(429)
            |> Plug.Conn.put_resp_header("retry-after", "5")
            |> Req.Test.json(%{}))
      })

      assert {:retry, :rate_limited} = PollWorker.handle_job(args(document), execution(op))

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @progress_path} => &(&1 |> Plug.Conn.put_status(502) |> Req.Test.json(%{}))
      })

      assert {:retry, :authority_unavailable} =
               PollWorker.handle_job(args(document), execution(op))

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @progress_path} =>
          &(&1
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{error: %{code: "NotFound", message: "No such submission"}}))
      })

      assert {:cancel, :status_unreadable} = PollWorker.handle_job(args(document), execution(op))

      assert [_, _, {"status_unreadable", %{reason: "No such submission", http_status: 404}}] =
               events(op, document)
    end
  end

  describe "refreshing and cancelling" do
    setup %{operator: op, document: document} do
      TestFixtures.open_posting_book!(op, 73)
      :ok = TestFixtures.validate!(op, 73, document.id)
      {:ok, view} = Einvoice.get_document(op, 73, document.id)
      %{document: view}
    end

    test "refresh needs a UUID and records an unchanged status as checked", %{operator: op} do
      {:ok, fresh} =
        Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes(%{code_number: "INV-2"}))

      assert {:error, :not_submitted} = Einvoice.refresh_status(op, 73, fresh.id)
    end

    test "refresh records a buyer's rejection request, then a cancellation made on the portal", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @details_path} => &TestFixtures.details_response(&1, "Valid")
      })

      assert {:ok, %{status: "valid"}} = Einvoice.refresh_status(op, 73, document.id)
      assert [_, _, _, {"status_checked", %{authority_status: "Valid"}}] = events(op, document)

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @details_path} =>
          &TestFixtures.details_response(&1, "Valid", %{
            rejectRequestDateTime: "2026-10-02T03:00:00Z",
            documentStatusReason: "Wrong quantity"
          })
      })

      assert {:ok, %{status: "rejected", attention: [:rejection_requested, :unposted]}} =
               Einvoice.refresh_status(op, 73, document.id)

      assert [_, _, _, _, {"rejected", %{reason: "Wrong quantity"}}] = events(op, document)
      assert "finance.einvoice.rejected" in action_events(op)

      # The document was never posted here (validated without the job), so
      # there is nothing to reverse; the status still moves.
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @details_path} =>
          &TestFixtures.details_response(&1, "Cancelled", %{
            cancelDateTime: "2026-10-02T04:00:00Z"
          })
      })

      assert {:ok, %{status: "cancelled"}} = Einvoice.refresh_status(op, 73, document.id)
      assert "finance.einvoice.cancelled" in action_events(op)
    end

    test "a status read never posts a failed document again", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"GET", @details_path} => &TestFixtures.details_response(&1, "Valid")
      })

      Bilimbi.Finance.Einvoice.Documents.record_event!(op, 73, document.id, %{
        event: "posting_failed",
        reason: "failed"
      })

      for _read <- 1..2 do
        assert {:ok, %{status: "valid", ledger_entry_id: nil, attention: [:posting_failed]}} =
                 Einvoice.refresh_status(op, 73, document.id)
      end

      assert [_, _, _, {"posting_failed", _}, {"status_checked", _}, {"status_checked", _}] =
               events(op, document)
    end

    test "retrying while another retry runs posts the document once", %{
      operator: op,
      document: document
    } do
      owner = self()

      results =
        for _try <- 1..2 do
          Task.async(fn ->
            Sandbox.allow(Repo, owner, self())
            Einvoice.retry_posting(op, 73, document.id)
          end)
        end
        |> Task.await_many()

      assert [{:ok, %{ledger_entry_id: entry_id}}, {:ok, %{ledger_entry_id: entry_id}}] = results
      assert is_integer(entry_id)
      assert Enum.count(events(op, document), &match?({"posted", _}, &1)) == 1
      assert {:ok, [_only_entry]} = Ledger.list_entries(op, 73)
    end

    test "a cancellation the portal already made is not recorded again", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"PUT", @cancel_path} => fn conn ->
          Bilimbi.Finance.Einvoice.Documents.record_event!(op, 73, document.id, %{
            event: "cancelled",
            authority_status: "Cancelled",
            reason: "portal"
          })

          Req.Test.json(conn, %{uuid: "F9D425P6DS7D8IU", status: "Cancelled"})
        end
      })

      assert {:ok, %{status: "cancelled"}} = Einvoice.cancel_document(op, 73, document.id, "Late")

      assert [_, _, _, {"cancelled", %{reason: "portal"}}] = events(op, document)
      refute "finance.einvoice.cancelled" in action_events(op)
    end

    test "a rejected document is still valid at the authority and posts like one", %{
      operator: op,
      document: document
    } do
      Bilimbi.Finance.Einvoice.Documents.record_event!(op, 73, document.id, %{
        event: "rejected",
        authority_status: "Valid",
        reason: "Wrong quantity"
      })

      assert {:ok, %{unposted: [row], unreversed: []}} = Einvoice.reconciliation(op, 73)
      assert row.id == document.id and row.status == "rejected"

      assert {:ok, %{status: "rejected", attention: [:rejection_requested, :unposted]}} =
               Einvoice.get_document(op, 73, document.id)

      assert {:ok, %{ledger_entry_id: entry_id, attention: [:rejection_requested]}} =
               Einvoice.retry_posting(op, 73, document.id)

      assert is_integer(entry_id)
      assert {:ok, %{unposted: [], unreversed: []}} = Einvoice.reconciliation(op, 73)
    end

    test "retry_posting posts a failed document once, audits each try, and is idempotent",
         %{operator: op, document: document} = context do
      :ok =
        TestFixtures.put_settings!(context.first_scope, 73, %{"posting.tax_account" => "9999"})

      assert {:error, {:failed, "accounts not in the chart: tax_account 9999"}} =
               Einvoice.retry_posting(op, 73, document.id)

      assert {:ok, %{attention: [:posting_failed]}} = Einvoice.get_document(op, 73, document.id)

      :ok =
        TestFixtures.put_settings!(context.first_scope, 73, %{"posting.tax_account" => "2200"})

      assert {:ok, %{ledger_entry_id: entry_id, attention: []}} =
               Einvoice.retry_posting(op, 73, document.id)

      assert is_integer(entry_id)

      assert {:ok, %{ledger_entry_id: ^entry_id}} = Einvoice.retry_posting(op, 73, document.id)

      assert {:ok, %{unposted: [], unreversed: []}} = Einvoice.reconciliation(op, 73)
      assert Enum.count(events(op, document), &match?({"posted", _}, &1)) == 1
      assert Enum.count(action_events(op), &(&1 == "finance.einvoice.posting.retried")) == 2

      {:ok, fresh} =
        Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes(%{code_number: "INV-2"}))

      assert {:error, :not_postable} = Einvoice.retry_posting(op, 73, fresh.id)
      assert {:error, :document_not_found} = Einvoice.retry_posting(op, 73, fresh.id + 1000)
    end

    test "retries need the ledger grant as well as the e-invoice one, and record nothing without",
         %{operator: op, document: document} = context do
      submitter = TestFixtures.sign_in!(context.first_scope, 73, 92, TestFixtures.capabilities())

      bookkeeper =
        TestFixtures.sign_in!(context.first_scope, 73, 93, TestFixtures.ledger_capabilities())

      for scope <- [submitter, bookkeeper] do
        assert {:error, :unauthorized} = Einvoice.retry_posting(scope, 73, document.id)
        assert {:error, :unauthorized} = Einvoice.retry_reversal(scope, 73, document.id)
      end

      assert [_, _, _] = events(op, document)
      refute "finance.einvoice.posting.retried" in action_events(op)
    end

    test "retry_reversal reverses a cancelled document's entry once", %{
      operator: op,
      document: document
    } do
      {:ok, entry} = Bilimbi.Finance.Einvoice.Posting.post(op, 73, document)
      assert {:error, :not_reversible} = Einvoice.retry_reversal(op, 73, document.id)

      Bilimbi.Finance.Einvoice.Documents.record_event!(op, 73, document.id, %{
        event: "cancelled",
        authority_status: "Cancelled",
        reason: "portal"
      })

      assert {:ok, %{unreversed: [_row]}} = Einvoice.reconciliation(op, 73)

      assert {:ok, %{ledger_entry_id: entry_id, reversal_entry_id: reversal_id, attention: []}} =
               Einvoice.retry_reversal(op, 73, document.id)

      assert entry_id == entry.id and is_integer(reversal_id)

      assert {:ok, %{reversal_entry_id: ^reversal_id}} =
               Einvoice.retry_reversal(op, 73, document.id)

      assert {:ok, %{unposted: [], unreversed: []}} = Einvoice.reconciliation(op, 73)
      assert Enum.count(action_events(op), &(&1 == "finance.einvoice.posting.retried")) == 1
    end

    test "an archived company is refused before the authority is asked or an event recorded", %{
      operator: op,
      document: document
    } do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"PUT", @cancel_path} =>
          &Req.Test.json(&1, %{uuid: "F9D425P6DS7D8IU", status: "Cancelled"}),
        {"GET", @details_path} => &TestFixtures.details_response(&1, "Valid")
      })

      SQL.query!(Repo, "UPDATE companies SET status = 'archived' WHERE id = 73", [])

      assert {:error, :company_archived} =
               Einvoice.cancel_document(op, 73, document.id, "Wrong buyer")

      assert {:error, :company_archived} = Einvoice.refresh_status(op, 73, document.id)
      assert {:error, :company_archived} = Einvoice.retry_posting(op, 73, document.id)
      assert {:error, :company_archived} = Einvoice.retry_reversal(op, 73, document.id)
      assert {:cancel, :company_archived} = PollWorker.handle_job(args(document), execution(op))
      assert {:cancel, :company_archived} = SubmitWorker.handle_job(args(document), execution(op))

      refute_received {:request, _method, _path, _body}
      assert [{"issued", _}, {"submitted", _}, {"valid", _}] = events(op, document)
    end

    test "cancel is guarded locally before the authority is asked", %{
      operator: op,
      document: document
    } do
      {:ok, fresh} =
        Einvoice.issue_document(op, 73, TestFixtures.invoice_attributes(%{code_number: "INV-3"}))

      assert {:error, :not_cancellable} = Einvoice.cancel_document(op, 73, fresh.id, "reason")
      assert {:error, :invalid_reason} = Einvoice.cancel_document(op, 73, document.id, "   ")

      assert {:error, :invalid_reason} =
               Einvoice.cancel_document(op, 73, document.id, String.duplicate("x", 301))

      late = DateTime.add(document.validated_at, 72 * 3600 + 1, :second)

      assert {:error, :cancellation_period_over} =
               Clearance.cancel(op, 73, document.id, "late", late)

      # A note the authority holds keeps the original from being cancelled.
      {:ok, note} =
        Einvoice.issue_document(
          op,
          73,
          TestFixtures.invoice_attributes(%{
            document_type: "02",
            code_number: "CN-1",
            original_document_id: document.id
          })
        )

      :ok =
        TestFixtures.validate!(op, 73, note.id,
          uuid: "NOTE000000000001",
          submission_uid: "SUB-NOTE"
        )

      assert {:error, :active_referencing_documents} =
               Einvoice.cancel_document(op, 73, document.id, "reason")

      refute_received {:request, "PUT", @cancel_path, _}
    end

    test "cancel records the authority's refusal", %{operator: op, document: document} do
      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"PUT", @cancel_path} => fn conn ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{error: %{code: "OperationPeriodOver", message: "Period over"}})
        end
      })

      assert {:error, {:refused, :period_over, "Period over"}} =
               Einvoice.cancel_document(op, 73, document.id, "Wrong buyer")

      assert [_, _, _, {"cancellation_refused", %{http_status: 400}}] = events(op, document)
      assert "finance.einvoice.cancellation.refused" in action_events(op)
      assert {:ok, %{status: "valid"}} = Einvoice.get_document(op, 73, document.id)
    end

    test "cancel records the cancellation and reverses the posting", %{
      operator: op,
      document: document
    } do
      {:ok, entry} = Bilimbi.Finance.Einvoice.Posting.post(op, 73, document)

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"PUT", @cancel_path} =>
          &Req.Test.json(&1, %{uuid: "F9D425P6DS7D8IU", status: "Cancelled"})
      })

      assert {:ok, view} = Einvoice.cancel_document(op, 73, document.id, "Wrong buyer")

      assert_received {:request, "PUT", @cancel_path,
                       %{"status" => "cancelled", "reason" => "Wrong buyer"}}

      assert view.status == "cancelled"
      assert view.ledger_entry_id == entry.id
      assert is_integer(view.reversal_entry_id) and view.reversal_entry_id != entry.id
      assert view.attention == []

      assert [_, _, _, {"posted", _}, {"cancelled", cancelled}, {"posting_reversed", _}] =
               events(op, document)

      assert cancelled.reason == "Wrong buyer"
      assert "finance.einvoice.cancelled" in action_events(op)
      assert {:error, :not_cancellable} = Einvoice.cancel_document(op, 73, document.id, "again")
    end
  end
end
