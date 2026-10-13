defmodule Bilimbi.Finance.Reports.AuditorPack do
  @moduledoc false
  import Ecto.Query
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope

  alias Bilimbi.Finance.{
    Ledger,
    Receivables,
    Payables,
    Reconciliation,
    Einvoice,
    Payroll,
    Sst,
    FixedAssets
  }

  alias Bilimbi.Finance.Reports.{Serialization, Snapshot}
  alias Ecto.Adapters.SQL

  @owners [
    {"ledger", Ledger},
    {"receivables", Receivables},
    {"payables", Payables},
    {"reconciliation", Reconciliation},
    {"einvoice", Einvoice},
    {"payroll", Payroll},
    {"sst", Sst},
    {"fixed_assets", FixedAssets}
  ]
  # Bump whenever an evidence field list, serialization or filter changes.
  @version "5"

  def sources, do: Enum.map(@owners, &elem(&1, 1))

  def generate(scope, company_id, as_of) do
    id = Ecto.UUID.generate()
    directory = Path.join(System.tmp_dir!(), "finance-auditor-pack-#{id}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    try do
      with {:ok, manifest} <- Snapshot.run(fn -> collect(scope, company_id, as_of, directory) end),
           :ok <-
             File.write(
               Path.join(directory, "manifest.json"),
               Jason.encode!(manifest, pretty: true)
             ),
           files = File.ls!(directory) |> Enum.sort() |> Enum.map(&String.to_charlist/1),
           {:ok, {_name, bytes}} <-
             :zip.create(~c"auditor-pack.zip", files, [
               :memory,
               cwd: String.to_charlist(directory)
             ]) do
        {:ok, %{id: id, bytes: bytes}}
      end
    after
      File.rm_rf!(directory)
    end
  end

  defp collect(scope, company_id, as_of, directory) do
    with {:ok, totals} <- Ledger.account_totals(scope, company_id),
         {:ok, trial} <-
           Ledger.trial_balance(scope, company_id, as_of,
             through_entry_number: totals.through_entry_number
           ),
         {:ok, ar} <-
           Receivables.aged_receivables(scope, company_id, as_of,
             through_entry_number: totals.through_entry_number
           ),
         {:ok, ap} <-
           Payables.aged_payables(scope, company_id, as_of,
             through_entry_number: totals.through_entry_number
           ) do
      %{rows: [[snapshot, captured_at]]} =
        SQL.query!(
          Repo.get_dynamic_repo(),
          "SELECT pg_current_snapshot()::text, clock_timestamp()",
          []
        )

      gl = general_ledger(scope, company_id, totals.through_entry_number, directory)
      debit_total = Enum.reduce(totals.rows, Decimal.new(0), &Decimal.add(&1.debits, &2))
      credit_total = Enum.reduce(totals.rows, Decimal.new(0), &Decimal.add(&1.credits, &2))

      unless Decimal.equal?(Decimal.new(gl.debits), debit_total) and
               Decimal.equal?(Decimal.new(gl.credits), credit_total),
             do: Repo.rollback(:control_totals_mismatch)

      evidence =
        for {name, owner} <- @owners, dataset <- owner.evidence_datasets() do
          filename = "#{name}-#{dataset}.csv"

          meta =
            write_pages(directory, filename, fn cursor ->
              owner.evidence_page(scope, company_id, dataset, after: cursor)
            end)

          {filename, meta}
        end
        |> Map.new()

      issued =
        write_pages(directory, "issued-reports.csv", fn cursor ->
          fields = [
            :id,
            :company_id,
            :kind,
            :implementation_version,
            :through_entry_number,
            :content,
            :chart,
            :layout,
            :membership,
            :issued_by_user_id,
            :issued_by_impersonator_id,
            :issued_at
          ]

          rows =
            from(r in Bilimbi.Base.Tenancy.scope_query(Bilimbi.Finance.Reports.Issued, scope),
              where: r.company_id == ^company_id and r.id > ^cursor,
              order_by: [asc: r.id],
              limit: 500,
              select: map(r, ^fields)
            )
            |> Repo.all()

          {:ok,
           %{
             fields: fields,
             rows: rows,
             next: if(length(rows) == 500, do: List.last(rows).id, else: nil)
           }}
        end)

      evidence = Map.put(evidence, "issued-reports.csv", issued)

      summaries =
        for {name, report} <- [
              {"trial-balance", trial},
              {"aged-receivables", ar},
              {"aged-payables", ap}
            ],
            into: %{} do
          filename = name <> ".json"
          bytes = report |> Serialization.value() |> Jason.encode!(pretty: true)
          File.write!(Path.join(directory, filename), bytes)
          {filename, %{row_count: summary_count(report), sha256: hash(bytes)}}
        end

      summaries = Map.merge(summaries, summary_csvs(directory, trial, ar, ap))

      source_meta = source_index(scope, company_id, directory)

      {:ok,
       %{
         generator: "finance/reports/auditor-pack",
         generator_version: @version,
         tenant_id: Scope.tenant_id(scope),
         company_id: company_id,
         currency_code: totals.currency_code,
         minor_units: totals.minor_units,
         generated_by_user_id: Scope.actor(scope).user_id,
         generated_by_impersonator_id: Scope.actor(scope).impersonator_id,
         captured_at: Serialization.value(captured_at),
         timezone: "Etc/UTC",
         database_snapshot: snapshot,
         through_entry_number: totals.through_entry_number,
         filters: %{
           evidence:
             "all company records of the #{Enum.map_join(@owners, ", ", &elem(&1, 0))} modules " <>
               "visible at the database snapshot, including drafts and reversals",
           trial_balance_and_aging_as_of: Date.to_iso8601(as_of)
         },
         decimal_encoding: "exact decimal strings; CSV numeric cells are unrounded",
         csv_text_encoding: "UTF-8; formula-like text is prefixed with an apostrophe",
         source_files:
           "bank input bytes are not retained; index carries original hashes; authority payloads are included",
         files:
           evidence
           |> Map.put("general-ledger.csv", gl)
           |> Map.merge(summaries)
           |> Map.merge(source_meta),
         control_totals: %{
           debits: Serialization.value(debit_total),
           credits: Serialization.value(credit_total)
         }
       }}
    end
  end

  defp summary_csvs(directory, trial, ar, ap) do
    trial_rows =
      Enum.map(
        trial.rows,
        &Map.merge(&1, %{as_of: trial.as_of, through_entry_number: trial.through_entry_number})
      )

    ar_rows =
      for customer <- ar.customers, row <- customer.documents do
        Map.merge(row, %{
          customer_id: customer.customer_id,
          customer_code: customer.code,
          customer_name: customer.name,
          as_of: ar.as_of,
          through_entry_number: ar.through_entry_number
        })
      end

    ap_rows =
      for party <- ap.parties, row <- party.documents do
        Map.merge(row, %{party_key: party.party_key, party_name: party.party_name})
      end ++ ap.exceptions

    ap_rows =
      Enum.map(
        ap_rows,
        &Map.merge(&1, %{as_of: ap.as_of, through_entry_number: ap.through_entry_number})
      )

    for {filename, fields, rows} <- [
          {"trial-balance.csv",
           [
             :as_of,
             :through_entry_number,
             :id,
             :code,
             :name,
             :account_type,
             :parent_id,
             :debits,
             :credits,
             :debit_balance,
             :credit_balance
           ], trial_rows},
          {"aged-receivables.csv",
           [
             :as_of,
             :through_entry_number,
             :customer_id,
             :customer_code,
             :customer_name,
             :document_id,
             :document_reference,
             :party_name,
             :issue_date,
             :due_date,
             :total,
             :outstanding,
             :days_overdue,
             :bucket
           ], ar_rows},
          {"aged-payables.csv",
           [
             :as_of,
             :through_entry_number,
             :id,
             :document_number,
             :party_key,
             :party_name,
             :party_document_number,
             :document_date,
             :due_date,
             :currency_code,
             :total,
             :outstanding,
             :days_overdue,
             :bucket
           ], ap_rows}
        ],
        into: %{} do
      {filename,
       write_pages(directory, filename, fn _ ->
         {:ok, %{fields: fields, rows: rows, next: nil}}
       end)}
    end
  end

  defp general_ledger(scope, company, through, directory) do
    {:ok, accounts} = Ledger.list_accounts(scope, company)
    chart = Map.new(accounts, &{&1.id, &1})

    fields = [
      :entry_number,
      :entry_id,
      :entry_date,
      :currency_code,
      :entry_description,
      :owner_module,
      :owner_record,
      :legacy,
      :reference,
      :posted_by_user_id,
      :posted_by_impersonator_id,
      :posted_at,
      :reverses_entry_id,
      :line_number,
      :account_id,
      :account_code,
      :account_name,
      :account_type,
      :description,
      :debit,
      :credit
    ]

    write_pages(directory, "general-ledger.csv", fn cursor ->
      with {:ok, entries} <-
             Ledger.list_entries(scope, company,
               through_entry_number: through,
               limit: 500,
               after: if(cursor == 0, do: nil, else: cursor)
             ) do
        rows =
          for entry <- entries, line <- entry.lines do
            account = Map.fetch!(chart, line.account_id)

            entry
            |> Map.take([
              :entry_number,
              :entry_date,
              :currency_code,
              :reference,
              :posted_by_user_id,
              :posted_by_impersonator_id,
              :posted_at,
              :reverses_entry_id,
              :legacy
            ])
            |> Map.merge(line)
            |> Map.merge(%{
              owner_module: entry.owner && entry.owner.module,
              owner_record: entry.owner && entry.owner.record,
              entry_id: entry.id,
              entry_description: entry.description,
              account_code: account.code,
              account_name: account.name,
              account_type: account.account_type
            })
          end

        last = List.last(entries)

        {:ok,
         %{
           fields: fields,
           rows: rows,
           next: if(length(entries) == 500, do: {last.entry_date, last.id}, else: nil)
         }}
      end
    end)
  end

  # Only a bounded page lives in memory. Hash each completed CSV incrementally.
  defp write_pages(directory, filename, fetch) do
    path = Path.join(directory, filename)
    {:ok, file} = File.open(path, [:write, :binary])

    try do
      {count, debits, credits} = page(file, fetch, 0, true, 0, Decimal.new(0), Decimal.new(0))

      %{
        row_count: count,
        sha256: hash_file(path),
        debits: Serialization.value(debits),
        credits: Serialization.value(credits)
      }
    after
      File.close(file)
    end
  end

  defp page(file, fetch, cursor, first?, count, debits, credits) do
    result =
      case fetch.(cursor) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end

    if first?,
      do:
        :ok = IO.binwrite(file, Serialization.csv_row(Enum.map(result.fields, &Atom.to_string/1)))

    {count, debits, credits} =
      Enum.reduce(result.rows, {count, debits, credits}, fn row, {n, debit, credit} ->
        :ok = IO.binwrite(file, Serialization.csv_row(Enum.map(result.fields, &Map.get(row, &1))))
        {n + 1, add(debit, Map.get(row, :debit)), add(credit, Map.get(row, :credit))}
      end)

    if result.next,
      do: page(file, fetch, result.next, false, count, debits, credits),
      else: {count, debits, credits}
  end

  defp source_index(scope, company_id, directory) do
    filename = "source-file-index.csv"
    {:ok, file} = File.open(Path.join(directory, filename), [:write, :binary])

    try do
      :ok =
        IO.binwrite(file, Serialization.csv_row(~w(owner record_id filename sha256 availability)))

      {count, files} =
        source_pages(file, scope, company_id, directory, Reconciliation, "statement", 0, 0, %{})

      {count, files} =
        source_pages(file, scope, company_id, directory, Einvoice, "submission", 0, count, files)

      Map.put(files, filename, %{
        row_count: count,
        sha256: hash_file(Path.join(directory, filename))
      })
    after
      File.close(file)
    end
  end

  defp source_pages(file, scope, company, directory, owner, dataset, cursor, count, files) do
    {:ok, result} = owner.evidence_page(scope, company, dataset, after: cursor)

    {count, files} =
      Enum.reduce(result.rows, {count, files}, fn row, {count, files} ->
        {name, sha, available, files} =
          if dataset == "statement" do
            {row.file_name, row.file_sha256, "original bytes not retained", files}
          else
            name = "authority-payload-#{row.id}.json"
            File.write!(Path.join(directory, name), row.payload)
            sha = hash(row.payload)
            if sha != row.payload_sha256, do: Repo.rollback(:source_integrity_failure)

            {name, sha, "included",
             Map.put(files, name, %{sha256: sha, byte_size: byte_size(row.payload)})}
          end

        :ok =
          IO.binwrite(
            file,
            Serialization.csv_row([
              if(dataset == "statement", do: "finance/reconciliation", else: "finance/einvoice"),
              row.id,
              name,
              sha,
              available
            ])
          )

        {count + 1, files}
      end)

    if result.next,
      do:
        source_pages(file, scope, company, directory, owner, dataset, result.next, count, files),
      else: {count, files}
  end

  defp summary_count(%{rows: rows}), do: length(rows)

  defp summary_count(%{customers: groups}),
    do: Enum.reduce(groups, 0, &(length(&1.documents) + &2))

  defp summary_count(%{parties: groups, exceptions: exceptions}),
    do: Enum.reduce(groups, length(exceptions), &(length(&1.documents) + &2))

  defp add(total, %Decimal{} = value), do: Decimal.add(total, value)
  defp add(total, _), do: total
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp hash_file(path),
    do:
      path
      |> File.stream!(65_536, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
end
