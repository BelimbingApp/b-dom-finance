defmodule Bilimbi.Finance.Payroll.PeopleSourceTest do
  use ExUnit.Case, async: true

  alias Bilimbi.Finance.Payroll.CompanyTime

  describe "the company's local date" do
    test "is the company's local calendar date of a stored UTC time, not the stored UTC date" do
      # 00:30 on 1 October in Kuala Lumpur (UTC+8) is stored as 30 September, 16:30 UTC.
      assert CompanyTime.local_date(~N[2026-09-30 16:30:00], "Asia/Kuala_Lumpur") ==
               ~D[2026-10-01]

      assert CompanyTime.local_date(~N[2026-09-30 15:59:59], "Asia/Kuala_Lumpur") ==
               ~D[2026-09-30]

      assert CompanyTime.local_date(~N[2026-09-30 16:30:00], "UTC") == ~D[2026-09-30]
    end

    test "is nil rather than a guess when the zone cannot convert" do
      assert CompanyTime.local_date(~N[2026-09-30 16:30:00], "Not/A_Zone") == nil
    end
  end
end
