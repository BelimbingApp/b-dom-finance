defmodule Bilimbi.Finance.Sst.RegistrationTest do
  use Bilimbi.Finance.Sst.SstCase

  alias Bilimbi.Finance.Sst.Periods

  describe "registration" do
    test "keeps every version, numbered, with who recorded it and why", context do
      %{operator: operator, registration: first} = context

      assert %{
               version: 1,
               sales_tax_number: "X00-2601-00000001",
               period_months: 2,
               period_start: ~D[2026-01-01],
               service_tax_basis: "payment",
               recorded_by_user_id: 91,
               recorded_at: %DateTime{}
             } = first

      assert {:ok, second} =
               Sst.register(operator, 73, %{
                 service_tax_number: "x00-2601-00000009 ",
                 reason: "Number corrected"
               })

      assert %{version: 2, service_tax_number: "X00-2601-00000009", reason: "Number corrected"} =
               second

      # Everything the call left out carries on from the version before.
      assert second.sales_tax_number == first.sales_tax_number
      assert second.period_start == first.period_start

      assert {:ok, ^second} = Sst.get_registration(operator, 73)
      assert {:ok, [%{version: 1}, %{version: 2}]} = Sst.list_registrations(operator, 73)

      # Nothing changed, nothing recorded.
      assert {:ok, %{version: 2}} =
               Sst.register(operator, 73, %{service_tax_number: "X00-2601-00000009"})

      assert {:ok, [_, _]} = Sst.list_registrations(operator, 73)
    end

    test "needs a number shaped as the department issues it", context do
      assert {:error, changeset} =
               Sst.register(context.operator, 73, %{sales_tax_number: "SST-123"})

      assert %{sales_tax_number: ["is not shaped like A00-0000-00000000"]} = errors_on(changeset)

      assert {:error, changeset} =
               Sst.register(context.operator, 73, %{
                 sales_tax_number: "",
                 service_tax_number: ""
               })

      assert %{sales_tax_number: ["or a service tax number is needed"]} = errors_on(changeset)

      assert {:error, changeset} =
               Sst.register(context.operator, 73, %{period_months: 13, service_tax_basis: "cash"})

      assert %{period_months: [_], service_tax_basis: ["is invalid"]} = errors_on(changeset)
    end

    test "changes the cycle or basis only after the last finalised period", context do
      %{operator: operator} = context
      tax_return = open!(context, "sales_tax", ~D[2026-01-01])
      {:ok, _finalised} = Sst.finalise_return(operator, 73, tax_return.id)

      assert {:error, changeset} =
               Sst.register(operator, 73, %{period_months: 1, period_start: ~D[2026-02-01]})

      assert %{period_start: [message]} = errors_on(changeset)
      assert message =~ "2026-02-28"

      assert {:error, changeset} = Sst.register(operator, 73, %{service_tax_basis: "invoice"})
      assert %{period_start: [_]} = errors_on(changeset)

      # The numbers may change at any time.
      assert {:ok, %{version: 2}} =
               Sst.register(operator, 73, %{sales_tax_number: "X00-2601-00000003"})

      assert {:ok, %{version: 3, period_months: 1, service_tax_basis: "invoice"}} =
               Sst.register(operator, 73, %{
                 period_months: 1,
                 period_start: ~D[2026-03-01],
                 service_tax_basis: "invoice"
               })
    end

    test "asks each call's own capability", context do
      viewer =
        TestFixtures.sign_in!(context.first_scope, 73, 93, ["finance.sst.view"])

      assert {:ok, %{version: 1}} = Sst.get_registration(viewer, 73)
      assert {:error, :unauthorized} = Sst.register(viewer, 73, %{period_months: 1})

      outsider = TestFixtures.sign_in!(context.first_scope, 73, 94, [])
      assert {:error, :unauthorized} = Sst.get_registration(outsider, 73)
      assert {:error, :unauthorized} = Sst.list_registrations(context.first_scope, 73)
      assert {:error, :company_not_found} = Sst.get_registration(context.operator, 75)
    end
  end

  describe "taxable periods" do
    test "run from the first period's start to month ends, two months a period" do
      cycle = %{period_start: ~D[2026-03-15], period_months: 2}

      assert {:ok, ~D[2026-03-15], ~D[2026-04-30]} = Periods.period(cycle, ~D[2026-03-15])
      assert {:ok, ~D[2026-05-01], ~D[2026-06-30]} = Periods.period(cycle, ~D[2026-05-01])
      assert :error = Periods.period(cycle, ~D[2026-06-01])
      assert :error = Periods.period(cycle, ~D[2026-04-01])
      assert {:ok, ~D[2026-11-01], ~D[2026-12-31]} = Periods.containing(cycle, ~D[2026-12-31])
      assert :error = Periods.containing(cycle, ~D[2026-03-14])

      assert [{~D[2026-07-01], _}, {~D[2026-05-01], _}, {~D[2026-03-15], ~D[2026-04-30]}] =
               Periods.recent(cycle, ~D[2026-07-20], 6)
    end

    test "are due at the end of the next month, or 30 days on for a varied cycle" do
      assert Periods.due_date(%{period_months: 2}, ~D[2026-02-28]) == ~D[2026-03-31]
      assert Periods.due_date(%{period_months: 1}, ~D[2026-01-31]) == ~D[2026-03-02]
    end

    test "are listed for the registration's cycle", context do
      assert {:ok, [newest | _] = periods} =
               Sst.taxable_periods(context.operator, 73, date: ~D[2026-05-10], count: 4)

      assert %{period_start: ~D[2026-05-01], period_end: ~D[2026-06-30], due_date: ~D[2026-07-31]} =
               newest

      assert length(periods) == 3
      assert {:error, :invalid_option} = Sst.taxable_periods(context.operator, 73, count: 0)
    end
  end

  describe "tax code mappings" do
    test "map a code to a box as numbered versions, and list every code with its mapping",
         context do
      %{operator: operator, codes: codes} = context

      assert {:ok, codes_now} = Sst.list_tax_codes(operator, 73)
      assert Enum.all?(codes_now, &is_nil(&1.mapping))
      assert length(codes_now) == 7

      assert {:ok, %{mapping_number: 1, box: "11a", tax_code: "G10"}} =
               Sst.map_tax_code(operator, 73, %{
                 source: "receivables",
                 tax_code_id: codes.goods10.id,
                 box: "11a"
               })

      assert {:ok, %{mapping_number: 2, box: "11b", reason: "Ten percent box"}} =
               Sst.map_tax_code(operator, 73, %{
                 "source" => "receivables",
                 "tax_code_id" => to_string(codes.goods10.id),
                 "box" => "11b",
                 "reason" => "Ten percent box"
               })

      # The same box again records nothing; a blank box is "not reported".
      assert {:ok, %{mapping_number: 2}} =
               Sst.map_tax_code(operator, 73, %{
                 source: "receivables",
                 tax_code_id: codes.goods10.id,
                 box: "11b"
               })

      assert {:ok, %{mapping_number: 3, box: nil}} =
               Sst.map_tax_code(operator, 73, %{
                 source: "receivables",
                 tax_code_id: codes.export.id,
                 box: ""
               })

      assert {:ok, listed} = Sst.list_tax_codes(operator, 73)
      g10 = Enum.find(listed, &(&1.code == "G10"))
      assert %{source: "receivables", mapping: %{box: "11b", mapping_number: 2}} = g10

      assert {:ok, [%{box: "11a"}, %{box: "11b"} = second, %{box: nil}]} =
               Sst.list_mappings(operator, 73)

      assert {:ok, [%{mapping_number: 3}]} = Sst.list_mappings(operator, 73, after: second.id)
    end

    test "refuse a box the source's codes do not report in, and an unknown code", context do
      %{operator: operator} = context

      assert {:error, changeset} =
               Sst.map_tax_code(operator, 73, %{
                 source: "payables",
                 tax_code_id: context.payable_codes.imported8.id,
                 box: "11a"
               })

      assert %{box: ["is not a box a payables tax code reports in"]} = errors_on(changeset)

      assert {:error, :tax_code_not_found} =
               Sst.map_tax_code(operator, 73, %{
                 source: "payables",
                 tax_code_id: 999_999,
                 box: "19"
               })

      assert {:error, :invalid_source} =
               Sst.map_tax_code(operator, 73, %{source: "ledger", tax_code_id: 1, box: "11a"})
    end

    test "need the settings capability and the sources' view grants", context do
      manager =
        TestFixtures.sign_in!(context.first_scope, 73, 93, ["finance.sst.settings.manage"])

      assert {:error, :unauthorized} =
               Sst.map_tax_code(manager, 73, %{
                 source: "receivables",
                 tax_code_id: context.codes.goods10.id,
                 box: "11b"
               })

      viewer = TestFixtures.sign_in!(context.first_scope, 73, 94, ["finance.sst.view"])
      assert {:error, :unauthorized} = Sst.list_tax_codes(viewer, 73)
      assert {:ok, []} = Sst.list_mappings(viewer, 73)
    end
  end
end
