defmodule Bilimbi.Finance.Reconciliation.Import do
  @moduledoc false
  # Statement import: a bank's CSV export read through the bank account's
  # mapping into an immutable statement and its lines. The facade authorizes
  # the call and holds the company lock.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Reconciliation.{Csv, Mapping, Records, Statement, StatementLine}

  @max_lines 10_000

  @doc "The most lines one statement may hold."
  def max_lines, do: @max_lines

  @doc """
  Imports `content`, the bytes of `file_name`, as a statement of the bank
  account. Refuses, whole, a file already imported (`{:duplicate_file,
  statement_number}`), a line already imported (`{:duplicate_lines, [...]}`),
  a file whose rows do not read through the mapping (`{:invalid_lines,
  [...]}`, `{:missing_headers, [...]}`, `:no_lines`), and a running balance
  that does not follow from the amounts (`{:running_balance_mismatch, row}`).
  """
  def import_statement(scope, company_id, bank_account, book, attributes) do
    file_name = Records.fetch(attributes, :file_name)
    content = Records.fetch(attributes, :content)

    with :ok <- file_attributes(file_name, content),
         sha256 = hash(content),
         :ok <- fresh_file(scope, company_id, sha256),
         {:ok, lines, skipped} <- read(content, bank_account.import_mapping, book.minor_units),
         {:ok, lines} <- ordered(lines, bank_account.import_mapping),
         lines = fingerprinted(lines),
         :ok <- fresh_lines(scope, company_id, bank_account.id, lines) do
      insert(scope, company_id, bank_account, file_name, sha256, lines, skipped)
    end
  end

  defp file_attributes(file_name, content) do
    cond do
      not (is_binary(file_name) and String.trim(file_name) != "" and
               String.length(file_name) <= 255) ->
        {:error, :invalid_file_name}

      not is_binary(content) ->
        {:error, :invalid_content}

      true ->
        :ok
    end
  end

  defp hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp fresh_file(scope, company_id, sha256) do
    case Statement
         |> Records.query(scope, company_id)
         |> where([s], s.file_sha256 == ^sha256)
         |> select([s], s.statement_number)
         |> Repo.one() do
      nil -> :ok
      number -> {:error, {:duplicate_file, number}}
    end
  end

  ## Reading

  defp read(content, mapping, minor_units) do
    with {:ok, rows} <- Csv.parse(content, mapping["delimiter"]),
         {headers, data} <- split_header(rows, mapping["header_rows"]),
         :ok <- headers_present(mapping, headers),
         :ok <- within_size(data) do
      parsed =
        data
        |> Enum.with_index(mapping["header_rows"] + 1)
        |> Enum.map(fn {row, number} -> parse_row(row, number, headers, mapping, minor_units) end)

      errors = for {:error, error} <- parsed, do: error

      cond do
        errors != [] -> {:error, {:invalid_lines, errors}}
        true -> lines_and_skipped(parsed)
      end
    end
  end

  defp lines_and_skipped(parsed) do
    lines = for {:ok, line} <- parsed, do: line
    skipped = Enum.count(parsed, &(&1 == :skip))
    if lines == [], do: {:error, :no_lines}, else: {:ok, lines, skipped}
  end

  defp split_header(rows, 0), do: {[], rows}

  defp split_header(rows, header_rows) do
    {header, data} = Enum.split(rows, header_rows)
    {List.last(header) || [], data}
  end

  defp headers_present(mapping, headers) do
    case Mapping.missing_headers(mapping, headers) do
      [] -> :ok
      missing -> {:error, {:missing_headers, missing}}
    end
  end

  defp within_size(data) do
    if length(data) > @max_lines, do: {:error, {:too_many_lines, @max_lines}}, else: :ok
  end

  defp parse_row(row, number, headers, mapping, minor_units) do
    cell = fn key -> Mapping.cell(row, headers, mapping[key]) end

    with {:ok, date} <- parse_date(cell.("date"), mapping["date_format"], number),
         {:ok, description} <- parse_description(cell.("description"), number),
         {:ok, amount} <- parse_amount(cell, mapping, number),
         :ok <- precision(amount, minor_units, number),
         {:ok, balance} <- parse_balance(cell.("balance"), mapping, number) do
      if Decimal.equal?(amount, 0) do
        :skip
      else
        {:ok,
         %{
           row: number,
           line_date: date,
           description: description,
           reference: reference(cell.("reference")),
           amount: amount,
           running_balance: balance
         }}
      end
    end
  end

  defp parse_date(text, format, number) do
    case Mapping.parse_date(text || "", format) do
      {:ok, date} -> {:ok, date}
      :error -> {:error, %{row: number, message: "date #{inspect(text)} is not #{format}"}}
    end
  end

  defp parse_description(text, number) do
    case String.trim(text || "") do
      "" -> {:error, %{row: number, message: "description is blank"}}
      trimmed -> {:ok, String.slice(trimmed, 0, 500)}
    end
  end

  defp reference(text) do
    case String.trim(text || "") do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 100)
    end
  end

  defp parse_amount(cell, %{"amount" => column} = mapping, number) when not is_nil(column) do
    case Mapping.parse_amount(cell.("amount"), mapping["decimal_separator"]) do
      {:ok, nil} ->
        {:error, %{row: number, message: "amount is blank"}}

      {:ok, amount} ->
        {:ok,
         if(mapping["amount_sign"] == "withdrawals_positive",
           do: Decimal.negate(amount),
           else: amount
         )}

      :error ->
        {:error, %{row: number, message: "amount #{inspect(cell.("amount"))} is not a number"}}
    end
  end

  defp parse_amount(cell, mapping, number) do
    separator = mapping["decimal_separator"]

    with {:ok, debit} <- side(cell.("debit"), "debit", separator, number),
         {:ok, credit} <- side(cell.("credit"), "credit", separator, number) do
      # The column gives the direction; a bank that brackets or signs the
      # figure in it is saying the same thing twice.
      if not Decimal.equal?(debit, 0) and not Decimal.equal?(credit, 0),
        do: {:error, %{row: number, message: "both debit and credit hold an amount"}},
        else: {:ok, Decimal.sub(Decimal.abs(credit), Decimal.abs(debit))}
    end
  end

  defp side(text, name, separator, number) do
    case Mapping.parse_amount(text, separator) do
      {:ok, nil} -> {:ok, Decimal.new(0)}
      {:ok, amount} -> {:ok, amount}
      :error -> {:error, %{row: number, message: "#{name} #{inspect(text)} is not a number"}}
    end
  end

  defp precision(amount, minor_units, number) do
    if Decimal.equal?(amount, Decimal.round(amount, minor_units)),
      do: :ok,
      else:
        {:error,
         %{row: number, message: "amount has more decimal places than the book's currency"}}
  end

  defp parse_balance(_text, %{"balance" => nil}, _number), do: {:ok, nil}

  defp parse_balance(text, mapping, number) do
    case Mapping.parse_amount(text, mapping["decimal_separator"]) do
      {:ok, nil} -> {:error, %{row: number, message: "running balance is blank"}}
      {:ok, balance} -> {:ok, balance}
      :error -> {:error, %{row: number, message: "balance #{inspect(text)} is not a number"}}
    end
  end

  ## Order

  # With a running balance each line's balance is the previous line's plus
  # its amount, read in whichever direction the bank wrote the file; without
  # one the file is read oldest first.
  defp ordered(lines, %{"balance" => nil}) do
    first = List.first(lines)
    last = List.last(lines)

    if Date.compare(first.line_date, last.line_date) == :gt,
      do: {:ok, number(Enum.reverse(lines))},
      else: {:ok, number(lines)}
  end

  defp ordered(lines, _mapping) do
    case chain_break(lines) do
      nil ->
        {:ok, number(lines)}

      row ->
        reversed = Enum.reverse(lines)

        if chain_break(reversed) == nil,
          do: {:ok, number(reversed)},
          else: {:error, {:running_balance_mismatch, row}}
    end
  end

  defp chain_break([first | rest]) do
    rest
    |> Enum.reduce_while(first, fn line, previous ->
      if Decimal.equal?(line.running_balance, Decimal.add(previous.running_balance, line.amount)),
        do: {:cont, line},
        else: {:halt, {:break, line.row}}
    end)
    |> case do
      {:break, row} -> row
      _line -> nil
    end
  end

  defp number(lines) do
    lines |> Enum.with_index(1) |> Enum.map(fn {line, n} -> Map.put(line, :line_number, n) end)
  end

  # The same movement twice in one file is two lines; the same file, or an
  # overlapping export, brings the same fingerprints again and is refused.
  defp fingerprinted(lines) do
    {fingerprinted, _seen} =
      Enum.map_reduce(lines, %{}, fn line, seen ->
        key =
          {line.line_date, line.description, line.reference, line.amount, line.running_balance}

        occurrence = Map.get(seen, key, 0) + 1

        fingerprint =
          [
            Date.to_iso8601(line.line_date),
            line.description,
            line.reference || "",
            Decimal.to_string(line.amount, :normal),
            if(line.running_balance,
              do: Decimal.to_string(line.running_balance, :normal),
              else: ""
            ),
            Integer.to_string(occurrence)
          ]
          |> Enum.join("\n")
          |> hash()

        {Map.put(line, :fingerprint, fingerprint), Map.put(seen, key, occurrence)}
      end)

    fingerprinted
  end

  defp fresh_lines(scope, company_id, bank_account_id, lines) do
    fingerprints = Enum.map(lines, & &1.fingerprint)

    existing =
      from(l in Records.query(StatementLine, scope, company_id),
        join: s in ^Records.query(Statement, scope, company_id),
        on: s.id == l.statement_id,
        where: l.bank_account_id == ^bank_account_id and l.fingerprint in ^fingerprints,
        select: {l.fingerprint, {s.statement_number, l.line_number}}
      )
      |> Repo.all()
      |> Map.new()

    duplicates =
      for line <- lines, found = Map.get(existing, line.fingerprint) do
        %{
          row: line.row,
          line_number: line.line_number,
          statement_number: elem(found, 0),
          statement_line_number: elem(found, 1)
        }
      end

    case duplicates do
      [] -> :ok
      duplicates -> {:error, {:duplicate_lines, duplicates}}
    end
  end

  ## Writing

  defp insert(scope, company_id, bank_account, file_name, sha256, lines, skipped) do
    {user_id, impersonator_id} = Records.actor_ids(scope)
    first = List.first(lines)
    last = List.last(lines)
    tenant_id = Scope.tenant_id(scope)

    {opening, closing} =
      if first.running_balance,
        do: {Decimal.sub(first.running_balance, first.amount), last.running_balance},
        else: {nil, nil}

    with {:ok, statement} <-
           Repo.insert(%Statement{
             tenant_id: tenant_id,
             company_id: company_id,
             bank_account_id: bank_account.id,
             file_name: String.trim(file_name),
             file_sha256: sha256,
             line_count: length(lines),
             start_date: lines |> Enum.map(& &1.line_date) |> Enum.min(Date),
             end_date: lines |> Enum.map(& &1.line_date) |> Enum.max(Date),
             opening_balance: opening,
             closing_balance: closing,
             imported_by_user_id: user_id,
             imported_by_impersonator_id: impersonator_id
           }) do
      rows =
        for line <- lines do
          %{
            tenant_id: tenant_id,
            company_id: company_id,
            statement_id: statement.id,
            bank_account_id: bank_account.id,
            line_number: line.line_number,
            line_date: line.line_date,
            description: line.description,
            reference: line.reference,
            amount: line.amount,
            running_balance: line.running_balance,
            fingerprint: line.fingerprint
          }
        end

      Repo.insert_all(StatementLine, rows)

      {:ok,
       statement
       |> read_back(scope, company_id)
       |> statement_view()
       |> Map.put(:skipped_count, skipped)}
    end
  end

  defp read_back(statement, scope, company_id) do
    Statement
    |> Records.query(scope, company_id)
    |> where([s], s.id == ^statement.id)
    |> preload(lines: ^ordered_lines(scope, company_id))
    |> Repo.one!()
  end

  @doc "A statement's lines in line order, as a preload query."
  def ordered_lines(scope, company_id) do
    StatementLine |> Records.query(scope, company_id) |> order_by([l], asc: l.line_number)
  end

  ## Views

  def statement_view(%Statement{} = statement) do
    statement
    |> Map.take([
      :id,
      :bank_account_id,
      :statement_number,
      :file_name,
      :file_sha256,
      :line_count,
      :start_date,
      :end_date,
      :opening_balance,
      :closing_balance,
      :imported_by_user_id,
      :imported_by_impersonator_id,
      :imported_at
    ])
    |> Map.put(
      :lines,
      case statement.lines do
        %Ecto.Association.NotLoaded{} -> []
        lines -> Enum.map(lines, &line_view/1)
      end
    )
  end

  def line_view(%StatementLine{} = line) do
    Map.take(line, [
      :id,
      :statement_id,
      :bank_account_id,
      :line_number,
      :line_date,
      :description,
      :reference,
      :amount,
      :running_balance
    ])
  end
end
