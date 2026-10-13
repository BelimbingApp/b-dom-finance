defmodule Bilimbi.Finance.Sst.Returns do
  @moduledoc false
  # A company's SST returns: opening one for a taxable period, adjusting it
  # while open, finalising it into a stored snapshot, discarding it, and
  # amending a finalised one with a new return for the same period. The
  # facade authorizes every call and holds the company lock for writes.

  import Ecto.Query

  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Finance.Ledger

  alias Bilimbi.Finance.Sst.{
    Adjustment,
    Figures,
    Form,
    Periods,
    Records,
    Registrations,
    ReturnAccount,
    ReturnBox,
    ReturnEvent,
    ReturnSource,
    TaxReturn
  }

  alias Ecto.Changeset

  @zero Decimal.new(0)

  ## Reading

  def fetch(scope, company_id, id) when is_integer(id) do
    Records.query(TaxReturn, scope, company_id)
    |> where([r], r.id == ^id)
    |> preload(
      events: ^order_by(Records.query(ReturnEvent, scope, company_id), asc: :event_number),
      adjustments:
        ^order_by(Records.query(Adjustment, scope, company_id), asc: :adjustment_number)
    )
    |> Repo.one()
  end

  def fetch(_scope, _company_id, _id), do: nil

  def fetch_adjustment(scope, company_id, id),
    do: Records.get(Adjustment, scope, company_id, id)

  @doc "`open`, `finalised`, or `discarded`, from the return's latest event."
  def status(%TaxReturn{events: events}) do
    cond do
      Enum.any?(events, &(&1.action == "finalised")) -> "finalised"
      Enum.any?(events, &(&1.action == "discarded")) -> "discarded"
      true -> "open"
    end
  end

  def finalised_event(%TaxReturn{events: events}),
    do: Enum.find(events, &(&1.action == "finalised"))

  @doc "The company's returns, oldest first, each as `view/2` shows it; `tax_type` filters."
  def list(scope, company_id, options) do
    tax_type = Keyword.get(options, :tax_type)

    with :ok <- tax_type_option(tax_type),
         {:ok, limit, cursor} <- Records.page_options(options) do
      returns =
        Records.query(TaxReturn, scope, company_id)
        |> then(fn query ->
          if tax_type, do: where(query, [r], r.tax_type == ^tax_type), else: query
        end)
        |> Records.page(limit, cursor)
        |> preload(events: ^order_by(Records.query(ReturnEvent, scope, company_id), asc: :id))
        |> Repo.all()

      superseded = superseded(scope, company_id)
      {:ok, Enum.map(returns, &view(&1, superseded))}
    end
  end

  defp tax_type_option(nil), do: :ok
  defp tax_type_option(tax_type) when is_binary(tax_type),
    do: if(tax_type in Form.tax_types(), do: :ok, else: {:error, :invalid_option})

  defp tax_type_option(_tax_type), do: {:error, :invalid_option}

  # `%{amended return ID => the finalised return that amends it}`.
  defp superseded(scope, company_id) do
    from(r in Records.query(TaxReturn, scope, company_id),
      join: e in ^Records.query(ReturnEvent, scope, company_id),
      on: e.return_id == r.id and e.action == "finalised",
      where: not is_nil(r.amends_return_id),
      select: {r.amends_return_id, r.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "A return's own fields, status, version, and events, without figures."
  def view(%TaxReturn{} = tax_return, superseded) do
    finalised = finalised_event(tax_return)

    tax_return
    |> Map.take([
      :id,
      :return_number,
      :tax_type,
      :registration_id,
      :period_start,
      :period_end,
      :due_date,
      :amends_return_id,
      :reason,
      :opened_by_user_id,
      :opened_by_impersonator_id,
      :opened_at
    ])
    |> Map.merge(%{
      status: status(tax_return),
      version: finalised && finalised.version,
      tax_payable: finalised && finalised.tax_payable,
      superseded_by_return_id: Map.get(superseded, tax_return.id),
      events: Enum.map(tax_return.events, &event_view/1)
    })
  end

  defp event_view(event) do
    Map.take(event, [
      :id,
      :event_number,
      :action,
      :reason,
      :version,
      :through_entry_number,
      :through_mapping_number,
      :through_adjustment_number,
      :tax_payable,
      :recorded_by_user_id,
      :recorded_by_impersonator_id,
      :recorded_at
    ])
  end

  @doc """
  A return with its registration, adjustments, and figures: an open one's
  read now, a finalised one's as stored, a discarded one's none. A
  finalised return also shows what changed since (`posted_since`) and an
  amendment the return it amends (`amends`).
  """
  def report(scope, company_id, %TaxReturn{} = tax_return) do
    status = status(tax_return)
    registration = Registrations.get(scope, company_id, tax_return.registration_id)

    base =
      tax_return
      |> view(superseded(scope, company_id))
      |> Map.merge(%{
        registration: Registrations.view(registration),
        registration_number: number(registration, tax_return.tax_type),
        adjustments: adjustment_views(tax_return.adjustments),
        period_ended: period_ended?(tax_return)
      })

    with {:ok, figures} <- figures(scope, company_id, tax_return, registration, status),
         {:ok, posted_since} <-
           posted_since(scope, company_id, tax_return, registration, status, figures) do
      {:ok,
       base
       |> Map.put(:figures, figures)
       |> Map.put(:posted_since, posted_since)
       |> Map.put(:amends, amends(scope, company_id, tax_return, figures))}
    end
  end

  defp figures(_scope, _company_id, _tax_return, _registration, "discarded"), do: {:ok, nil}

  defp figures(scope, company_id, tax_return, registration, "open") do
    Figures.compute(
      scope,
      company_id,
      tax_return,
      registration,
      standing(tax_return.adjustments, Records.max_bigint())
    )
  end

  defp figures(scope, company_id, tax_return, _registration, "finalised"),
    do: {:ok, snapshot(scope, company_id, tax_return)}

  # A finalised return's stored figures, in the form's order.
  defp snapshot(scope, company_id, tax_return) do
    event = finalised_event(tax_return)

    stored =
      Records.query(ReturnBox, scope, company_id)
      |> where([b], b.return_id == ^tax_return.id)
      |> Repo.all()
      |> Map.new(&{&1.box, &1})

    sources =
      Records.query(ReturnSource, scope, company_id)
      |> where([s], s.return_id == ^tax_return.id)
      |> order_by([s], asc: s.line_number)
      |> Repo.all()
      |> Enum.map(&source_view/1)

    accounts =
      Records.query(ReturnAccount, scope, company_id)
      |> where([a], a.return_id == ^tax_return.id)
      |> order_by([a], asc: a.line_number)
      |> Repo.all()
      |> Enum.map(&account_view/1)

    %{
      tax_type: tax_return.tax_type,
      period_start: tax_return.period_start,
      period_end: tax_return.period_end,
      currency_code: event.currency_code,
      minor_units: event.minor_units,
      through_entry_number: event.through_entry_number,
      through_mapping_number: event.through_mapping_number,
      through_adjustment_number: event.through_adjustment_number,
      tax_payable: event.tax_payable,
      boxes:
        Enum.map(Form.boxes(tax_return.tax_type), fn box ->
          row = Map.get(stored, box.key, %{taxable_amount: nil, tax_amount: nil})

          box
          |> Map.take([:key, :item, :part, :kind, :label, :rate])
          |> Map.merge(%{taxable_amount: row.taxable_amount, tax_amount: row.tax_amount})
        end),
      sources: sources,
      accounts: accounts,
      unmapped: [],
      rate_mismatches: []
    }
  end

  defp source_view(row) do
    row
    |> Map.take([
      :line_number,
      :source,
      :document_kind,
      :measure,
      :prior_period,
      :tax_code_id,
      :tax_code,
      :rate,
      :account_id,
      :box,
      :mapping_number,
      :document_count,
      :taxable_amount,
      :tax_amount
    ])
    |> Map.put(:rate_mismatch, false)
  end

  defp account_view(row) do
    Map.take(row, [
      :line_number,
      :account_id,
      :account_code,
      :account_name,
      :ledger_debits,
      :ledger_credits,
      :document_debits,
      :document_credits,
      :difference
    ])
  end

  # What the documents dated in a finalised return's period show now,
  # under the same mappings and adjustments: each box that differs, so a
  # document posted after finalising is never silently left out.
  defp posted_since(scope, company_id, tax_return, registration, "finalised", figures) do
    event = finalised_event(tax_return)

    with {:ok, now} <-
           Figures.compute(
             scope,
             company_id,
             tax_return,
             registration,
             standing(tax_return.adjustments, event.through_adjustment_number),
             through_mapping_number: event.through_mapping_number
           ) do
      changed =
        if now.through_entry_number == figures.through_entry_number,
          do: [],
          else: box_differences(now.boxes, figures.boxes)

      {:ok, %{through_entry_number: now.through_entry_number, boxes: changed}}
    end
  end

  defp posted_since(_scope, _company_id, _tax_return, _registration, _status, _figures),
    do: {:ok, nil}

  # An amendment's figures against the finalised figures of the return it
  # amends, box by box.
  defp amends(_scope, _company_id, %TaxReturn{amends_return_id: nil}, _figures), do: nil

  defp amends(scope, company_id, %TaxReturn{amends_return_id: id}, figures) do
    amended = fetch(scope, company_id, id)
    previous = snapshot(scope, company_id, amended)

    %{
      return_id: amended.id,
      return_number: amended.return_number,
      version: finalised_event(amended).version,
      tax_payable: previous.tax_payable,
      boxes: if(figures, do: box_differences(figures.boxes, previous.boxes), else: [])
    }
  end

  defp box_differences(now, before) do
    before = Map.new(before, &{&1.key, &1})

    for box <- now,
        old = Map.fetch!(before, box.key),
        taxable = difference(box.taxable_amount, old.taxable_amount),
        tax = difference(box.tax_amount, old.tax_amount),
        not (zero?(taxable) and zero?(tax)) do
      %{
        key: box.key,
        item: box.item,
        label: box.label,
        taxable_amount: box.taxable_amount,
        tax_amount: box.tax_amount,
        taxable_change: taxable,
        tax_change: tax
      }
    end
  end

  defp difference(nil, nil), do: nil
  defp difference(now, before), do: Decimal.sub(now || @zero, before || @zero)

  defp zero?(nil), do: true
  defp zero?(amount), do: Decimal.equal?(amount, 0)

  defp adjustment_views(adjustments) do
    withdrawn =
      for %{action: "withdrawn"} = w <- adjustments, into: %{}, do: {w.withdraws_adjustment_id, w}

    for %{action: "added"} = a <- adjustments do
      withdrawal = Map.get(withdrawn, a.id)

      a
      |> Map.take([
        :id,
        :adjustment_number,
        :box,
        :taxable_amount,
        :tax_amount,
        :description,
        :reference,
        :copied_from_adjustment_id,
        :recorded_by_user_id,
        :recorded_by_impersonator_id,
        :recorded_at
      ])
      |> Map.put(:standing, is_nil(withdrawal))
      |> Map.put(
        :withdrawal,
        withdrawal &&
          Map.take(withdrawal, [
            :id,
            :adjustment_number,
            :description,
            :recorded_by_user_id,
            :recorded_by_impersonator_id,
            :recorded_at
          ])
      )
    end
  end

  # Adjustments added and not withdrawn, both numbered through `through`.
  defp standing(adjustments, through) do
    withdrawn =
      for %{action: "withdrawn", adjustment_number: n} = w <- adjustments,
          n <= through,
          into: MapSet.new(),
          do: w.withdraws_adjustment_id

    for %{action: "added", adjustment_number: n} = a <- adjustments,
        n <= through,
        not MapSet.member?(withdrawn, a.id),
        do: a
  end

  defp number(nil, _tax_type), do: nil
  defp number(registration, "sales_tax"), do: registration.sales_tax_number
  defp number(registration, "service_tax"), do: registration.service_tax_number

  defp period_ended?(tax_return),
    do: Date.compare(Date.utc_today(), tax_return.period_end) == :gt

  @doc """
  The figures a return would show for a `tax_type` and `period_start`
  without opening one, read at `pins`; no adjustments.
  """
  def preview(scope, company_id, attributes, pins) do
    with {:ok, tax_type, start} <- period_attributes(attributes),
         {:ok, registration, period} <- period(scope, company_id, tax_type, start) do
      Figures.compute(scope, company_id, period, registration, [], pins)
    end
  end

  @doc """
  A finalised return's figures read again from the live tables at the
  numbers it recorded, and whether they equal what it stored.
  """
  def reproduce(scope, company_id, tax_return) do
    case finalised_event(tax_return) do
      nil ->
        {:error, :return_not_finalised}

      event ->
        registration = Registrations.get(scope, company_id, tax_return.registration_id)
        stored = snapshot(scope, company_id, tax_return)

        with {:ok, figures} <-
               Figures.compute(
                 scope,
                 company_id,
                 tax_return,
                 registration,
                 standing(tax_return.adjustments, event.through_adjustment_number),
                 through_entry_number: event.through_entry_number,
                 through_mapping_number: event.through_mapping_number
               ) do
          {:ok,
           %{
             figures: figures,
             reproduced:
               amounts(figures.boxes) == amounts(stored.boxes) and
                 source_amounts(figures.sources) == source_amounts(stored.sources) and
                 account_amounts(figures.accounts) == account_amounts(stored.accounts)
           }}
        end
    end
  end

  defp amounts(boxes),
    do: Enum.map(boxes, &{&1.key, normal(&1.taxable_amount), normal(&1.tax_amount)})

  defp source_amounts(rows) do
    Enum.map(rows, fn row ->
      {row.source, row.document_kind, row.measure, row.tax_code_id, row.box,
       row.document_count, normal(row.taxable_amount), normal(row.tax_amount)}
    end)
  end

  defp account_amounts(rows) do
    Enum.map(rows, fn row ->
      {row.account_id, normal(row.ledger_debits), normal(row.ledger_credits),
       normal(row.document_debits), normal(row.document_credits), normal(row.difference)}
    end)
  end

  defp normal(nil), do: nil
  defp normal(amount), do: amount |> Decimal.normalize() |> Decimal.to_string(:normal)

  ## Writing

  @doc """
  Opens the return of `tax_type` for the taxable period starting on
  `period_start`, under the registration version governing that date.
  """
  def open(scope, company_id, attributes) do
    with {:ok, tax_type, start} <- period_attributes(attributes),
         {:ok, registration, period} <- period(scope, company_id, tax_type, start),
         :ok <- period_free(scope, company_id, period) do
      insert_return(scope, company_id, registration, period, nil, %{})
    end
  end

  @doc """
  Opens a new return for a finalised return's period that amends it, with
  a `reason`, copying the adjustments that stood on it.
  """
  def amend(scope, company_id, %TaxReturn{} = tax_return, attributes) do
    period = Map.take(tax_return, [:tax_type, :period_start, :period_end])

    with :ok <- amendable(scope, company_id, tax_return),
         {:ok, registration} <- governing(scope, company_id, tax_return.period_start),
         {:ok, amendment} <-
           insert_return(scope, company_id, registration, period, tax_return, attributes) do
      {user_id, impersonator_id} = Records.actor_ids(scope)

      for adjustment <- standing(tax_return.adjustments, Records.max_bigint()) do
        Repo.insert!(%Adjustment{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          return_id: amendment.id,
          action: "added",
          copied_from_adjustment_id: adjustment.id,
          box: adjustment.box,
          taxable_amount: adjustment.taxable_amount,
          tax_amount: adjustment.tax_amount,
          description: adjustment.description,
          reference: adjustment.reference,
          recorded_by_user_id: user_id,
          recorded_by_impersonator_id: impersonator_id
        })
      end

      {:ok, amendment}
    end
  end

  defp amendable(scope, company_id, tax_return) do
    cond do
      status(tax_return) != "finalised" ->
        {:error, :return_not_finalised}

      Map.has_key?(superseded(scope, company_id), tax_return.id) ->
        {:error, :return_superseded}

      open_return(scope, company_id, tax_return) ->
        {:error, :return_open}

      true ->
        :ok
    end
  end

  defp open_return(scope, company_id, period) do
    scope
    |> period_returns(company_id, period)
    |> Enum.find(&(status(&1) == "open"))
  end

  defp period_returns(scope, company_id, %{tax_type: tax_type, period_start: start}) do
    Records.query(TaxReturn, scope, company_id)
    |> where([r], r.tax_type == ^tax_type and r.period_start == ^start)
    |> preload(events: ^Records.query(ReturnEvent, scope, company_id))
    |> Repo.all()
  end

  defp insert_return(scope, company_id, registration, period, amended, attributes) do
    {user_id, impersonator_id} = Records.actor_ids(scope)

    changeset =
      %TaxReturn{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        tax_type: period.tax_type,
        registration_id: registration.id,
        period_start: period.period_start,
        period_end: period.period_end,
        due_date: Periods.due_date(registration, period.period_end),
        amends_return_id: amended && amended.id,
        opened_by_user_id: user_id,
        opened_by_impersonator_id: impersonator_id
      }
      |> TaxReturn.changeset(attributes)

    with {:ok, tax_return} <- Repo.insert(changeset),
         {:ok, _event} <-
           insert_event(scope, company_id, tax_return, "opened", %{
             reason: tax_return.reason
           }) do
      {:ok, fetch(scope, company_id, tax_return.id)}
    end
  end

  defp period_attributes(attributes) do
    tax_type = Records.fetch(attributes, :tax_type)

    if tax_type in Form.tax_types() do
      with {:ok, start} <- date(Records.fetch(attributes, :period_start)),
           do: {:ok, tax_type, start}
    else
      {:error, :invalid_tax_type}
    end
  end

  defp date(%Date{} = date), do: {:ok, date}

  defp date(text) when is_binary(text) do
    case Date.from_iso8601(String.trim(text)) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :not_a_taxable_period}
    end
  end

  defp date(_value), do: {:error, :not_a_taxable_period}

  # The taxable period starting on `start` under the registration version
  # governing it, which must hold a number for the tax.
  defp period(scope, company_id, tax_type, start) do
    with {:ok, registration} <- governing(scope, company_id, start),
         :ok <- registered_for(registration, tax_type),
         {:ok, start, finish} <- periods(registration, start) do
      {:ok, registration, %{tax_type: tax_type, period_start: start, period_end: finish}}
    end
  end

  defp governing(scope, company_id, start) do
    case Registrations.governing(scope, company_id, start) do
      nil -> {:error, :not_registered}
      registration -> {:ok, registration}
    end
  end

  defp registered_for(registration, tax_type) do
    if number(registration, tax_type), do: :ok, else: {:error, :not_registered_for_tax}
  end

  defp periods(registration, start) do
    case Periods.period(registration, start) do
      {:ok, start, finish} -> {:ok, start, finish}
      :error -> {:error, :not_a_taxable_period}
    end
  end

  defp period_free(scope, company_id, period) do
    returns = period_returns(scope, company_id, period)

    cond do
      Enum.any?(returns, &(status(&1) == "open")) -> {:error, :return_open}
      Enum.any?(returns, &(status(&1) == "finalised")) -> {:error, :return_finalised}
      overlapping?(scope, company_id, period) -> {:error, :period_overlaps}
      true -> :ok
    end
  end

  defp overlapping?(scope, company_id, period) do
    from(r in Records.query(TaxReturn, scope, company_id),
      left_join: e in ^Records.query(ReturnEvent, scope, company_id),
      on: e.return_id == r.id and e.action == "discarded",
      where: r.tax_type == ^period.tax_type and is_nil(e.id),
      where: r.period_start != ^period.period_start or r.period_end != ^period.period_end,
      where: r.period_start <= ^period.period_end and r.period_end >= ^period.period_start
    )
    |> Repo.exists?()
  end

  @doc "Adds an adjustment to an open return: `box`, `taxable_amount`, `tax_amount`, `description`, `reference`."
  def add_adjustment(scope, company_id, %TaxReturn{} = tax_return, attributes) do
    key = Records.fetch(attributes, :box)
    box = Enum.find(Form.adjustable_boxes(tax_return.tax_type), &(&1.key == key))
    {user_id, impersonator_id} = Records.actor_ids(scope)

    with :ok <- open?(tax_return),
         :ok <- adjustable(box),
         {:ok, book} <- Ledger.get_book(scope, company_id) do
      %Adjustment{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        return_id: tax_return.id,
        action: "added",
        box: box.key,
        recorded_by_user_id: user_id,
        recorded_by_impersonator_id: impersonator_id
      }
      |> Adjustment.add_changeset(attributes, Form.columns(box), book.minor_units)
      |> Repo.insert()
    end
  end

  @doc "Withdraws a standing adjustment of an open return with a `reason`."
  def withdraw_adjustment(scope, company_id, %Adjustment{} = adjustment, attributes) do
    tax_return = fetch(scope, company_id, adjustment.return_id)
    {user_id, impersonator_id} = Records.actor_ids(scope)

    cond do
      adjustment.action != "added" ->
        {:error, :adjustment_not_found}

      Enum.any?(tax_return.adjustments, &(&1.withdraws_adjustment_id == adjustment.id)) ->
        {:error, :adjustment_withdrawn}

      true ->
        with :ok <- open?(tax_return) do
          %Adjustment{
            tenant_id: Scope.tenant_id(scope),
            company_id: company_id,
            return_id: tax_return.id,
            action: "withdrawn",
            withdraws_adjustment_id: adjustment.id,
            recorded_by_user_id: user_id,
            recorded_by_impersonator_id: impersonator_id
          }
          |> Adjustment.withdraw_changeset(%{description: Records.fetch(attributes, :reason)})
          |> Repo.insert()
        end
    end
  end

  defp adjustable(nil) do
    {:error,
     %Adjustment{}
     |> Changeset.change()
     |> Changeset.add_error(:box, "is not a box of this return a preparer adjusts")}
  end

  defp adjustable(_box), do: :ok

  defp open?(tax_return) do
    case status(tax_return) do
      "open" -> :ok
      "finalised" -> {:error, :return_finalised}
      "discarded" -> {:error, :return_discarded}
    end
  end

  @doc """
  Finalises an open return once its period has ended, every tax code with
  tax in it is mapped, and every mapped rate fits its box: records the
  figures read now, the numbers they were read at, the source rows, and the
  ledger reconciliation, after which nothing about the return changes.
  """
  def finalise(scope, company_id, %TaxReturn{} = tax_return) do
    registration = Registrations.get(scope, company_id, tax_return.registration_id)
    standing = standing(tax_return.adjustments, Records.max_bigint())

    with :ok <- open?(tax_return),
         :ok <- if(period_ended?(tax_return), do: :ok, else: {:error, :period_not_ended}),
         {:ok, figures} <- Figures.compute(scope, company_id, tax_return, registration, standing),
         :ok <- complete(figures),
         {:ok, _event} <-
           insert_event(scope, company_id, tax_return, "finalised", %{
             through_entry_number: figures.through_entry_number,
             through_mapping_number: figures.through_mapping_number,
             through_adjustment_number: last_adjustment_number(scope, company_id),
             currency_code: figures.currency_code,
             minor_units: figures.minor_units,
             tax_payable: figures.tax_payable
           }) do
      store_snapshot(scope, company_id, tax_return, figures)
      {:ok, fetch(scope, company_id, tax_return.id)}
    end
  end

  defp complete(%{unmapped: [_ | _] = unmapped}), do: {:error, {:unmapped_tax_codes, unmapped}}

  defp complete(%{rate_mismatches: [_ | _] = rows}) do
    {:error,
     {:rate_mismatch,
      Enum.map(rows, &Map.take(&1, [:source, :tax_code_id, :tax_code, :rate, :box]))}}
  end

  defp complete(_figures), do: :ok

  defp last_adjustment_number(scope, company_id) do
    Records.query(Adjustment, scope, company_id)
    |> select([a], coalesce(max(a.adjustment_number), 0))
    |> Repo.one()
  end

  defp store_snapshot(scope, company_id, tax_return, figures) do
    owned = %{tenant_id: Scope.tenant_id(scope), company_id: company_id, return_id: tax_return.id}

    figures.boxes
    |> Enum.with_index(1)
    |> Enum.each(fn {box, n} ->
      Repo.insert!(
        struct(
          ReturnBox,
          Map.merge(owned, %{
            line_number: n,
            box: box.key,
            taxable_amount: box.taxable_amount,
            tax_amount: box.tax_amount
          })
        )
      )
    end)

    for row <- figures.sources do
      Repo.insert!(
        struct(ReturnSource, Map.merge(owned, Map.drop(row, [:rate_mismatch])))
      )
    end

    for row <- figures.accounts do
      Repo.insert!(struct(ReturnAccount, Map.merge(owned, row)))
    end
  end

  @doc "Discards an open return with a `reason`; it is kept, with its adjustments."
  def discard(scope, company_id, %TaxReturn{} = tax_return, attributes) do
    with :ok <- open?(tax_return),
         {:ok, _event} <-
           insert_event(scope, company_id, tax_return, "discarded", %{
             reason: Records.fetch(attributes, :reason)
           }) do
      {:ok, fetch(scope, company_id, tax_return.id)}
    end
  end

  defp insert_event(scope, company_id, tax_return, action, attributes) do
    {user_id, impersonator_id} = Records.actor_ids(scope)

    %ReturnEvent{
      tenant_id: Scope.tenant_id(scope),
      company_id: company_id,
      return_id: tax_return.id,
      action: action,
      recorded_by_user_id: user_id,
      recorded_by_impersonator_id: impersonator_id
    }
    |> struct(Map.delete(attributes, :reason))
    |> ReturnEvent.changeset(Map.take(attributes, [:reason]))
    |> Repo.insert()
  end
end
