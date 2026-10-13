defmodule Bilimbi.Finance.Attachments.Web.DownloadController do
  @moduledoc false
  # Downloads a source document. Every request reads through the facade,
  # which re-asks the view capability, re-reads the record it supports, and
  # reads the bytes through Base Artifacts, which re-authorizes, checks the
  # SHA-256, and records the read. The file is delivered as an attachment
  # with content sniffing disabled, never cached, and never rendered inline.
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Attachments

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope.scope
    company_id = Scope.actor(scope).company_id

    case Attachments.read_attachment(scope, company_id, id) do
      {:ok, %{bytes: bytes, file_name: file_name, content_type: content_type}} ->
        conn
        |> put_resp_content_type(content_type, nil)
        |> put_resp_header("content-disposition", disposition(file_name))
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

  # The browser gets the file's own name, quoted and percent-encoded for the
  # characters a header cannot carry (RFC 6266).
  defp disposition(file_name) do
    ascii = file_name |> String.replace(~r/[^\x20-\x7E]/, "_") |> String.replace(~s("), "'")
    encoded = URI.encode(file_name, &URI.char_unreserved?/1)
    ~s(attachment; filename="#{ascii}"; filename*=UTF-8''#{encoded})
  end
end
