defmodule Bilimbi.Finance.Reconciliation.Csv do
  @moduledoc false
  # A small RFC 4180 reader for bank exports: one configurable delimiter,
  # double-quoted fields with doubled quotes inside them, fields that span
  # lines, CRLF or LF line ends, and a UTF-8 byte-order mark. Nothing here
  # is specific to a bank.

  @max_bytes 5 * 1024 * 1024

  @doc "The largest file the reader accepts, in bytes."
  def max_bytes, do: @max_bytes

  @doc """
  The file's rows as lists of strings. Blank rows are dropped. A field quote
  left open is `{:error, {:unterminated_quote, row}}`; a quote in the middle
  of an unquoted field is `{:error, {:stray_quote, row}}`.
  """
  @spec parse(binary(), String.t()) :: {:ok, [[String.t()]]} | {:error, term()}
  def parse(content, _delimiter) when byte_size(content) > @max_bytes, do: {:error, :too_large}

  def parse(content, delimiter) when is_binary(content) and is_binary(delimiter) do
    if String.valid?(content) do
      content |> strip_bom() |> rows(delimiter)
    else
      {:error, :not_utf8}
    end
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  defp rows(content, delimiter) do
    case read(content, delimiter, "", [], [], 1, :field) do
      {:ok, rows} -> {:ok, Enum.reject(rows, &blank_row?/1)}
      error -> error
    end
  end

  defp blank_row?(row), do: Enum.all?(row, &(String.trim(&1) == ""))

  # read(rest, delimiter, current field, current row, finished rows, row
  # number, state): :field is outside quotes, :quoted inside them, and
  # :closed is just after a closing quote, where only a delimiter or a line
  # end may follow.
  defp read(<<>>, _delimiter, field, row, rows, _row_number, state) when state != :quoted do
    rows = if field == "" and row == [], do: rows, else: [finish(field, row) | rows]
    {:ok, Enum.reverse(rows)}
  end

  defp read(<<>>, _delimiter, _field, _row, _rows, row_number, :quoted),
    do: {:error, {:unterminated_quote, row_number}}

  defp read(<<"\"", rest::binary>>, delimiter, "", row, rows, row_number, :field),
    do: read(rest, delimiter, "", row, rows, row_number, :quoted)

  defp read(<<"\"\"", rest::binary>>, delimiter, field, row, rows, row_number, :quoted),
    do: read(rest, delimiter, field <> "\"", row, rows, row_number, :quoted)

  defp read(<<"\"", rest::binary>>, delimiter, field, row, rows, row_number, :quoted),
    do: read(rest, delimiter, field, row, rows, row_number, :closed)

  defp read(<<"\"", _rest::binary>>, _delimiter, _field, _row, _rows, row_number, _state),
    do: {:error, {:stray_quote, row_number}}

  defp read(<<"\r\n", rest::binary>>, delimiter, field, row, rows, row_number, state)
       when state != :quoted,
       do: read(rest, delimiter, "", [], [finish(field, row) | rows], row_number + 1, :field)

  defp read(<<"\n", rest::binary>>, delimiter, field, row, rows, row_number, state)
       when state != :quoted,
       do: read(rest, delimiter, "", [], [finish(field, row) | rows], row_number + 1, :field)

  defp read(<<"\r", rest::binary>>, delimiter, field, row, rows, row_number, state)
       when state != :quoted,
       do: read(rest, delimiter, "", [], [finish(field, row) | rows], row_number + 1, :field)

  defp read(rest, delimiter, field, row, rows, row_number, state) when state != :quoted do
    size = byte_size(delimiter)

    case rest do
      <<^delimiter::binary-size(^size), tail::binary>> ->
        read(tail, delimiter, "", [field | row], rows, row_number, :field)

      <<_char::utf8, _tail::binary>> when state == :closed ->
        {:error, {:stray_quote, row_number}}

      <<char::utf8, tail::binary>> ->
        read(tail, delimiter, field <> <<char::utf8>>, row, rows, row_number, :field)
    end
  end

  # A row is one record, however many lines a quoted field spans, so an
  # error names the record that opened the quote.
  defp read(<<char::utf8, rest::binary>>, delimiter, field, row, rows, row_number, :quoted),
    do: read(rest, delimiter, field <> <<char::utf8>>, row, rows, row_number, :quoted)

  defp finish(field, row), do: Enum.reverse([field | row])
end
