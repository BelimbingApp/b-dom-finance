defmodule Bilimbi.Finance.Einvoice.MyInvois.TokenCache do
  @moduledoc """
  Access tokens by company, environment, and client ID, node-local.

  The authority allows 12 logins a minute and a token lives an hour, so a
  token is reused until shortly before it expires. A changed client ID is a
  different key, and a refused token is dropped with `delete/1`. A token is
  a short-lived credential: it lives only in this ETS table, never in the
  database, a log, or an exchange record.
  """

  use GenServer

  @table __MODULE__
  # Renew this long before the authority's expiry, so a request never
  # leaves with a token that lapses in flight.
  @margin_seconds 120

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "A live token for `key`, or `:error`."
  @spec fetch(term(), integer()) :: {:ok, String.t()} | :error
  def fetch(key, now \\ System.system_time(:second)) do
    case :ets.lookup(@table, key) do
      [{^key, token, expires_at}] when expires_at - @margin_seconds > now -> {:ok, token}
      _other -> :error
    end
  end

  @doc "Keeps `token` for `key` until `expires_in` seconds from now."
  @spec put(term(), String.t(), pos_integer(), integer()) :: :ok
  def put(key, token, expires_in, now \\ System.system_time(:second)) do
    true = :ets.insert(@table, {key, token, now + expires_in})
    :ok
  end

  @doc "Forgets the token for `key`."
  @spec delete(term()) :: :ok
  def delete(key) do
    true = :ets.delete(@table, key)
    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
