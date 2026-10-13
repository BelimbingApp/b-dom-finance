defmodule Bilimbi.Finance.Attachments.AttachmentEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Attachments.Attachment

  # What happened to an attachment after its capture: `replaced` (naming the
  # attachment that took its place), `removed`, `retention_extended` (with
  # the new retain-until), `hold_placed`, or `hold_released`, each with the
  # actor, any impersonator, and the database's time. The database keeps at
  # most one `replaced` or `removed` per attachment.
  schema "finance_attachment_events" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:event, :string)
    field(:replacement_id, :integer)
    field(:retain_until, :utc_datetime_usec)
    field(:reason, :string)
    field(:actor_user_id, :integer)
    field(:actor_impersonator_id, :integer)
    field(:actor_system_principal, :string)
    field(:occurred_at, :utc_datetime_usec, read_after_writes: true)
    belongs_to(:attachment, Attachment)
  end

  def events, do: ~w(replaced removed retention_extended hold_placed hold_released)

  def changeset(event, attributes) do
    event
    |> cast(attributes, [:reason])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :attachment_id, :event, :actor_user_id])
    |> validate_inclusion(:event, events())
    |> validate_length(:reason, max: 500)
    |> validate_reason()
    |> unique_constraint(:attachment_id, name: :finance_attachment_events_standing_unique)
  end

  # A removal and a hold carry the reason the auditor asks for.
  defp validate_reason(changeset) do
    if get_field(changeset, :event) in ~w(removed hold_placed hold_released),
      do: validate_required(changeset, [:reason], message: "is required"),
      else: changeset
  end
end
