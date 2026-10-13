defmodule Bilimbi.Finance.Attachments.AttachmentsCase do
  @moduledoc """
  A company with an open ledger book, Base Artifacts storage in a temporary
  directory, an operator holding every capability, a second user holding
  only the view capability, and the stub source, for the module's suites.

  The contribution registry snapshot is process-global, so suites using this
  case do not run alongside other suites.
  """

  use ExUnit.CaseTemplate

  alias Bilimbi.Base.ModuleRegistry.ContributionRegistry
  alias Bilimbi.Finance.Attachments.TestFixtures
  alias Bilimbi.Finance.Ledger

  using do
    quote do
      use Bilimbi.Base.Database.DataCase, async: false

      import Bilimbi.Base.Database.TestHelpers, only: [errors_on: 1]
      import Bilimbi.Finance.Attachments.AttachmentsCase

      alias Bilimbi.Finance.Attachments
      alias Bilimbi.Finance.Attachments.StubSource
      alias Bilimbi.Finance.Attachments.TestFixtures
      alias Bilimbi.Finance.Ledger

      # After DataCase's setup, which checks out the sandbox connection.
      setup :setup_company
    end
  end

  @ledger ~w(finance.ledger.view finance.ledger.accounts.manage finance.ledger.entries.post finance.ledger.periods.manage finance.ledger.journals.submit finance.ledger.journals.approve)
  @attachments ~w(finance.attachments.view finance.attachments.create finance.attachments.delete finance.attachments.retention.manage)

  @doc "Every ledger and attachments capability the case grants."
  def all_capabilities, do: @ledger ++ @attachments

  @doc "The attachments capabilities alone."
  def attachments_capabilities, do: @attachments

  @doc "The case's company: see the moduledoc."
  def setup_company(_context) do
    context = TestFixtures.setup_attachments!()
    on_exit(&ContributionRegistry.clear_for_test!/0)
    root = TestFixtures.put_artifacts_root!()

    operator = TestFixtures.sign_in!(context.first_scope, 73, 91, all_capabilities())

    viewer =
      TestFixtures.sign_in!(
        context.first_scope,
        73,
        92,
        ~w(finance.ledger.view finance.attachments.view)
      )

    {:ok, _book} = Ledger.open_book(operator, 73, %{currency_code: "XTS", minor_units: 2})

    Map.merge(context, %{operator: operator, viewer: viewer, root: root})
  end
end
