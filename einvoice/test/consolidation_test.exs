defmodule Bilimbi.Finance.Einvoice.ConsolidationTest do
  # The contribution registry snapshot and the token cache are node-global.
  use Bilimbi.Base.Database.DataCase, async: false

  alias Bilimbi.Base.Audit
  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Einvoice
  alias Bilimbi.Finance.Einvoice.{ConsolidatedSource, Document, Documents, Line, MyInvois}
  alias Bilimbi.Finance.Einvoice.{Submission, TestFixtures}
  alias Bilimbi.Finance.Einvoice.MyInvois.TokenCache

  import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]

  @cancel_path "/api/v1.0/documents/state/F9D425P6DS7D8IU/state"
  # Inside September 2026's window: the month ended at 2026-09-30T16:00Z
  # (midnight in Malaysia), and the window closes seven days later.
  @now ~U[2026-10-03 02:00:00Z]

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

    on_exit(fn ->
      TokenCache.delete({73, "sandbox", "test-client-id"})
      Application.delete_env(:bilimbi_finance_einvoice, :clock)
    end)

    Map.put(context, :operator, operator)
  end

  defp line(price, overrides \\ %{}) do
    Map.merge(
      %{
        description: "Item",
        classification_code: "022",
        quantity: "1",
        unit_code: "C62",
        unit_price: price,
        tax_type: "01",
        tax_rate: "6"
      },
      overrides
    )
  end

  defp source!(op, code_number, issued_at, lines \\ [line("100.00")]) do
    {:ok, document} =
      Einvoice.issue_document(
        op,
        73,
        TestFixtures.invoice_attributes(%{
          code_number: code_number,
          issued_at: issued_at,
          lines: lines
        })
      )

    document
  end

  defp consolidate(op, attributes, now \\ @now) do
    Application.put_env(:bilimbi_finance_einvoice, :clock, fn -> now end)

    Einvoice.issue_consolidated_document(
      op,
      73,
      Map.merge(%{month: "2026-09", code_number: "CON-2026-09"}, attributes)
    )
  end

  defp status(op, document) do
    {:ok, view} = Einvoice.get_document(op, 73, document.id)
    view.status
  end

  defp money(value), do: value |> Decimal.round(2) |> Decimal.to_string(:normal)

  describe "candidates" do
    test "lists the month's unsubmitted documents in the authority's calendar, with the limits it sets",
         %{operator: op} do
      # 00:30 on 1 September in Malaysia is still 31 August in UTC.
      first = source!(op, "R-001", ~U[2026-08-31 16:30:00Z])
      second = source!(op, "R-002", ~U[2026-09-15 04:00:00Z], [line("50.00"), line("20.00")])
      # Midnight on 1 October in Malaysia belongs to October.
      _october = source!(op, "R-003", ~U[2026-09-30 16:00:00Z])
      _august = source!(op, "R-000", ~U[2026-08-31 15:59:59Z])
      large = source!(op, "R-004", ~U[2026-09-16 04:00:00Z], [line("10000.00")])
      validated = source!(op, "R-005", ~U[2026-09-17 04:00:00Z])
      :ok = TestFixtures.validate!(op, 73, validated.id)
      # One waiting in a submit job is on its way to an individual e-invoice.
      queued = source!(op, "R-006", ~U[2026-09-18 04:00:00Z])
      {:ok, _job} = Einvoice.submit_document(op, 73, queued.id)

      assert {:ok, candidates} = Einvoice.consolidation_candidates(op, 73, "2026-09")

      assert candidates.month == ~D[2026-09-01]
      assert candidates.environment == "sandbox"
      assert candidates.from == ~U[2026-08-31 16:00:00Z]
      assert candidates.until == ~U[2026-09-30 16:00:00Z]
      assert candidates.closes_at == ~U[2026-10-07 16:00:00Z]
      assert Enum.map(candidates.documents, & &1.id) == [first.id, second.id]
      assert money(candidates.line_extension_amount) == "170.00"
      assert money(candidates.tax_amount) == "10.20"
      assert money(candidates.payable_amount) == "180.20"

      assert [%{document: %{id: large_id}, reason: reason}] = candidates.refused
      assert large_id == large.id
      assert reason =~ "RM10000"

      assert {:ok, %{documents: [_, _]}} =
               Einvoice.consolidation_candidates(op, 73, ~D[2026-09-20])

      assert {:error, :invalid_month} = Einvoice.consolidation_candidates(op, 73, "2026-13")
      assert {:error, :invalid_month} = Einvoice.consolidation_candidates(op, 73, "September")
    end
  end

  describe "issuing a consolidated document" do
    test "covers each source on its own line, to the general public buyer, and ties to the sources",
         %{operator: op} do
      first = source!(op, "R-001", ~U[2026-09-02 04:00:00Z])

      second =
        source!(op, "R-002", ~U[2026-09-03 04:00:00Z], [
          line("50.00"),
          line("30.00", %{tax_type: "E", tax_rate: "0", tax_exemption_reason: "Exempt goods"})
        ])

      assert {:ok, document} = consolidate(op, %{})

      assert %{
               document_type: "01",
               code_number: "CON-2026-09",
               issued_at: ~U[2026-10-03 02:00:00Z],
               status: "issued",
               consolidated?: true,
               self_billed?: false,
               counterparty_name: "General Public"
             } = document

      assert %{
               "consolidation_month" => "2026-09",
               "billing_period_start" => "2026-09-01",
               "billing_period_end" => "2026-09-30",
               "billing_period_description" => "Monthly"
             } = document.details

      assert %{"tax_id" => "EI00000000010", "registration_number" => "NA", "phone" => "NA"} =
               document.buyer

      assert [
               %{line_number: 1, description: "R-001", tax_type: "01"} = one,
               %{line_number: 2, description: "R-002", tax_type: "01"},
               %{line_number: 3, description: "R-002", tax_type: "E"} = exempt
             ] = document.lines

      assert Enum.all?(document.lines, &(&1.classification_code == "004"))
      assert money(one.line_extension_amount) == "100.00" and money(one.tax_amount) == "6.00"
      assert exempt.tax_exemption_reason == "Exempt goods"

      sources_total = Decimal.add(first.payable_amount, second.payable_amount)
      assert Decimal.equal?(document.payable_amount, sources_total)

      assert [%{id: first_id, line_numbers: [1]}, %{id: second_id, line_numbers: [2, 3]}] =
               document.sources

      assert {first_id, second_id} == {first.id, second.id}

      for source <- [first, second] do
        assert {:ok, view} = Einvoice.get_document(op, 73, source.id)
        assert view.status == "consolidated"
        assert view.consolidated_by.id == document.id
        assert List.last(view.events).reason == "consolidated in CON-2026-09"
      end

      {:ok, actions} = Audit.list_actions(op)

      assert %{payload: %{"month" => "2026-09", "document_count" => 2}} =
               Enum.find(actions, &(&1.event == "finance.einvoice.document.consolidated"))
    end

    test "a line's tax is its sources' tax, not the rate applied again to their sum",
         %{operator: op} do
      # 0.25 at 6% rounds half up to 0.02 on each line; 0.50 at 6% to 0.03.
      source!(op, "R-001", ~U[2026-09-02 04:00:00Z], [line("0.25"), line("0.25")])

      assert {:ok, %{lines: [line], tax_amount: tax}} = consolidate(op, %{})
      assert money(line.tax_amount) == "0.04"
      assert money(tax) == "0.04"
    end

    test "covers only the documents named", %{operator: op} do
      first = source!(op, "R-001", ~U[2026-09-02 04:00:00Z])
      second = source!(op, "R-002", ~U[2026-09-03 04:00:00Z])

      assert {:ok, document} = consolidate(op, %{document_ids: [second.id]})
      assert [%{id: id}] = document.sources
      assert id == second.id
      assert status(op, first) == "issued"

      assert {:error, {:not_consolidatable, id}} =
               consolidate(op, %{code_number: "CON-2", document_ids: [second.id]})

      assert id == second.id
    end

    test "is issued only inside the window after the month ends", %{operator: op} do
      source!(op, "R-001", ~U[2026-09-02 04:00:00Z])

      assert {:error, :period_not_ended} = consolidate(op, %{}, ~U[2026-09-30 15:59:59Z])

      assert {:error, :consolidation_window_closed} =
               consolidate(op, %{}, ~U[2026-10-07 16:00:00Z])

      assert {:ok, _document} = consolidate(op, %{}, ~U[2026-10-07 15:59:59Z])
    end

    test "never consolidates a document twice", %{operator: op} do
      source = source!(op, "R-001", ~U[2026-09-02 04:00:00Z])
      assert {:ok, _document} = consolidate(op, %{})

      assert {:error, :nothing_to_consolidate} = consolidate(op, %{code_number: "CON-2"})

      assert {:error, {:not_consolidatable, _}} =
               consolidate(op, %{code_number: "CON-2", document_ids: [source.id]})
    end

    test "refuses bad requests and checks the result like any document", %{operator: op} do
      assert {:error, :nothing_to_consolidate} = consolidate(op, %{})

      source!(op, "R-001", ~U[2026-09-02 04:00:00Z])

      assert {:error, :invalid_month} = consolidate(op, %{month: "2026/09"})
      assert {:error, :invalid_option} = consolidate(op, %{document_ids: []})
      assert {:error, :invalid_option} = consolidate(op, %{document_ids: ["1"]})

      assert {:error, changeset} = consolidate(op, %{code_number: ""})
      assert %{code_number: ["can't be blank"]} = errors_on(changeset)

      assert {:ok, _} = consolidate(op, %{code_number: "R-001X"})
      source!(op, "R-002", ~U[2026-09-03 04:00:00Z])
      assert {:error, :code_number_taken} = consolidate(op, %{code_number: "R-001X"})
    end

    test "needs the issue capability", %{operator: op} = context do
      source!(op, "R-001", ~U[2026-09-02 04:00:00Z])

      viewer =
        TestFixtures.sign_in!(context.first_scope, 73, 92, ["finance.einvoice.view"])

      assert {:ok, %{documents: [_]}} = Einvoice.consolidation_candidates(viewer, 73, "2026-09")
      assert {:error, :unauthorized} = consolidate(viewer, %{})

      assert {:error, :unauthorized} =
               Einvoice.consolidation_candidates(context.first_scope, 73, "2026-09")
    end

    test "an individual document never carries the consolidated classification",
         %{operator: op} do
      attributes =
        TestFixtures.invoice_attributes(%{lines: [line("1.00", %{classification_code: "004"})]})

      assert {:error, changeset} = Einvoice.issue_document(op, 73, attributes)

      assert %{lines: [%{classification_code: ["is for a consolidated document" <> _]}]} =
               errors_on(changeset)
    end

    test "builds the authority's consolidated payload", %{operator: op} do
      source!(op, "R-001", ~U[2026-09-02 04:00:00Z])
      assert {:ok, document} = consolidate(op, %{})

      ubl = MyInvois.ubl(document, "1.0")

      assert ubl.invoice_period == %{
               start_date: "2026-09-01",
               end_date: "2026-09-30",
               description: "Monthly"
             }

      assert {"TIN", "EI00000000010"} in ubl.buyer.identifications
      assert ubl.buyer.phone == "NA"
      assert [%{classifications: [{"CLASS", "004"}], description: "R-001"}] = ubl.lines

      assert {:ok, %{bytes: bytes}} =
               MyInvois.payload(document, %{version: "1.0", signing_key: nil}, @now)

      assert bytes =~ ~s("InvoicePeriod")
      assert bytes =~ ~s("EI00000000010")
    end
  end

  describe "a consolidated document's sources" do
    test "are never submitted on their own while it holds them", %{operator: op} do
      source = source!(op, "R-001", ~U[2026-09-02 04:00:00Z])
      assert {:ok, _document} = consolidate(op, %{})

      assert {:error, :not_submittable} = Einvoice.submit_document(op, 73, source.id)

      # The database refuses it too, whoever writes.
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.insert!(%Submission{
            tenant_id: 41,
            company_id: 73,
            document_id: source.id,
            environment: "sandbox",
            format: "JSON",
            document_version: "1.0",
            payload: "{}",
            payload_sha256: :sha256 |> :crypto.hash("{}") |> Base.encode16(case: :lower),
            actor_type: "user",
            actor_user_id: 91
          })
        end

      assert error.postgres.message =~ "is consolidated and cannot be submitted on its own"
    end

    test "are released when it is cancelled, and may be consolidated again", %{operator: op} do
      source = source!(op, "R-001", ~U[2026-09-02 04:00:00Z])
      assert {:ok, document} = consolidate(op, %{})
      :ok = TestFixtures.validate!(op, 73, document.id)

      TestFixtures.stub_authority!(%{
        {"POST", "/connect/token"} => &TestFixtures.token_response/1,
        {"PUT", @cancel_path} =>
          &Req.Test.json(&1, %{uuid: "F9D425P6DS7D8IU", status: "Cancelled"})
      })

      assert {:ok, %{status: "cancelled"}} =
               Einvoice.cancel_document(op, 73, document.id, "Wrong month")

      assert {:ok, view} = Einvoice.get_document(op, 73, source.id)
      assert view.status == "released"
      assert view.consolidated_by == nil
      assert List.last(view.events).reason == "CON-2026-09 is cancelled"

      assert {:ok, again} = consolidate(op, %{code_number: "CON-2026-09-B"})
      assert [%{id: id}] = again.sources
      assert id == source.id
      assert status(op, source) == "consolidated"

      # The cancelled document still lists what it covered.
      assert {:ok, %{sources: [%{id: ^id}]}} = Einvoice.get_document(op, 73, document.id)
    end

    for event <- ["refused", "invalid"] do
      test "are released when the authority answers #{event}, and it is never sent again",
           %{operator: op} do
        source = source!(op, "R-001", ~U[2026-09-02 04:00:00Z])
        assert {:ok, document} = consolidate(op, %{})

        Documents.write!(op, 73, fn ->
          Documents.record_event!(op, 73, document.id, %{event: unquote(event), reason: "CF321"})
        end)

        assert status(op, source) == "released"
        assert {:error, :not_submittable} = Einvoice.submit_document(op, 73, document.id)

        # The database refuses sending it again, whoever writes.
        error =
          assert_raise Postgrex.Error, fn ->
            Repo.insert!(%Submission{
              tenant_id: 41,
              company_id: 73,
              document_id: document.id,
              environment: "sandbox",
              format: "JSON",
              document_version: "1.0",
              payload: "{}",
              payload_sha256: :sha256 |> :crypto.hash("{}") |> Base.encode16(case: :lower),
              actor_type: "user",
              actor_user_id: 91
            })
          end

        assert error.postgres.message =~ "released its sources"

        # A new consolidated document covers the released source.
        assert {:ok, %{sources: [%{id: id}]}} = consolidate(op, %{code_number: "CON-2026-09-B"})
        assert id == source.id
      end
    end
  end

  describe "the database" do
    # A consolidated document written straight to the tables, one line of
    # 1.00 with 0.06 tax, covering `source_id`; bypasses every facade check.
    defp raw_consolidated!(source_id) do
      document =
        Repo.insert!(%Document{
          tenant_id: 41,
          company_id: 73,
          authority: "myinvois",
          environment: "sandbox",
          document_type: "01",
          code_number: "CON-RAW-#{source_id}",
          issued_at: ~U[2026-10-02 00:00:00Z],
          currency_code: "MYR",
          supplier: %{},
          buyer: %{},
          details: %{"consolidation_month" => "2026-09"},
          line_extension_amount: Decimal.new("1.00"),
          tax_exclusive_amount: Decimal.new("1.00"),
          tax_amount: Decimal.new("0.06"),
          tax_inclusive_amount: Decimal.new("1.06"),
          payable_amount: Decimal.new("1.06"),
          issued_by_user_id: 91
        })

      Repo.insert!(%Line{
        tenant_id: 41,
        company_id: 73,
        document_id: document.id,
        line_number: 1,
        description: "Raw",
        classification_code: "004",
        quantity: Decimal.new(1),
        unit_price: Decimal.new("1.00"),
        subtotal: Decimal.new("1.00"),
        discount_amount: Decimal.new(0),
        charge_amount: Decimal.new(0),
        line_extension_amount: Decimal.new("1.00"),
        tax_type: "01",
        tax_rate: Decimal.new(6),
        tax_amount: Decimal.new("0.06")
      })

      Repo.insert!(%ConsolidatedSource{
        tenant_id: 41,
        company_id: 73,
        document_id: document.id,
        source_document_id: source_id,
        line_number: 1
      })

      document
    end

    test "refuses a consolidated document whose totals differ from its sources'",
         %{operator: op} do
      source = source!(op, "R-001", ~U[2026-09-02 04:00:00Z])
      raw_consolidated!(source.id)

      error = assert_raise Postgrex.Error, &TestFixtures.check_deferred_constraints!/0
      assert error.postgres.message =~ "totals differ from its sources"
    end

    test "refuses covering a document another consolidated document holds",
         %{operator: op} do
      source = source!(op, "R-001", ~U[2026-09-02 04:00:00Z])
      assert {:ok, _document} = consolidate(op, %{})

      error = assert_raise Postgrex.Error, fn -> raw_consolidated!(source.id) end
      assert error.postgres.message =~ "is already consolidated"
    end

    test "refuses covering a document that was submitted on its own", %{operator: op} do
      source = source!(op, "R-001", ~U[2026-09-02 04:00:00Z])

      Repo.insert!(%Submission{
        tenant_id: 41,
        company_id: 73,
        document_id: source.id,
        environment: "sandbox",
        format: "JSON",
        document_version: "1.0",
        payload: "{}",
        payload_sha256: :sha256 |> :crypto.hash("{}") |> Base.encode16(case: :lower),
        actor_type: "user",
        actor_user_id: 91
      })

      assert {:ok, %{documents: []}} = Einvoice.consolidation_candidates(op, 73, "2026-09")
      error = assert_raise Postgrex.Error, fn -> raw_consolidated!(source.id) end
      assert error.postgres.message =~ "was submitted on its own"
    end
  end
end
