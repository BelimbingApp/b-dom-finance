defmodule Bilimbi.Finance.Reports.Layout do
  @moduledoc false

  # A company's report layout is the `finance.reports.sections` setting: an
  # ordered JSON array of sections, each naming the report it belongs to, its
  # heading, and the codes of the accounts it gathers:
  #
  #     [{"report": "balance_sheet", "name": "...", "accounts": ["1000", "1100"]}]
  #
  # Headings and account codes are the company's own data. A listed account
  # brings its descendants in the chart with it, unless a descendant is
  # listed itself; the nearest listed account decides, and within one report
  # the first section that lists a code keeps it.

  @reports ~w(profit_and_loss balance_sheet cash_position)
  @name_limit 100
  @code_limit 50

  @doc "The reports a section may belong to."
  def reports, do: @reports

  @doc "Whether `value` is a valid layout, for Base Settings' validator."
  def valid?(value) when is_list(value), do: Enum.all?(value, &valid_section?/1)
  def valid?(_value), do: false

  defp valid_section?(%{"report" => report, "name" => name, "accounts" => codes} = section)
       when map_size(section) == 3 and report in @reports and is_binary(name) and is_list(codes) do
    present?(name, @name_limit) and
      Enum.all?(codes, &(is_binary(&1) and present?(&1, @code_limit)))
  end

  defp valid_section?(_section), do: false

  defp present?(text, limit) do
    trimmed = String.trim(text)
    trimmed != "" and String.length(trimmed) <= limit
  end

  @doc """
  The sections of one report, in order: `%{name, codes}`. A stored value
  that is not a valid layout (one written before validation, or adopted)
  yields no sections rather than a wrong grouping.
  """
  def sections(value, report) when report in @reports do
    if valid?(value) do
      for %{"report" => ^report, "name" => name, "accounts" => codes} <- value,
          do: %{name: String.trim(name), codes: Enum.map(codes, &String.trim/1)}
    else
      []
    end
  end

  @doc """
  Each account's section index in `sections`, or no entry when no listed
  account covers it, and the listed codes the chart does not have.
  """
  def assign(accounts, sections) do
    by_code = Map.new(accounts, &{&1.code, &1})
    by_id = Map.new(accounts, &{&1.id, &1})

    listed =
      sections
      |> Enum.with_index()
      |> Enum.flat_map(fn {section, index} -> Enum.map(section.codes, &{&1, index}) end)
      |> Enum.reverse()
      |> Map.new()

    unmatched =
      sections
      |> Enum.flat_map(& &1.codes)
      |> Enum.reject(&Map.has_key?(by_code, &1))
      |> Enum.uniq()

    membership =
      for account <- accounts,
          index = nearest(account, listed, by_id, map_size(by_id)),
          index != nil,
          into: %{},
          do: {account.id, index}

    {membership, unmatched}
  end

  # The chart refuses a cycle, but the walk is bounded by the chart's size
  # so a malformed parent chain can never loop.
  defp nearest(nil, _listed, _by_id, _steps), do: nil
  defp nearest(_account, _listed, _by_id, steps) when steps < 0, do: nil

  defp nearest(account, listed, by_id, steps) do
    case Map.fetch(listed, account.code) do
      {:ok, index} -> index
      :error -> nearest(Map.get(by_id, account.parent_id), listed, by_id, steps - 1)
    end
  end
end
