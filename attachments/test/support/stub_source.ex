defmodule Bilimbi.Finance.Attachments.StubSource do
  @moduledoc """
  A record source for the module's tests: records the test puts in the
  process, with the date and standing it chooses, so the facade's rules are
  proved without another module's records. `put_document!/2` adds one;
  `finalise!/1` makes it final.
  """

  @behaviour Bilimbi.Finance.Attachments.Source

  alias Bilimbi.Base.Tenancy.Scope

  @key {__MODULE__, :documents}

  @impl true
  def source_id, do: "finance/test/record"

  @impl true
  def source_label, do: "Test record"

  @impl true
  def view_capability, do: Bilimbi.Finance.Ledger.view_capability()

  @impl true
  def document(%Scope{}, _company_id, id) do
    case Map.fetch(documents(), id) do
      {:ok, document} -> {:ok, document}
      :error -> {:error, :not_found}
    end
  end

  @doc "Adds record `id`, dated `~D[2026-10-01]` and not final unless given."
  def put_document!(id, attributes \\ %{}) do
    document =
      Map.merge(%{label: "Record #{id}", date: ~D[2026-10-01], final?: false}, attributes)

    Process.put(@key, Map.put(documents(), id, document))
    document
  end

  @doc "Makes record `id` final."
  def finalise!(id), do: put_document!(id, Map.put(Map.fetch!(documents(), id), :final?, true))

  defp documents, do: Process.get(@key, %{})
end
