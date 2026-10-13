defmodule Bilimbi.Finance.Reconciliation.Mapping do
  @moduledoc """
  A bank account's import mapping: which columns of its bank's CSV export
  hold a line's date, description, reference, amount (or debit and credit),
  and running balance, and how the bank writes dates and amounts.

  The mapping is a JSON map stored with the bank account, so each bank's
  export is configured data, never code. A column is named by its header
  text, or by its 1-based position when the file has no header row.

  | Key | Values | Default |
  | --- | --- | --- |
  | `delimiter` | `","`, `";"`, `"\\t"`, `"|"` | `","` |
  | `header_rows` | 0 to 20 rows before the data; the last is the header | `1` |
  | `date` | column | required |
  | `date_format` | one of `date_formats/0` | `"YYYY-MM-DD"` |
  | `description` | column | required |
  | `reference` | column or null | null |
  | `amount` | column: one signed column | either this or `debit` and `credit` |
  | `amount_sign` | `"deposits_positive"` or `"withdrawals_positive"` | `"deposits_positive"` |
  | `debit` | column: money out | with `credit` |
  | `credit` | column: money in | with `debit` |
  | `balance` | column or null: the running balance | null |
  | `decimal_separator` | `"."` or `","` | `"."` |
  """

  @delimiters [",", ";", "\t", "|"]
  @date_formats ~w(YYYY-MM-DD DD/MM/YYYY MM/DD/YYYY DD-MM-YYYY DD.MM.YYYY YYYY/MM/DD YYYYMMDD DD-MMM-YYYY DD-MMM-YY)
  @amount_signs ~w(deposits_positive withdrawals_positive)
  @decimal_separators [".", ","]
  @columns ~w(date description reference amount debit credit balance)
  @keys ~w(delimiter header_rows date_format amount_sign decimal_separator) ++ @columns
  @max_header_rows 20

  @months %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  def delimiters, do: @delimiters
  def date_formats, do: @date_formats
  def amount_signs, do: @amount_signs
  def decimal_separators, do: @decimal_separators

  @doc "A mapping with every key present and its defaults filled, or why it is invalid."
  @spec normalize(term()) :: {:ok, map()} | {:error, String.t()}
  def normalize(mapping) when is_map(mapping) do
    mapping = Map.new(mapping, fn {key, value} -> {to_string(key), value} end)

    with :ok <- known_keys(mapping),
         {:ok, delimiter} <- choice(mapping, "delimiter", @delimiters, ","),
         {:ok, header_rows} <- header_rows(mapping),
         {:ok, date_format} <- choice(mapping, "date_format", @date_formats, "YYYY-MM-DD"),
         {:ok, amount_sign} <- choice(mapping, "amount_sign", @amount_signs, "deposits_positive"),
         {:ok, separator} <- choice(mapping, "decimal_separator", @decimal_separators, "."),
         {:ok, columns} <- columns(mapping, header_rows),
         :ok <- amount_columns(columns) do
      {:ok,
       Map.merge(columns, %{
         "delimiter" => delimiter,
         "header_rows" => header_rows,
         "date_format" => date_format,
         "amount_sign" => amount_sign,
         "decimal_separator" => separator
       })}
    end
  end

  def normalize(_mapping), do: {:error, "must be a map of import settings"}

  defp known_keys(mapping) do
    case Map.keys(mapping) -- @keys do
      [] -> :ok
      unknown -> {:error, "has unknown settings: #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  defp choice(mapping, key, choices, default) do
    value = Map.get(mapping, key, default)

    cond do
      is_nil(value) -> {:ok, default}
      value in choices -> {:ok, value}
      true -> {:error, "#{key} must be one of #{Enum.map_join(choices, ", ", &inspect/1)}"}
    end
  end

  defp header_rows(mapping) do
    case Map.get(mapping, "header_rows", 1) do
      nil -> {:ok, 1}
      rows when is_integer(rows) and rows in 0..@max_header_rows -> {:ok, rows}
      _other -> {:error, "header_rows must be a whole number from 0 to #{@max_header_rows}"}
    end
  end

  defp columns(mapping, header_rows) do
    Enum.reduce_while(@columns, {:ok, %{}}, fn key, {:ok, acc} ->
      case column(Map.get(mapping, key), header_rows) do
        {:ok, nil} when key in ~w(date description) ->
          {:halt, {:error, "#{key} column is required"}}

        {:ok, column} ->
          {:cont, {:ok, Map.put(acc, key, column)}}

        :error when header_rows == 0 ->
          {:halt,
           {:error,
            "#{key} must be a column position (1, 2, ...) because the file has no header row"}}

        :error ->
          {:halt, {:error, "#{key} must be a column header or position"}}
      end
    end)
  end

  defp column(nil, _header_rows), do: {:ok, nil}
  defp column("", _header_rows), do: {:ok, nil}

  defp column(position, _header_rows) when is_integer(position) and position > 0,
    do: {:ok, position}

  defp column(name, header_rows) when is_binary(name) and header_rows > 0 do
    case String.trim(name) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp column(_other, _header_rows), do: :error

  defp amount_columns(%{"amount" => amount, "debit" => debit, "credit" => credit}) do
    cond do
      amount && (debit || credit) ->
        {:error, "names an amount column and debit or credit columns; use one or the other"}

      amount ->
        :ok

      debit && credit ->
        :ok

      true ->
        {:error, "needs an amount column, or both a debit and a credit column"}
    end
  end

  @doc "Reads a column's cell from a parsed row, by header position or 1-based index; an unmapped column is nil."
  def cell(_row, _headers, nil), do: nil

  def cell(row, _headers, column) when is_integer(column) do
    Enum.at(row, column - 1)
  end

  def cell(row, headers, column) when is_binary(column) do
    case Enum.find_index(headers, &(String.trim(&1) == column)) do
      nil -> nil
      index -> Enum.at(row, index)
    end
  end

  @doc "The header names a mapping needs that `headers` does not have."
  def missing_headers(mapping, headers) do
    trimmed = Enum.map(headers, &String.trim/1)

    for key <- @columns,
        column = Map.get(mapping, key),
        is_binary(column),
        column not in trimmed,
        do: column
  end

  @doc "Parses a date written in `format`."
  @spec parse_date(String.t(), String.t()) :: {:ok, Date.t()} | :error
  def parse_date(text, format) when is_binary(text) do
    parts = text |> String.trim() |> String.split(~r/[-\/. ]/, trim: true)

    result =
      case {format, parts} do
        {"YYYY-MM-DD", [y, m, d]} -> date(y, m, d)
        {"YYYY/MM/DD", [y, m, d]} -> date(y, m, d)
        {"DD/MM/YYYY", [d, m, y]} -> date(y, m, d)
        {"DD-MM-YYYY", [d, m, y]} -> date(y, m, d)
        {"DD.MM.YYYY", [d, m, y]} -> date(y, m, d)
        {"MM/DD/YYYY", [m, d, y]} -> date(y, m, d)
        {"YYYYMMDD", [<<y::binary-4, m::binary-2, d::binary-2>>]} -> date(y, m, d)
        {"DD-MMM-YYYY", [d, mmm, y]} -> month_name_date(y, mmm, d)
        {"DD-MMM-YY", [d, mmm, <<_::binary-2>> = yy]} -> month_name_date("20" <> yy, mmm, d)
        _other -> :error
      end

    result
  end

  def parse_date(_text, _format), do: :error

  defp month_name_date(y, mmm, d) do
    case Map.fetch(@months, String.downcase(mmm)) do
      {:ok, month} -> date(y, Integer.to_string(month), d)
      :error -> :error
    end
  end

  defp date(y, m, d) do
    with {year, ""} when year in 1900..2200 <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d),
         {:ok, date} <- Date.new(year, month, day) do
      {:ok, date}
    else
      _other -> :error
    end
  end

  @doc """
  Parses an amount as banks write them: thousands separators, a leading or
  trailing minus, parentheses, or a trailing `CR` (in) or `DR` (out) marker.
  A blank cell is `{:ok, nil}`.
  """
  @spec parse_amount(String.t() | nil, String.t()) :: {:ok, Decimal.t() | nil} | :error
  def parse_amount(nil, _separator), do: {:ok, nil}

  def parse_amount(text, separator) when is_binary(text) do
    trimmed = text |> String.trim() |> String.upcase()

    if trimmed == "" do
      {:ok, nil}
    else
      {sign, body} = sign_and_body(trimmed)
      digits = body |> String.replace(~r/[\s']/u, "") |> decimal_point(separator)

      case Regex.match?(~r/^\d+(\.\d+)?$/, digits) and Decimal.parse(digits) do
        {decimal, ""} -> {:ok, if(sign == :negative, do: Decimal.negate(decimal), else: decimal)}
        _other -> :error
      end
    end
  end

  def parse_amount(_text, _separator), do: :error

  defp sign_and_body(text) do
    cond do
      String.starts_with?(text, "(") and String.ends_with?(text, ")") ->
        {:negative, String.slice(text, 1..-2//1)}

      String.ends_with?(text, "DR") ->
        {:negative, text |> String.trim_trailing("DR") |> String.trim()}

      String.ends_with?(text, "CR") ->
        {:positive, text |> String.trim_trailing("CR") |> String.trim()}

      String.starts_with?(text, "-") ->
        {:negative, String.trim_leading(text, "-")}

      String.ends_with?(text, "-") ->
        {:negative, String.trim_trailing(text, "-")}

      String.starts_with?(text, "+") ->
        {:positive, String.trim_leading(text, "+")}

      true ->
        {:positive, text}
    end
  end

  defp decimal_point(digits, "."), do: String.replace(digits, ",", "")

  defp decimal_point(digits, ","),
    do: digits |> String.replace(".", "") |> String.replace(",", ".")
end
