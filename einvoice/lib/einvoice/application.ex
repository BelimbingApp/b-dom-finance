defmodule Bilimbi.Finance.Einvoice.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Bilimbi.Finance.Einvoice.MyInvois.TokenCache],
      strategy: :one_for_one,
      name: Bilimbi.Finance.Einvoice.Supervisor
    )
  end
end
