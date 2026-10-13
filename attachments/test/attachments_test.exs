defmodule Bilimbi.Finance.Attachments.AttachmentsTest do
  use Bilimbi.Finance.Attachments.AttachmentsCase

  alias Bilimbi.Base.Artifacts
  alias Bilimbi.Base.Repo
  alias Bilimbi.Finance.Attachments.ArtifactOwner
  alias Ecto.Adapters.SQL

  @sha256_of_scan :crypto.hash(:sha256, "made-up scan") |> Base.encode16(case: :lower)

  setup do
    StubSource.put_document!(1)
    StubSource.put_document!(2, %{label: "Record 2", date: ~D[2027-03-15]})
    :ok
  end

  describe "attach/5" do
    test "keeps the file as a retained artifact linked to the record, with who and when",
         %{operator: operator} do
      assert {:ok, attachment} =
               Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())

      assert attachment.attachment_number == 1
      assert attachment.source == "finance/test/record"
      assert attachment.source_label == "Test record"
      assert attachment.document_id == 1
      assert attachment.document_label == "Record 1"
      assert attachment.document_date == ~D[2026-10-01]
      assert attachment.file_name == "scan.txt"
      assert attachment.content_type == "text/plain"
      assert attachment.byte_size == byte_size("made-up scan")
      assert attachment.sha256 == @sha256_of_scan
      assert attachment.retention_years == 7
      # Seven years after the end of the calendar year the record falls in.
      assert attachment.retain_until == ~U[2033-12-31 23:59:59.999999Z]
      assert attachment.captured_by_user_id == 91
      assert attachment.captured_by_impersonator_id == nil
      assert %DateTime{} = attachment.captured_at
      assert attachment.status == "standing"
      assert attachment.events == []

      assert {:ok, %{metadata: metadata, bytes: "made-up scan"}} =
               Artifacts.read(operator, 73, ArtifactOwner, attachment.artifact_id)

      assert metadata.retain_until == attachment.retain_until
      assert metadata.expires_at == nil
      assert metadata.subject == "finance/test/record"
      assert metadata.kind == "source-document"
    end

    test "counts the retention from the end of the ledger's fiscal year covering the record",
         %{operator: operator} do
      {:ok, _year} =
        Ledger.open_fiscal_year(operator, 73, %{
          start_date: ~D[2026-07-01],
          end_date: ~D[2027-06-30]
        })

      assert {:ok, attachment} =
               Attachments.attach(operator, 73, StubSource, 2, TestFixtures.file())

      assert attachment.document_date == ~D[2027-03-15]
      assert attachment.retain_until == ~U[2034-06-30 23:59:59.999999Z]

      assert {:ok, ~U[2034-06-30 23:59:59.999999Z]} =
               Attachments.retain_until(operator, 73, ~D[2027-03-15])

      # A date no fiscal year covers falls back to its calendar year.
      assert {:ok, ~U[2032-12-31 23:59:59.999999Z]} =
               Attachments.retain_until(operator, 73, ~D[2025-02-01])
    end

    test "applies the company's lengthened retention to documents captured afterwards",
         %{operator: operator} do
      {:ok, first} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())

      assert {:ok, %{years: 10, change: %{reason: "a dispute is open"}}} =
               Attachments.set_retention(operator, 73, %{years: 10, reason: "a dispute is open"})

      {:ok, second} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file("b.txt"))
      assert first.retain_until == ~U[2033-12-31 23:59:59.999999Z]
      assert second.retain_until == ~U[2036-12-31 23:59:59.999999Z]
      assert second.retention_years == 10
    end

    test "a final record still takes attachments", %{operator: operator} do
      StubSource.finalise!(1)

      assert {:ok, %{status: "standing"}} =
               Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())
    end

    test "refuses what the source refuses, an undated record, and a bad file",
         %{operator: operator} do
      assert {:error, :not_found} =
               Attachments.attach(operator, 73, StubSource, 99, TestFixtures.file())

      assert {:error, :not_found} =
               Attachments.attach(operator, 73, StubSource, "x", TestFixtures.file())

      StubSource.put_document!(3, %{date: nil})

      assert {:error, :document_undated} =
               Attachments.attach(operator, 73, StubSource, 3, TestFixtures.file())

      assert {:error, :invalid_source} =
               Attachments.attach(operator, 73, String, 1, TestFixtures.file())

      assert {:error, :invalid_file_name} =
               Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file("  "))

      assert {:error, :empty_file} =
               Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file("a.txt", ""))

      assert {:error, :invalid_content_type} =
               Attachments.attach(
                 operator,
                 73,
                 StubSource,
                 1,
                 TestFixtures.file("a.txt", "x", "not a type")
               )

      assert {:error, :file_too_large} =
               Attachments.attach(operator, 73, StubSource, 1, %{
                 file_name: "big.bin",
                 content: :binary.copy(<<0>>, Attachments.max_file_bytes() + 1)
               })

      assert {:ok, []} = Attachments.list_attachments(operator, 73, StubSource, 1)
    end

    test "stores nothing when Base Artifacts has no storage", %{operator: operator} do
      :ok = Bilimbi.Base.Settings.delete("artifacts.storage_root")

      assert {:error, _storage} =
               Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())

      assert {:ok, []} = Attachments.list_attachments(operator, 73, StubSource, 1)
    end

    test "needs the create capability in the company", %{
      first_scope: scope,
      viewer: viewer,
      operator: operator
    } do
      assert {:error, :unauthorized} =
               Attachments.attach(viewer, 73, StubSource, 1, TestFixtures.file())

      assert {:error, :unauthorized} =
               Attachments.attach(operator, 74, StubSource, 1, TestFixtures.file())

      assert {:error, :company_not_found} =
               Attachments.attach(operator, 75, StubSource, 1, TestFixtures.file())

      assert {:error, :unauthorized} =
               Attachments.attach(scope, 73, StubSource, 1, TestFixtures.file())
    end

    test "a missing default content type is the octet stream", %{operator: operator} do
      assert {:ok, %{content_type: "application/octet-stream"}} =
               Attachments.attach(operator, 73, StubSource, 1, %{file_name: "x.bin", content: "x"})
    end
  end

  test "a blank content type is the octet stream", %{operator: operator} do
    assert {:ok, %{content_type: "application/octet-stream"}} =
             Attachments.attach(operator, 73, StubSource, 1, %{
               file_name: "x.bin",
               content: "x",
               content_type: ""
             })
  end

  describe "capture_file/5 and attach_capture/5" do
    test "store before a transaction and link inside it", %{operator: operator} do
      assert {:ok, capture} =
               Attachments.capture_file(
                 operator,
                 73,
                 StubSource,
                 TestFixtures.file(),
                 ~D[2026-10-01]
               )

      assert capture.retain_until == ~U[2033-12-31 23:59:59.999999Z]

      assert {:ok, attachment} =
               Repo.transact(fn ->
                 StubSource.put_document!(7)
                 Attachments.attach_capture(operator, 73, StubSource, 7, capture)
               end)

      assert attachment.document_id == 7
      assert attachment.artifact_id == capture.artifact_id
      assert {:ok, [%{id: id}]} = Attachments.list_attachments(operator, 73, StubSource, 7)
      assert id == attachment.id
    end

    test "refuses a capture whose source or date is not the record's", %{operator: operator} do
      {:ok, capture} =
        Attachments.capture_file(operator, 73, StubSource, TestFixtures.file(), ~D[2026-10-01])

      assert {:error, :capture_mismatch} =
               Attachments.attach_capture(operator, 73, StubSource, 2, capture)

      {:ok, capture} =
        Attachments.capture_file(operator, 73, StubSource, TestFixtures.file(), ~D[2027-03-15])

      assert {:error, :invalid_source} =
               Attachments.attach_capture(operator, 73, String, 2, capture)

      assert {:ok, _attachment} = Attachments.attach_capture(operator, 73, StubSource, 2, capture)
      # One artifact, one attachment.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Attachments.attach_capture(operator, 73, StubSource, 2, capture)

      assert %{artifact_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "replace/4 and remove/4" do
    test "replace captures the new file and ends the old one, which stays readable",
         %{operator: operator} do
      {:ok, old} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())

      assert {:ok, new} =
               Attachments.replace(
                 operator,
                 73,
                 old.id,
                 TestFixtures.file("better.txt", "better")
               )

      assert new.attachment_number == 2
      assert new.document_id == 1

      assert {:ok, %{status: "replaced", events: [event]}} =
               Attachments.get_attachment(operator, 73, old.id)

      assert event.event == "replaced"
      assert event.replacement_id == new.id
      assert event.actor_user_id == 91
      assert %DateTime{} = event.occurred_at

      assert {:ok, [standing]} = Attachments.list_attachments(operator, 73, StubSource, 1)
      assert standing.id == new.id
      assert {:ok, %{bytes: "made-up scan"}} = Attachments.read_attachment(operator, 73, old.id)

      assert {:error, :attachment_not_standing} =
               Attachments.replace(operator, 73, old.id, TestFixtures.file())
    end

    test "remove ends a draft record's attachment with its reason", %{operator: operator} do
      {:ok, attachment} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())

      assert {:error, %Ecto.Changeset{} = changeset} =
               Attachments.remove(operator, 73, attachment.id, %{})

      assert %{reason: ["is required"]} = errors_on(changeset)

      assert {:ok, %{status: "removed", events: [%{event: "removed", reason: "wrong file"}]}} =
               Attachments.remove(operator, 73, attachment.id, %{reason: "wrong file"})

      assert {:ok, []} = Attachments.list_attachments(operator, 73, StubSource, 1)

      assert {:ok, [%{status: "removed"}]} =
               Attachments.list_company_attachments(operator, 73, status: "removed")

      assert {:error, :attachment_not_standing} =
               Attachments.remove(operator, 73, attachment.id, %{reason: "again"})

      # The bytes are retained: Base refuses to delete them.
      assert {:error, :retained} =
               Artifacts.delete(operator, 73, ArtifactOwner, attachment.artifact_id)
    end

    test "a final record's attachments are kept as they are", %{operator: operator} do
      {:ok, attachment} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())
      StubSource.finalise!(1)

      assert {:error, :document_final} =
               Attachments.replace(operator, 73, attachment.id, TestFixtures.file())

      assert {:error, :document_final} =
               Attachments.remove(operator, 73, attachment.id, %{reason: "no"})

      assert {:ok, [%{status: "standing"}]} =
               Attachments.list_attachments(operator, 73, StubSource, 1)
    end

    test "each asks its own capability", %{operator: operator, viewer: viewer, first_scope: scope} do
      {:ok, attachment} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())

      assert {:error, :unauthorized} =
               Attachments.replace(viewer, 73, attachment.id, TestFixtures.file())

      assert {:error, :unauthorized} =
               Attachments.remove(viewer, 73, attachment.id, %{reason: "no"})

      remover =
        TestFixtures.sign_in!(
          scope,
          73,
          93,
          ~w(finance.attachments.view finance.attachments.delete)
        )

      assert {:error, :unauthorized} =
               Attachments.replace(remover, 73, attachment.id, TestFixtures.file())

      assert {:ok, %{status: "removed"}} =
               Attachments.remove(remover, 73, attachment.id, %{reason: "duplicate"})
    end
  end

  describe "retention of one attachment" do
    test "extend_retention moves the retain-until later and records it", %{
      operator: operator,
      viewer: viewer
    } do
      {:ok, attachment} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())

      assert {:error, :retention_not_extended} =
               Attachments.extend_retention(operator, 73, attachment.id, %{
                 retain_until: ~D[2033-12-31],
                 reason: "same"
               })

      assert {:error, :reason_required} =
               Attachments.extend_retention(operator, 73, attachment.id, %{
                 retain_until: ~D[2040-01-01]
               })

      assert {:ok, %{events: [event]}} =
               Attachments.extend_retention(operator, 73, attachment.id, %{
                 retain_until: ~D[2040-01-01],
                 reason: "a tax query"
               })

      assert event.event == "retention_extended"
      assert event.retain_until == ~U[2040-01-01 23:59:59.999999Z]
      assert event.reason == "a tax query"

      assert {:ok, %{retain_until: ~U[2040-01-01 23:59:59.999999Z]}} =
               Attachments.get_attachment(operator, 73, attachment.id)

      assert {:ok, [%{retain_until: ~U[2040-01-01 23:59:59.999999Z]}]} =
               Attachments.list_attachments(operator, 73, StubSource, 1)

      assert {:ok, %{metadata: %{retain_until: ~U[2040-01-01 23:59:59.999999Z]}}} =
               Artifacts.read(operator, 73, ArtifactOwner, attachment.artifact_id)

      assert {:error, :unauthorized} =
               Attachments.extend_retention(viewer, 73, attachment.id, %{
                 retain_until: ~D[2041-01-01],
                 reason: "no"
               })
    end

    test "a legal hold is placed and released with reasons", %{operator: operator} do
      {:ok, attachment} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())

      assert {:error, :not_on_hold} =
               Attachments.release_hold(operator, 73, attachment.id, %{reason: "x"})

      assert {:ok, %{on_hold: false}} = Attachments.get_attachment(operator, 73, attachment.id)

      assert {:ok, %{on_hold: true, events: [%{event: "hold_placed", reason: "case 12"}]}} =
               Attachments.place_hold(operator, 73, attachment.id, %{reason: "case 12"})

      assert {:error, :already_on_hold} =
               Attachments.place_hold(operator, 73, attachment.id, %{reason: "again"})

      assert {:error, :legal_hold} =
               Artifacts.delete(operator, 73, ArtifactOwner, attachment.artifact_id)

      assert {:ok,
              %{
                on_hold: false,
                events: [_placed, %{event: "hold_released", reason: "case closed"}]
              }} =
               Attachments.release_hold(operator, 73, attachment.id, %{reason: "case closed"})
    end
  end

  describe "reading without access to the source" do
    test "the attachments grant alone shows no attachment's metadata", %{
      operator: operator,
      first_scope: scope
    } do
      {:ok, attachment} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())

      blind = TestFixtures.sign_in!(scope, 73, 94, ~w(finance.attachments.view))

      assert {:ok, []} = Attachments.list_attachments(blind, 73, StubSource, 1)
      assert {:ok, []} = Attachments.list_company_attachments(blind, 73)
      assert {:ok, []} = Attachments.list_company_attachments(blind, 73, status: "all")
      assert {:error, :unauthorized} = Attachments.get_attachment(blind, 73, attachment.id)
      assert {:error, :unauthorized} = Attachments.read_attachment(blind, 73, attachment.id)

      assert {:ok, [%{id: id}]} = Attachments.list_company_attachments(operator, 73)
      assert id == attachment.id
    end

    test "a retention manager who cannot read the source cannot change its attachment", %{
      operator: operator,
      first_scope: scope
    } do
      {:ok, attachment} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())

      manager =
        TestFixtures.sign_in!(scope, 73, 95, ~w(finance.attachments.retention.manage))

      assert {:error, :unauthorized} =
               Attachments.place_hold(manager, 73, attachment.id, %{reason: "case"})

      assert {:error, :unauthorized} =
               Attachments.extend_retention(manager, 73, attachment.id, %{
                 retain_until: ~D[2040-01-01],
                 reason: "tax query"
               })
    end
  end

  describe "reading" do
    test "lists by record and by company, newest page after a number", %{operator: operator} do
      {:ok, a} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file("a.txt"))
      {:ok, b} = Attachments.attach(operator, 73, StubSource, 2, TestFixtures.file("b.txt"))
      {:ok, c} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file("c.txt"))

      assert {:ok, [%{id: a_id}, %{id: c_id}]} =
               Attachments.list_attachments(operator, 73, StubSource, 1)

      assert {a_id, c_id} == {a.id, c.id}
      assert {:ok, [%{id: b_id}]} = Attachments.list_attachments(operator, 73, StubSource, 2)
      assert b_id == b.id
      assert {:ok, [_, _, _]} = Attachments.list_company_attachments(operator, 73)

      assert {:ok, [%{file_name: "c.txt"}]} =
               Attachments.list_company_attachments(operator, 73, after: 2)

      assert {:ok, [_, _]} = Attachments.list_company_attachments(operator, 73, limit: 2)

      assert {:ok, [%{file_name: "b.txt"}]} =
               Attachments.list_company_attachments(operator, 73, document_ids: [2])

      assert {:ok, [%{file_name: "a.txt"}, %{file_name: "c.txt"}]} =
               Attachments.list_company_attachments(operator, 73, document_ids: [1, 3])

      assert {:ok, []} = Attachments.list_company_attachments(operator, 73, document_ids: [])

      assert {:error, :invalid_option} =
               Attachments.list_company_attachments(operator, 73, document_ids: ["x"])

      assert {:ok, [_, _, _]} =
               Attachments.list_company_attachments(operator, 73, source: "finance/test/record")

      assert {:ok, []} =
               Attachments.list_company_attachments(operator, 73, source: "finance/other")

      assert {:error, :invalid_option} =
               Attachments.list_company_attachments(operator, 73, limit: 0)

      assert {:error, :invalid_option} =
               Attachments.list_company_attachments(operator, 73, status: "lost")

      assert {:error, :unauthorized} = Attachments.list_company_attachments(operator, 74)
    end

    test "read_attachment re-reads the record and the bytes", %{
      operator: operator,
      viewer: viewer
    } do
      {:ok, attachment} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())

      assert {:ok,
              %{
                bytes: "made-up scan",
                file_name: "scan.txt",
                content_type: "text/plain",
                sha256: sha
              }} =
               Attachments.read_attachment(viewer, 73, attachment.id)

      assert sha == @sha256_of_scan

      assert {:error, :attachment_not_found} =
               Attachments.read_attachment(operator, 73, attachment.id + 1)

      assert {:error, :attachment_not_found} = Attachments.read_attachment(operator, 73, "nope")

      # The record must still be readable through its source.
      Process.put({StubSource, :documents}, %{})
      assert {:error, :not_found} = Attachments.read_attachment(operator, 73, attachment.id)
    end

    test "a sibling company and a system scope see nothing", %{
      operator: operator,
      first_scope: scope
    } do
      {:ok, attachment} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())
      assert {:error, :unauthorized} = Attachments.get_attachment(operator, 74, attachment.id)
      assert {:error, :unauthorized} = Attachments.read_attachment(scope, 73, attachment.id)
      assert {:error, :unauthorized} = Attachments.list_company_attachments(scope, 73)
    end
  end

  describe "the database" do
    test "keeps attachments and their events, and ends one once", %{operator: operator} do
      {:ok, attachment} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file())

      assert_raise Postgrex.Error, ~r/UPDATE is refused/, fn ->
        SQL.query!(Repo, "UPDATE finance_attachments SET file_name = 'x' WHERE id = $1", [
          attachment.id
        ])
      end

      assert_raise Postgrex.Error, ~r/DELETE is refused/, fn ->
        SQL.query!(Repo, "DELETE FROM finance_attachments WHERE id = $1", [attachment.id])
      end

      {:ok, _removed} = Attachments.remove(operator, 73, attachment.id, %{reason: "wrong file"})

      assert_raise Postgrex.Error, ~r/finance_attachment_events_standing_unique/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_attachment_events (tenant_id, company_id, attachment_id, event, reason, actor_user_id, occurred_at) VALUES (41, 73, $1, 'removed', 'twice', 91, now())",
          [attachment.id]
        )
      end

      assert_raise Postgrex.Error, ~r/UPDATE is refused/, fn ->
        SQL.query!(Repo, "UPDATE finance_attachment_events SET reason = 'x'", [])
      end
    end

    test "a replacement is a later attachment of the same record", %{operator: operator} do
      {:ok, first} = Attachments.attach(operator, 73, StubSource, 1, TestFixtures.file("a.txt"))
      {:ok, other} = Attachments.attach(operator, 73, StubSource, 2, TestFixtures.file("b.txt"))

      assert_raise Postgrex.Error, ~r/same record/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_attachment_events (tenant_id, company_id, attachment_id, event, replacement_id, actor_user_id, occurred_at) VALUES (41, 73, $1, 'replaced', $2, 91, now())",
          [first.id, other.id]
        )
      end

      assert_raise Postgrex.Error, ~r/same record/, fn ->
        SQL.query!(
          Repo,
          "INSERT INTO finance_attachment_events (tenant_id, company_id, attachment_id, event, replacement_id, actor_user_id, occurred_at) VALUES (41, 73, $1, 'replaced', $2, 91, now())",
          [other.id, first.id]
        )
      end
    end
  end
end
