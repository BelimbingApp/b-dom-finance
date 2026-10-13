defmodule Bilimbi.Finance.Reports.Serialization do
  @moduledoc false

  # Issued content is a durable JSON contract: string keys, exact decimal
  # strings, ISO dates and UTC timestamps. No floats or Elixir term encoding.
  def value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  def value(%Date{} = value), do: Date.to_iso8601(value)
  def value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value) <> "Z"
  def value(value) when is_struct(value), do: value |> Map.from_struct() |> value()

  def value(value) when is_map(value),
    do: Map.new(value, fn {key, v} -> {to_string(key), value(v)} end)

  def value(value) when is_list(value), do: Enum.map(value, &value/1)
  def value(value) when is_tuple(value), do: value |> Tuple.to_list() |> value()

  def value(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  def value(value), do: value

  def csv_row(values), do: Enum.map_join(values, ",", &cell/1) <> "\r\n"

  # Typed numbers stay exact; every text field is defended, even when its
  # leading formula character is preceded by whitespace/control characters.
  defp cell(%Decimal{} = number), do: Decimal.to_string(number, :normal)
  defp cell(number) when is_integer(number), do: Integer.to_string(number)
  defp cell(nil), do: "\"\""

  defp cell(v) do
    text =
      case value(v) do
        v when is_binary(v) -> v
        v -> Jason.encode!(v)
      end

    text =
      if Regex.match?(~r/^[\s\x00-\x1f]*[=+\-@]/u, text) or
           String.starts_with?(text, ["\t", "\r", "\n"]), do: "'" <> text, else: text

    "\"" <> String.replace(text, "\"", "\"\"") <> "\""
  end
end
