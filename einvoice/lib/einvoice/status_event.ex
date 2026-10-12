defmodule Bilimbi.Finance.Einvoice.StatusEvent do
  @moduledoc false
  use Ecto.Schema

  schema "finance_einvoice_status_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:document_id, :integer)
    # The database numbers a document's events and stamps the time.
    field(:sequence, :integer, read_after_writes: true)
    field(:submission_id, :integer)
    field(:event, :string)
    field(:authority_status, :string)
    field(:submission_uid, :string)
    field(:document_uuid, :string)
    field(:long_id, :string)
    field(:reason, :string)
    field(:http_status, :integer)
    field(:response, :map)
    field(:actor_type, :string)
    field(:actor_user_id, :integer)
    field(:actor_impersonator_id, :integer)
    field(:system_principal, :string)
    field(:recorded_at, :utc_datetime_usec, read_after_writes: true)
  end
end
