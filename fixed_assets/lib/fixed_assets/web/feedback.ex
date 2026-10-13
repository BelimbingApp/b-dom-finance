defmodule Bilimbi.Finance.FixedAssets.Web.Feedback do
  @moduledoc false
  def message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {text, opts} ->
      Enum.reduce(opts, text, fn {key, value}, text ->
        String.replace(text, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  def message(:unauthorized), do: "You do not have permission for this action."
  def message(:company_archived), do: "This company is archived and cannot be changed."
  def message(:period_closed), do: "The period is closed. Choose an open period."

  def message(:period_not_found),
    do: "Open a fiscal year covering this month before running depreciation."

  def message(:depreciation_required),
    do: "Post depreciation through the last completed month before disposing of this asset."

  def message(:dependent_postings),
    do: "Reverse later depreciation runs and standing disposals first."

  def message(:later_activity),
    do: "This date precedes recorded asset activity. Choose a later date."

  def message(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  def message(_reason), do: "The operation was refused. Refresh this page and review the record."
end
