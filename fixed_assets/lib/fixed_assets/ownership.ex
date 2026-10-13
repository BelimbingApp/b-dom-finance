defmodule Bilimbi.Finance.FixedAssets.Ownership do
  @moduledoc false
  # How this module names itself to the ledger as the owner of the entries
  # it posts (`Bilimbi.Finance.Ledger.post_entry/4`'s `owner` option), so
  # the ledger refuses a second entry for a record and a reversal from
  # anywhere but this module (`Ledger.reverse_owned_entry/5`). An asset's
  # acquisition entry is not this module's: it belongs to whoever posted it.

  alias Bilimbi.Base.Repo

  @module_id "finance/fixed_assets"

  @doc "This module's descriptor ID, the `owner_module` of every entry it posts."
  def module_id, do: @module_id

  @doc """
  The owner identity of a ledger entry this module posted: a depreciation
  run (`run:<id>`), or an event (`event:<id>`: a disposal, a void's mirror
  of charges, or the mirror a partial run reversal posts). A run's reversal
  names the run; a disposal's reversal names the disposal event.
  """
  def owner(kind, id) when kind in [:run, :event] and is_integer(id),
    do: %{module: @module_id, record: "#{kind}:#{id}"}

  @doc """
  The ID the next inserted row of `schema` will take, drawn now, so a
  record can name itself as an entry's owner before it is inserted.
  """
  def next_id(schema) do
    %{rows: [[id]]} =
      Repo.query!("SELECT nextval(pg_get_serial_sequence($1, 'id'))", [
        schema.__schema__(:source)
      ])

    id
  end
end
