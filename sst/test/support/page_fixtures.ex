defmodule Bilimbi.Finance.Sst.PageFixtures do
  @moduledoc """
  A company with a ledger book, receivables and payables tax codes, and an
  SST registration for the SST pages' tests in `web_test/`: user 92 holds
  every capability and sets the scene; the signed-in user 91 holds only
  what each test grants. Compiled with the module's test support so the web
  tests need no `Code.require_file`.
  """

  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Finance.Sst.SstCase
  alias Bilimbi.Finance.Sst.TestFixtures

  @doc "The scene: see the moduledoc."
  def setup_scene! do
    TestFixtures.create_tables!()
    {:ok, scope} = Tenancy.scope(41)
    scope |> SstCase.build_company!(92) |> Map.put(:scope, scope)
  end

  @doc "What every SST page's figures read besides an SST capability."
  def reading_capabilities, do: SstCase.reading_capabilities()
end
