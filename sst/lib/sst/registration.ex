defmodule Bilimbi.Finance.Sst.Registration do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Sst.Text

  @bases ~w(payment invoice)

  # A number as the department issues it: a station letter and two digits,
  # the year and month of registration, and an eight-digit serial.
  @number ~r/^[A-Z][0-9]{2}-[0-9]{4}-[0-9]{8}$/

  # The database numbers and stamps a version (see the migration).
  schema "finance_sst_registrations" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:version, :integer, read_after_writes: true)
    field(:sales_tax_number, :string)
    field(:service_tax_number, :string)
    field(:period_months, :integer, default: 2)
    field(:period_start, :date)
    field(:service_tax_basis, :string, default: "payment")
    field(:reason, :string)
    field(:recorded_by_user_id, :integer)
    field(:recorded_by_impersonator_id, :integer)
    field(:recorded_at, :utc_datetime_usec, read_after_writes: true)
  end

  def bases, do: @bases

  def changeset(registration, attributes) do
    registration
    |> cast(attributes, [
      :sales_tax_number,
      :service_tax_number,
      :period_months,
      :period_start,
      :service_tax_basis,
      :reason
    ])
    |> update_change(:sales_tax_number, &upcase/1)
    |> update_change(:service_tax_number, &upcase/1)
    |> update_change(:reason, &Text.blank_to_nil/1)
    |> validate_required([
      :tenant_id,
      :company_id,
      :period_months,
      :period_start,
      :service_tax_basis,
      :recorded_by_user_id
    ])
    |> validate_format(:sales_tax_number, @number, message: "is not shaped like A00-0000-00000000")
    |> validate_format(:service_tax_number, @number,
      message: "is not shaped like A00-0000-00000000"
    )
    |> validate_number(:period_months, greater_than_or_equal_to: 1, less_than_or_equal_to: 12)
    |> validate_inclusion(:service_tax_basis, @bases)
    |> validate_length(:reason, max: 500)
    |> validate_number_present()
  end

  defp validate_number_present(changeset) do
    if is_nil(get_field(changeset, :sales_tax_number)) and
         is_nil(get_field(changeset, :service_tax_number)),
       do: add_error(changeset, :sales_tax_number, "or a service tax number is needed"),
       else: changeset
  end

  defp upcase(value) do
    case Text.blank_to_nil(value) do
      nil -> nil
      text -> String.upcase(text)
    end
  end
end
