defmodule Bilimbi.Finance.Ledger.Contributions do
  @moduledoc false
  @behaviour Bilimbi.Base.ModuleRegistry.ContributionProvider

  @view "finance.ledger.view"
  @manage_accounts "finance.ledger.accounts.manage"
  @post_entries "finance.ledger.entries.post"
  @manage_periods "finance.ledger.periods.manage"
  @reopen_periods "finance.ledger.periods.reopen"
  @lock_periods "finance.ledger.periods.lock"
  # "manage", "submit", "approve", and "review" are Base Authz's verbs.
  @manage_duty_separation "finance.ledger.duty-separation.manage"
  @manage_controlled_bookkeeping "finance.ledger.controlled-bookkeeping.manage"
  @review_late_recordings "finance.ledger.late-recordings.review"
  @submit_journals "finance.ledger.journals.submit"
  @approve_journals "finance.ledger.journals.approve"
  @review_exceptions "finance.ledger.approval-exceptions.review"

  @capabilities [
    @view,
    @manage_accounts,
    @post_entries,
    @manage_periods,
    @reopen_periods,
    @lock_periods,
    @manage_duty_separation,
    @manage_controlled_bookkeeping,
    @review_late_recordings,
    @submit_journals,
    @approve_journals,
    @review_exceptions
  ]

  @impl true
  def contributions do
    %{
      authz: %{
        domains: %{"finance" => "Finance domain modules"},
        verbs: ["post", "reopen", "lock"],
        capabilities: @capabilities,
        roles: %{"tenant_owner" => %{capabilities: @capabilities}}
      }
    }
  end
end
