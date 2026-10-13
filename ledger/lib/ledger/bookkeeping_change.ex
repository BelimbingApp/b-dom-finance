defmodule Bilimbi.Finance.Ledger.BookkeepingChange do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  # One change to a company's controlled bookkeeping. The changes are
  # append-only and the latest decides; with none, a company is not
  # controlled. The database numbers and stamps a change (see the migration).
  schema "finance_ledger_bookkeeping_changes" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:change_number, :integer, read_after_writes: true)
    field(:controlled, :boolean)
    field(:reason, :string)
    field(:changed_by_user_id, :integer)
    field(:changed_by_impersonator_id, :integer)
    field(:changed_at, :utc_datetime_usec, read_after_writes: true)
  end

  @doc "Whether the latest change (or none) makes the company controlled."
  def controlled?(nil), do: false
  def controlled?(%__MODULE__{controlled: controlled}), do: controlled

  @doc "Casts `controlled` and `reason`; turning controlled bookkeeping off needs a reason."
  def changeset(change, attributes) do
    change
    |> cast(attributes, [:controlled, :reason])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:tenant_id, :company_id, :controlled, :changed_by_user_id])
    |> validate_length(:reason, max: 500)
    |> then(fn changeset ->
      if get_field(changeset, :controlled) == false,
        do: validate_required(changeset, :reason, message: "is required to turn this off"),
        else: changeset
    end)
  end
end
