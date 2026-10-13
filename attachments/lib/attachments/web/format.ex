defmodule Bilimbi.Finance.Attachments.Web.Format do
  @moduledoc false
  # How the attachments pages word refusals, sizes, and hashes.

  alias Ecto.Changeset

  @doc "A refusal from the facade, as the page tells it."
  def refusal(:unauthorized), do: "You are not allowed to do that."
  def refusal(:company_not_found), do: "This company cannot be read with your current access."
  def refusal(:company_archived), do: "This company is archived; nothing more is recorded."
  def refusal(:not_found), do: "There is no such record for this company."
  def refusal(:attachment_not_found), do: "There is no such attachment for this company."
  def refusal(:attachment_not_standing), do: "That attachment was already replaced or removed."
  def refusal(:document_final), do: "The record is final; its attachments are kept as they are."
  def refusal(:document_undated), do: "The record has no date to count the retention from."
  def refusal(:invalid_file_name), do: "The file needs a name of at most 255 characters."
  def refusal(:empty_file), do: "The file is empty."
  def refusal(:file_too_large), do: "The file is larger than this page accepts."
  def refusal(:invalid_content_type), do: "The file's type could not be read."
  def refusal(:invalid_size), do: "The file is larger than Base Artifacts accepts."
  def refusal(:reason_required), do: "Give a reason."
  def refusal(:retention_not_lengthened), do: "Retention is only ever lengthened."

  def refusal(:retention_not_extended),
    do: "The new retain-until must be later than the current one."

  def refusal(:source_unavailable), do: "The module that owns this record is not mounted."
  def refusal(:invalid_source), do: "That kind of record cannot take attachments."

  def refusal(:retention_not_configured),
    do: "Base Artifacts has no storage root configured; an operator sets it in Operator Settings."

  def refusal(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field |> to_string() |> String.replace("_", " ")} #{Enum.join(messages, ", ")}"
    end)
  end

  def refusal(other), do: "The action was refused: #{inspect(other)}."

  @doc "A byte count a person reads: `12.3 KB`, `4.0 MB`."
  def bytes(size) when is_integer(size) and size < 1024, do: "#{size} B"

  def bytes(size) when is_integer(size) and size < 1024 * 1024,
    do: "#{one_decimal(size / 1024)} KB"

  def bytes(size) when is_integer(size), do: "#{one_decimal(size / (1024 * 1024))} MB"
  def bytes(_other), do: ""

  @doc "The first and last characters of a SHA-256, for a table cell; the title holds it whole."
  def short_hash(<<first::binary-size(8), _::binary-size(48), last::binary-size(8)>>),
    do: "#{first}…#{last}"

  def short_hash(other), do: to_string(other)

  @doc "The date of a retain-until, which is the end of that day in UTC."
  def retain_until(%DateTime{} = until), do: until |> DateTime.to_date() |> Date.to_iso8601()
  def retain_until(_other), do: ""

  defp one_decimal(value), do: :erlang.float_to_binary(value, decimals: 1)
end
