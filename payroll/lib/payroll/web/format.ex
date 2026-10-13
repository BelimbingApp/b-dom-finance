defmodule Bilimbi.Finance.Payroll.Web.Format do
  @moduledoc false
  # Amounts, labels, and refusals as the pages show them.

  @doc "An amount with thousands separators, rounded to the book's minor units."
  def money(nil, _minor_units), do: "—"

  def money(%Decimal{} = amount, minor_units) do
    rounded = Decimal.round(amount, minor_units)

    [whole | fraction] =
      rounded |> Decimal.abs() |> Decimal.to_string(:normal) |> String.split(".")

    grouped =
      whole
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(",", &Enum.join/1)
      |> String.reverse()

    sign = if Decimal.negative?(rounded), do: "-", else: ""
    sign <> Enum.join([grouped | fraction], ".")
  end

  @doc "A ledger account as `code name`, or its ID when the chart cannot be read."
  def account(_chart_by_id, nil), do: "—"

  def account(chart_by_id, id) do
    case Map.get(chart_by_id, id) do
      nil -> "##{id}"
      account -> "#{account.code} #{account.name}"
    end
  end

  @doc "A source kind as a noun."
  def source_kind("payroll_run"), do: "Payroll run"
  def source_kind("claim"), do: "Claim"
  def source_kind(other), do: other

  @doc "A mapping kind as a noun."
  def mapping_kind("component"), do: "Payroll component"
  def mapping_kind("claim_category"), do: "Claim category"
  def mapping_kind(other), do: other

  @doc "The badge kind of a posting standing."
  def standing_kind(%{posting: %{reversal: %{}}}), do: :warning
  def standing_kind(%{posting: %{}}), do: :success
  def standing_kind(%{last_failure: %{}}), do: :danger
  def standing_kind(_source), do: :neutral

  @doc "The word for a posting standing."
  def standing(%{posting: %{reversal: %{}}}), do: "reversed"
  def standing(%{posting: %{}}), do: "posted"
  def standing(%{last_failure: %{}}), do: "failed"
  def standing(_source), do: "not posted"

  @doc "The sentence a refusal from the facade reads as."
  def refusal(:unauthorized), do: "You do not have permission for that action."
  def refusal(:company_archived), do: "The company is archived; nothing can be changed."
  def refusal(:company_not_found), do: "The company could not be found."
  def refusal(:book_not_open), do: "The company's ledger book is not open yet."
  def refusal(:payroll_not_configured), do: "Set the posting accounts first."
  def refusal(:people_unavailable), do: "The payroll and claims source is not installed."
  def refusal(:source_not_found), do: "That run or claim could not be found."
  def refusal(:not_finalised), do: "Only a finalised run can be posted."
  def refusal(:already_posted), do: "It is already posted."
  def refusal(:already_reversed), do: "That posting is already reversed."
  def refusal(:posting_not_found), do: "The posting no longer exists."
  def refusal({:failed, reason}), do: "It failed: #{reason}."

  def refusal(%Ecto.Changeset{} = changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, options} ->
        Enum.reduce(options, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)
      |> Enum.map_join("; ", fn {field, messages} ->
        "#{field |> to_string() |> String.replace("_", " ")} #{Enum.join(List.wrap(messages), ", ")}"
      end)

    "Refused: #{errors}."
  end

  def refusal(reason), do: "It could not be done (#{inspect(reason)})."
end
