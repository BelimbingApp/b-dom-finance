defmodule Bilimbi.Finance.Einvoice.Draft do
  @moduledoc """
  A document a caller asks to issue, as plain attributes, before it is
  recorded.

  The draft owns the shape every authority shares: the document's type and
  code number, its issue instant, currency and exchange rate, the buyer,
  optional payment and billing-period details, and the lines. It derives
  each line's amounts and the document's totals, so a caller sends
  quantities, prices, discounts, and tax rates and never a total. The
  authority then checks codes and its own rules (`Authority.validate/3`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Einvoice.Draft.{Line, Party}

  @primary_key false
  embedded_schema do
    field(:document_type, :string)
    field(:code_number, :string)
    field(:issued_at, :utc_datetime)
    field(:currency_code, :string)
    field(:exchange_rate, :decimal)
    field(:payment_means_code, :string)
    field(:payment_terms, :string)
    field(:billing_period_start, :date)
    field(:billing_period_end, :date)
    field(:billing_period_description, :string)
    embeds_one(:buyer, Party, on_replace: :update)
    embeds_many(:lines, Line, on_replace: :delete)
    # Derived from the lines.
    field(:line_extension_amount, :decimal)
    field(:tax_amount, :decimal)
  end

  @max_lines 1_000

  @doc """
  Casts and checks `attributes`. `now` is the issue instant when the caller
  gives none, and an issue instant later than `now` is refused.
  """
  @spec changeset(map(), DateTime.t()) :: Ecto.Changeset.t()
  def changeset(attributes, %DateTime{} = now) when is_map(attributes) do
    %__MODULE__{}
    |> cast(attributes, [
      :document_type,
      :code_number,
      :issued_at,
      :currency_code,
      :exchange_rate,
      :payment_means_code,
      :payment_terms,
      :billing_period_start,
      :billing_period_end,
      :billing_period_description
    ])
    |> update_change(:code_number, &String.trim/1)
    |> put_default_issued_at(now)
    |> cast_embed(:buyer, required: true)
    |> cast_embed(:lines, required: true)
    |> validate_required([:document_type, :code_number, :issued_at, :currency_code])
    |> validate_length(:code_number, min: 1, max: 50)
    |> validate_format(:currency_code, ~r/\A[A-Z]{3}\z/)
    |> validate_number(:exchange_rate, greater_than: 0)
    |> validate_length(:payment_terms, max: 300)
    |> validate_length(:billing_period_description, max: 50)
    |> validate_length(:lines, max: @max_lines)
    |> validate_change(:issued_at, fn :issued_at, issued_at ->
      if DateTime.compare(issued_at, now) == :gt,
        do: [issued_at: "cannot be in the future"],
        else: []
    end)
    |> validate_period()
    |> derive_totals()
  end

  defp put_default_issued_at(changeset, now) do
    if get_field(changeset, :issued_at),
      do: changeset,
      else: put_change(changeset, :issued_at, DateTime.truncate(now, :second))
  end

  defp validate_period(changeset) do
    start = get_field(changeset, :billing_period_start)
    finish = get_field(changeset, :billing_period_end)

    if start && finish && Date.compare(start, finish) == :gt,
      do: add_error(changeset, :billing_period_end, "cannot be before the period's start"),
      else: changeset
  end

  defp derive_totals(%{valid?: false} = changeset), do: changeset

  defp derive_totals(changeset) do
    lines = get_field(changeset, :lines)

    changeset
    |> put_change(:line_extension_amount, sum(lines, :line_extension_amount))
    |> put_change(:tax_amount, sum(lines, :tax_amount))
  end

  defp sum(lines, field),
    do: Enum.reduce(lines, Decimal.new("0.00"), &Decimal.add(Map.fetch!(&1, field), &2))
end
