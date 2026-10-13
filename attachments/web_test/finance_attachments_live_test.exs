defmodule BilimbiWeb.FinanceAttachmentsLiveTest do
  use BilimbiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Attachments
  alias Bilimbi.Finance.Attachments.AttachmentsCase
  alias Bilimbi.Finance.Attachments.StubSource
  alias Bilimbi.Finance.Attachments.TestFixtures
  alias Bilimbi.Finance.Ledger

  @view "finance.attachments.view"
  @manage "finance.attachments.retention.manage"
  # StubSource's records are read with the ledger's view grant.
  @source_view Ledger.view_capability()

  setup do
    signed_in_identity!()
    TestFixtures.create_artifacts_tables!()
    Ledger.TestFixtures.create_ledger_tables!()
    TestFixtures.create_attachments_tables!()
    TestFixtures.put_artifacts_root!()
    {:ok, scope} = Tenancy.scope(41)
    # Another user keeps the books, so the signed-in user 91 holds only what
    # each test grants.
    keeper = TestFixtures.sign_in!(scope, 73, 92, AttachmentsCase.all_capabilities())
    {:ok, _book} = Ledger.open_book(keeper, 73, %{currency_code: "XTS", minor_units: 2})
    StubSource.put_document!(1)
    %{scope: scope, keeper: keeper}
  end

  test "needs the view capability", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/dashboard"}}} =
             conn |> log_in_as() |> live(~p"/finance/attachments")
  end

  test "lists the company's attachments with a download each and the retention, withholding the form",
       %{conn: conn, keeper: keeper} do
    {:ok, attachment} = Attachments.attach(keeper, 73, StubSource, 1, TestFixtures.file())
    grant_capabilities!([@view, @source_view])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/attachments")

    assert has_element?(view, "#attachments-retention-years", "7 years")
    refute has_element?(view, "#attachments-retention-form")
    assert has_element?(view, "#attachment-#{attachment.id}", "scan.txt")
    assert has_element?(view, "#attachment-#{attachment.id}", "Test record · Record 1")
    assert has_element?(view, "#attachment-#{attachment.id}", "2033-12-31")
    assert has_element?(view, "#attachment-#{attachment.id}-download")

    # The download delivers the bytes as an attachment, never cached.
    conn = conn |> log_in_as() |> get(~p"/finance/attachments/#{attachment.id}/download")
    assert conn.status == 200
    assert conn.resp_body == "made-up scan"
    assert get_resp_header(conn, "content-type") == ["text/plain"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(attachment; filename="scan.txt")

    assert conn |> recycle() |> log_in_as() |> get(~p"/finance/attachments/#{attachment.id + 1}/download") |> Map.fetch!(:status) == 404
  end

  test "the download needs the view capability", %{conn: conn, keeper: keeper} do
    {:ok, attachment} = Attachments.attach(keeper, 73, StubSource, 1, TestFixtures.file())
    conn = conn |> log_in_as() |> get(~p"/finance/attachments/#{attachment.id}/download")
    assert conn.status in [302, 403]
    assert conn.resp_body != "made-up scan"
  end

  test "the attachments grant alone lists nothing and refuses the download", %{
    conn: conn,
    keeper: keeper
  } do
    {:ok, attachment} = Attachments.attach(keeper, 73, StubSource, 1, TestFixtures.file())
    grant_capabilities!([@view])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/attachments")

    refute has_element?(view, "#attachment-#{attachment.id}")
    refute render(view) =~ "scan.txt"

    conn = conn |> recycle() |> log_in_as() |> get(~p"/finance/attachments/#{attachment.id}/download")
    assert conn.status == 403
    assert conn.resp_body != "made-up scan"
  end

  test "filters by standing and lengthens the retention with a reason", %{conn: conn, keeper: keeper} do
    {:ok, old} = Attachments.attach(keeper, 73, StubSource, 1, TestFixtures.file("old.txt"))
    {:ok, new} = Attachments.replace(keeper, 73, old.id, TestFixtures.file("new.txt"))
    grant_capabilities!([@view, @source_view, @manage])
    {:ok, view, _html} = conn |> log_in_as() |> live(~p"/finance/attachments")

    assert has_element?(view, "#attachment-#{new.id}")
    refute has_element?(view, "#attachment-#{old.id}")

    view |> form("#attachments-filter", filter: %{status: "replaced", source: ""}) |> render_change()
    assert has_element?(view, "#attachment-#{old.id}", "replaced")
    refute has_element?(view, "#attachment-#{new.id}")

    view
    |> form("#attachments-retention-form", retention: %{years: "10", reason: "group policy"})
    |> render_submit()

    assert has_element?(view, "#attachments-retention-years", "10 years")
    assert has_element?(view, "#attachments-retention-changes", "group policy")
    assert {:ok, %{years: 10}} = Attachments.get_retention(keeper, 73)

    view
    |> form("#attachments-retention-form", retention: %{years: "8", reason: "back"})
    |> render_submit()

    assert render(view) =~ "only ever lengthened"
  end
end
