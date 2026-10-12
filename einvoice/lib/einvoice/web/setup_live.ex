defmodule Bilimbi.Finance.Einvoice.Web.SetupLive do
  @moduledoc """
  The signed-in company's e-invoicing setup: its environment, which
  credentials it holds, its certificate's details and expiry, what its
  supplier profile still lacks, and a "Test connection" check.

  The values themselves are company-scoped settings in the
  `finance.einvoice` group, edited on the Settings screen with the company
  chosen there, which masks secrets and reveals them only after a password
  check. This page reads `Einvoice.setup/3`, which never returns a secret.
  """

  use Bilimbi.Base.UI, :live_view

  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Einvoice

  @field_labels %{
    tax_id: "supplier TIN",
    registration_number: "registration number",
    industry_code: "industry classification code",
    business_activity: "business activity",
    phone: "phone",
    address_line1: "address line 1",
    city: "city",
    state_code: "state code",
    country_code: "country code"
  }

  @impl true
  def mount(_params, _session, socket) do
    company_id = Scope.actor(socket.assigns.current_scope.scope).company_id

    {:ok,
     socket
     |> assign(:page_title, "E-invoice Setup")
     |> assign(:active_nav, "finance.einvoice.setup")
     |> assign(:company_id, company_id)
     |> load_setup()}
  end

  @impl true
  def handle_event("test_connection", _params, socket) do
    scope = socket.assigns.current_scope.scope

    socket =
      case Einvoice.test_connection(scope, socket.assigns.company_id) do
        :ok ->
          put_flash(socket, :info, "Connected: the authority accepted the #{environment(socket)} credentials.")

        {:error, reason} ->
          put_flash(socket, :error, connection_message(reason))
      end

    {:noreply, load_setup(socket)}
  end

  defp load_setup(socket) do
    case Einvoice.setup(socket.assigns.current_scope.scope, socket.assigns.company_id) do
      {:ok, setup} -> assign(socket, :setup, setup)
      {:error, _reason} -> assign(socket, :setup, nil)
    end
  end

  defp environment(socket), do: socket.assigns.setup && socket.assigns.setup.environment

  defp connection_message(:missing_credentials),
    do: "Connection not tested: set the client ID and client secret for this environment first."

  defp connection_message(:unauthorized),
    do: "Connection not tested: you do not have permission to manage e-invoice settings."

  defp connection_message({:http, status, _body}),
    do: "The authority refused the login (HTTP #{status}). Check the client ID and secret."

  defp connection_message({:retry_after, seconds, _status, _body}),
    do: "The authority is limiting logins. Try again in #{seconds} seconds."

  defp connection_message({:transport, _exception}),
    do: "The authority could not be reached. Try again later."

  defp connection_message(_reason), do: "The connection test failed."

  defp missing_wording(fields), do: Enum.map_join(fields, ", ", &Map.fetch!(@field_labels, &1))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={@active_nav}>
      <.page id="einvoice-setup" variant={:detail}>
        <.header>
          E-invoice Setup
          <:subtitle>Credentials, certificate, and supplier profile for this company.</:subtitle>
          <:actions>
            <.link id="einvoice-edit-settings" navigate={~p"/system/settings"}>
              Edit settings
            </.link>
          </:actions>
        </.header>

        <.empty_state
          :if={is_nil(@setup)}
          id="einvoice-setup-unavailable"
          title="Setup unavailable"
          reason="This company's e-invoice setup cannot be read with your current access."
        />

        <%= if @setup do %>
          <.card
            id="einvoice-connection"
            inner_class="p-5 sm:p-6"
            role="region"
            aria-labelledby="einvoice-connection-heading"
          >
            <.section_heading id="einvoice-connection-heading" title="Connection">
              <:description>
                Values are edited under Settings, in the e-invoice group, with this company chosen.
              </:description>
            </.section_heading>
            <.list id="einvoice-connection-facts">
              <:item title="Environment">{@setup.environment}</:item>
              <:item title="Client ID">{if @setup.client_id?, do: "Set", else: "Not set"}</:item>
              <:item title="Client secret">
                {if @setup.client_secret?, do: "Set", else: "Not set"}
              </:item>
              <:item title="Client secret expires">
                {if @setup.client_secret_expires_on,
                  do: Date.to_iso8601(@setup.client_secret_expires_on),
                  else: "Not recorded"}
              </:item>
            </.list>
            <.button id="einvoice-test-connection" phx-click="test_connection">
              Test connection
            </.button>
          </.card>

          <.card
            id="einvoice-certificate"
            inner_class="p-5 sm:p-6"
            role="region"
            aria-labelledby="einvoice-certificate-heading"
          >
            <.section_heading id="einvoice-certificate-heading" title="Signing certificate" />
            <.empty_state
              :if={is_nil(@setup.certificate)}
              id="einvoice-certificate-missing"
              title="No certificate"
              reason="Store the company's certificate and private key as PEM in the e-invoice settings."
            />
            <.empty_state
              :if={@setup.certificate && @setup.certificate[:invalid?]}
              id="einvoice-certificate-invalid"
              title="Certificate unreadable"
              reason="The stored certificate is not a PEM-encoded X.509 certificate. Store it again."
            />
            <.list
              :if={@setup.certificate && !@setup.certificate[:invalid?]}
              id="einvoice-certificate-facts"
            >
              <:item title="Issuer">{@setup.certificate.issuer_name}</:item>
              <:item title="Serial number">{@setup.certificate.serial_number}</:item>
              <:item title="TIN on certificate">
                {@setup.certificate.organization_identifier || "—"}
              </:item>
              <:item title="Registration number on certificate">
                {@setup.certificate.registration_number || "—"}
              </:item>
              <:item title="Valid until">
                <.datetime id="einvoice-certificate-expiry" value={@setup.certificate.not_after} />
              </:item>
              <:item title="Days left">{@setup.certificate.days_until_expiry}</:item>
              <:item title="Private key">
                {if @setup.certificate.private_key_matches?,
                  do: "Matches the certificate",
                  else: "Missing or does not match the certificate"}
              </:item>
              <:item title="Supplier TIN">
                {if @setup.tax_id_matches_certificate?,
                  do: "Matches the certificate",
                  else: "Differs from the certificate"}
              </:item>
            </.list>
          </.card>

          <.card
            :if={@setup.expiring != []}
            id="einvoice-expiry-alert"
            inner_class="p-5 sm:p-6"
            role="alert"
          >
            <.section_heading id="einvoice-expiry-heading" title="Renew soon">
              <:description>
                {Enum.map_join(@setup.expiring, " and ", fn
                  :certificate -> "The certificate"
                  :client_secret -> "The client secret"
                end)} expires within {@setup.expiry_alert_days} days or has expired. Submissions fail once it does.
              </:description>
            </.section_heading>
          </.card>

          <.card
            id="einvoice-supplier"
            inner_class="p-5 sm:p-6"
            role="region"
            aria-labelledby="einvoice-supplier-heading"
          >
            <.section_heading id="einvoice-supplier-heading" title="Supplier profile" />
            <p :if={@setup.supplier_missing == []} id="einvoice-supplier-complete">
              Every field a document needs is set.
            </p>
            <.empty_state
              :if={@setup.supplier_missing != []}
              id="einvoice-supplier-incomplete"
              title="Supplier profile incomplete"
              reason={"Set #{missing_wording(@setup.supplier_missing)} in the e-invoice settings before issuing documents."}
            />
          </.card>
        <% end %>
      </.page>
    </Layouts.app>
    """
  end
end
