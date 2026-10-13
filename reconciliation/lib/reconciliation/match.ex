defmodule Bilimbi.Finance.Reconciliation.Match do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Bilimbi.Finance.Reconciliation.{MatchEntry, MatchEvent, MatchLine}

  # The database numbers and stamps a match (see the migration).
  schema "finance_reconciliation_matches" do
    field(:tenant_id, :integer)
    field(:company_id, :integer)
    field(:bank_account_id, :integer)
    field(:match_number, :integer, read_after_writes: true)
    field(:note, :string)
    field(:matched_by_user_id, :integer)
    field(:matched_by_impersonator_id, :integer)
    field(:matched_at, :utc_datetime_usec, read_after_writes: true)
    has_many(:lines, MatchLine, foreign_key: :match_id)
    has_many(:entries, MatchEntry, foreign_key: :match_id)
    has_many(:events, MatchEvent, foreign_key: :match_id)
  end

  def changeset(match, attributes) do
    match
    |> cast(attributes, [:note])
    |> update_change(:note, &blank_to_nil/1)
    |> validate_length(:note, max: 500)
    |> validate_required([:tenant_id, :company_id, :bank_account_id, :matched_by_user_id])
  end

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
