defmodule Bilimbi.Finance.Reports.Web.AuditorPackController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Reports

  def show(conn, %{"artifact_id" => id}) do
    scope = conn.assigns.current_scope.scope

    case Reports.read_auditor_pack(scope, Scope.actor(scope).company_id, id) do
      {:ok, %{bytes: bytes, filename: filename}} ->
        conn
        |> put_resp_content_type("application/zip", nil)
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(200, bytes)

      {:error, :unauthorized} ->
        send_resp(conn, 403, "Forbidden")

      {:error, _} ->
        send_resp(conn, 404, "Not found")
    end
  end
end
