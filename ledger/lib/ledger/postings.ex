defmodule Bilimbi.Finance.Ledger.Postings do
  @moduledoc false

  # Relays the database's notice of a posted entry to the processes on this
  # node that subscribed to the entry's company.
  #
  # The migration's trigger calls `pg_notify` in the posting transaction, and
  # PostgreSQL delivers a notification only when that transaction commits: a
  # rolled-back post announces nothing, and a post inside a caller's own
  # transaction is announced at that transaction's commit, after the entry
  # is readable. Every node's listener hears every notice, so a subscriber on
  # any node learns of a posting made on any other. The listening connection
  # opens with the first subscription on the node, never at boot, and a
  # database that cannot be reached is retried rather than allowed to crash
  # the ledger's supervision tree.

  use GenServer

  alias Bilimbi.Base.Repo

  @channel "finance_ledger_postings"
  @registry Bilimbi.Finance.Ledger.Postings.Registry
  @retry_ms 5_000

  @doc "The PostgreSQL channel the ledger's trigger notifies."
  def channel, do: @channel

  @doc "The registry of subscribed processes, keyed by `{tenant_id, company_id}`."
  def registry, do: @registry

  def start_link(_options), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Registers the caller for one company's postings and asks the relay to
  listen. The relay connects in its own process; a caller that must know the
  connection is listening waits with `:sys.get_state/1` on the relay.
  """
  def subscribe(tenant_id, company_id) do
    key = {tenant_id, company_id}

    unless key in Registry.keys(@registry, self()) do
      {:ok, _owner} = Registry.register(@registry, key, nil)
    end

    GenServer.cast(__MODULE__, :listen)
  end

  # A restarted relay finds the subscriptions it held still registered.
  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{connection: nil}, {:continue, :listen}}
  end

  @impl true
  def handle_continue(:listen, state), do: {:noreply, listen(state)}

  @impl true
  def handle_cast(:listen, state), do: {:noreply, listen(state)}

  @impl true
  def handle_info({:notification, _connection, _ref, @channel, payload}, state) do
    with [tenant_id, company_id, entry_number] <- String.split(payload, ":"),
         {tenant_id, ""} <- Integer.parse(tenant_id),
         {company_id, ""} <- Integer.parse(company_id),
         {entry_number, ""} <- Integer.parse(entry_number) do
      notice = {:finance_ledger_posted, %{company_id: company_id, entry_number: entry_number}}

      Registry.dispatch(@registry, {tenant_id, company_id}, fn subscribers ->
        for {pid, _value} <- subscribers, do: send(pid, notice)
      end)
    end

    {:noreply, state}
  end

  def handle_info(:retry, state), do: {:noreply, listen(state)}

  def handle_info({:EXIT, connection, _reason}, %{connection: connection} = state) do
    Process.send_after(self(), :retry, @retry_ms)
    {:noreply, %{state | connection: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp listen(%{connection: nil} = state) do
    if Registry.count(@registry) > 0, do: connect(state), else: state
  end

  defp listen(state), do: state

  # Connected before LISTEN, so a subscriber that waited on the relay hears
  # every posting committed after it subscribed. Once connected, the
  # connection reconnects and listens again on its own.
  defp connect(state) do
    options =
      Repo.config()
      |> Keyword.drop([:pool, :pool_size, :name])
      |> Keyword.merge(auto_reconnect: true, sync_connect: true)

    case Postgrex.Notifications.start_link(options) do
      {:ok, connection} ->
        {_status, _ref} = Postgrex.Notifications.listen(connection, @channel)
        %{state | connection: connection}

      {:error, _reason} ->
        Process.send_after(self(), :retry, @retry_ms)
        state
    end
  end
end
