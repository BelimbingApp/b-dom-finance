defmodule Bilimbi.Finance.Reports.Snapshot do
  @moduledoc false
  alias Bilimbi.Base.Repo
  alias Ecto.Adapters.SQL

  # An outer transaction is required: changing isolation after the caller's
  # first read cannot freeze metadata. Do not silently accept a partial pin.
  def run(fun) do
    if Repo.in_transaction?() do
      {:error, :transaction_already_open}
    else
      Repo.transact(fn ->
        SQL.query!(Repo.get_dynamic_repo(), "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
        fun.()
      end)
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres && error.postgres.code == :serialization_failure,
        do: {:error, :snapshot_changed},
        else: reraise(error, __STACKTRACE__)
  end
end
