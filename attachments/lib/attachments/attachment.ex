defmodule Bilimbi.Finance.Attachments.Attachment do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Attachments.AttachmentEvent

  # One source document captured for a Finance record: the link from the
  # record (`source`, `document_id`) to the records-grade artifact holding
  # the bytes, with the file's facts and the retention it was given. The
  # database numbers and stamps it (see the migration); its events decide
  # whether it still stands.
  schema "finance_attachments" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:attachment_number, :integer, read_after_writes: true)
    field(:source, :string)
    field(:source_module, :string)
    field(:document_id, :integer)
    field(:document_label, :string)
    field(:document_date, :date)
    field(:artifact_id, Ecto.UUID)
    field(:file_name, :string)
    field(:content_type, :string)
    field(:byte_size, :integer)
    field(:sha256, :string)
    field(:retention_years, :integer)
    field(:retain_until, :utc_datetime_usec)
    field(:captured_by_user_id, :integer)
    field(:captured_by_impersonator_id, :integer)
    field(:captured_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:events, AttachmentEvent)
  end

  @doc "An attachment stands until a `replaced` or `removed` event ends it."
  def status(%__MODULE__{events: events}) when is_list(events) do
    case Enum.find(events, &(&1.event in ~w(replaced removed))) do
      nil -> "standing"
      %AttachmentEvent{event: event} -> event
    end
  end

  def statuses, do: ~w(standing replaced removed)

  def changeset(attachment, attributes) do
    attachment
    |> cast(attributes, [
      :source,
      :source_module,
      :document_id,
      :document_label,
      :document_date,
      :artifact_id,
      :file_name,
      :content_type,
      :byte_size,
      :sha256,
      :retention_years,
      :retain_until
    ])
    |> update_change(:file_name, &String.trim/1)
    |> update_change(:document_label, &String.trim/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :source,
      :source_module,
      :document_id,
      :document_label,
      :document_date,
      :artifact_id,
      :file_name,
      :content_type,
      :byte_size,
      :sha256,
      :retention_years,
      :retain_until,
      :captured_by_user_id
    ])
    |> validate_length(:source, min: 1, max: 100)
    |> validate_length(:document_label, min: 1, max: 100)
    |> validate_length(:file_name, min: 1, max: 255)
    |> validate_length(:content_type, min: 1, max: 255)
    |> validate_number(:document_id, greater_than: 0)
    |> validate_number(:byte_size, greater_than: 0)
    |> validate_number(:retention_years, greater_than: 0)
    |> validate_format(:sha256, ~r/^[0-9a-f]{64}$/)
    |> unique_constraint(:artifact_id, name: :finance_attachments_artifact_unique)
  end
end
