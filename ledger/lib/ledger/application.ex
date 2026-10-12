defmodule Bilimbi.Finance.Ledger.Application do
  @moduledoc false

  use Application

  alias Bilimbi.Finance.Ledger.Postings

  # Subscriptions outlive a relay restart: the relay is started after the
  # registry and resumes listening for whoever is still registered.
  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{Registry, keys: :duplicate, name: Postings.registry()}, Postings],
      strategy: :rest_for_one,
      name: Bilimbi.Finance.Ledger.Supervisor
    )
  end
end
