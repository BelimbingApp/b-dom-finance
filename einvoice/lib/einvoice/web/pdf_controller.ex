defmodule Bilimbi.Finance.Einvoice.Web.PdfController do
  @moduledoc false
  # Downloads a PDF `Einvoice.generate_pdf/3` stored. Every request reads
  # through Base Artifacts again, which re-authorizes and checks the bytes.
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Einvoice

  def show(conn, %{"artifact_id" => artifact_id}) do
    scope = conn.assigns.current_scope.scope
    company_id = Scope.actor(scope).company_id

    case Einvoice.read_pdf(scope, company_id, artifact_id) do
      {:ok, %{bytes: bytes, filename: filename}} ->
        conn
        |> put_resp_content_type("application/pdf", nil)
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(200, bytes)

      {:error, :unauthorized} ->
        send_resp(conn, 403, "Forbidden")

      {:error, _reason} ->
        send_resp(conn, 404, "Not found")
    end
  end
end
