defmodule Bilimbi.Finance.Sst.Web.ExportController do
  @moduledoc false
  # Downloads a return as CSV, or shows it as a printable page. Every
  # request reads the return through the facade, which re-authorizes.
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Sst

  def csv(conn, %{"id" => id}), do: export(conn, id, :csv, "attachment")
  def print(conn, %{"id" => id}), do: export(conn, id, :html, "inline")

  defp export(conn, id, format, disposition) do
    scope = conn.assigns.current_scope.scope
    company_id = Scope.actor(scope).company_id

    case Sst.export_return(scope, company_id, id, format: format) do
      {:ok, %{content: content, filename: filename, content_type: content_type}} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("content-disposition", ~s(#{disposition}; filename="#{filename}"))
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header(
          "content-security-policy",
          "default-src 'none'; style-src 'unsafe-inline'"
        )
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(200, content)

      {:error, :unauthorized} ->
        send_resp(conn, 403, "Forbidden")

      {:error, _reason} ->
        send_resp(conn, 404, "Not found")
    end
  end
end
