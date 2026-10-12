defmodule Bilimbi.Finance.Einvoice.Submission do
  @moduledoc false
  use Ecto.Schema

  schema "finance_einvoice_submissions" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:document_id, :integer)
    field(:environment, :string)
    field(:format, :string)
    field(:document_version, :string)
    field(:payload, :binary)
    field(:payload_sha256, :string)
    field(:actor_type, :string)
    field(:actor_user_id, :integer)
    field(:actor_impersonator_id, :integer)
    field(:system_principal, :string)
    field(:recorded_at, :utc_datetime_usec, read_after_writes: true)
  end
end
