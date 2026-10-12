defmodule Bilimbi.Finance.Receivables.Text do
  @moduledoc false
  # Normalizers for `Ecto.Changeset.update_change/3`, which also hands over
  # the nil that clearing a field on an existing record casts to.

  def trim(nil), do: nil
  def trim(text), do: String.trim(text)

  def upcase(nil), do: nil
  def upcase(text), do: String.upcase(text)
end
