defmodule Bilimbi.Finance.Payroll.CompanyTime do
  @moduledoc false
  # The company's own calendar, from Base DateTime: the time zone the company
  # set, else the app's configured zone. Every date this module defaults or
  # derives from a stored UTC time is the company's local date, never UTC's.

  alias Bilimbi.Base.DateTime, as: BaseDateTime
  alias Bilimbi.Base.Settings
  alias Bilimbi.Base.Tenancy.Scope

  def timezone(%Scope{} = scope, company_id) do
    BaseDateTime.company_timezone(Settings.Scope.company(company_id, Scope.tenant_id(scope)))
  end

  def today(%Scope{} = scope, company_id) do
    local_date(DateTime.utc_now(), timezone(scope, company_id))
  end

  def local_date(moment, timezone) do
    case BaseDateTime.shift(moment, timezone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, _reason} -> nil
    end
  end
end
