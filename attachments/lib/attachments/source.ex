defmodule Bilimbi.Finance.Attachments.Source do
  @moduledoc """
  The record a source document supports, as the module that owns the record
  describes it.

  A Finance module that keeps source documents implements this behaviour
  once per kind of record (a bill, a payment request, an invoice, a bank
  statement) and hands the module to `Bilimbi.Finance.Attachments`, which
  stores the module's name with each attachment and asks it again on every
  read and write. `view_capability/0` is what the owning module asks to read
  its records: every metadata read of an attachment (`get_attachment/3`, the
  lists, the source documents page) also needs it, and leaves out the
  attachments of a source whose records the caller cannot read, so the
  attachments grant alone discloses no record's label, file name, or date.
  `document/3` reads the record through the owning module's
  own facade with the caller's scope, so it carries that facade's
  authorization, and answers:

  - `label`: how the record is named to a person (`"Bill 12"`), kept with
    the attachment for the index and the auditor's pack;
  - `date`: the record's own date, which decides the financial year the
    retention counts from;
  - `final?`: whether the record is beyond change (posted, issued,
    approved, imported), after which its attachments are kept as they are:
    one can still be added, none replaced or removed.

  Any refusal (`{:error, :not_found}`, `{:error, :unauthorized}`, ...) is
  returned to the caller as the attachment operation's refusal.
  """

  alias Bilimbi.Base.Tenancy.Scope

  @type document :: %{label: String.t(), date: Date.t(), final?: boolean()}

  @doc "The source's stable identifier, `\"finance/<module>/<record>\"`."
  @callback source_id() :: String.t()

  @doc "The kind of record, as a person reads it (`\"Bill\"`)."
  @callback source_label() :: String.t()

  @doc "The capability the owning module asks to read its records."
  @callback view_capability() :: String.t()

  @doc "The record, read through its module's facade with the caller's scope."
  @callback document(Scope.t(), term(), term()) :: {:ok, document()} | {:error, term()}

  @doc "Whether the module implements this behaviour."
  @spec source?(term()) :: boolean()
  def source?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :source_id, 0) and
      function_exported?(module, :source_label, 0) and
      function_exported?(module, :view_capability, 0) and
      function_exported?(module, :document, 3)
  end

  def source?(_other), do: false

  @doc "The source module an attachment row names, or nil if it is no longer mounted."
  @spec from_name(String.t()) :: module() | nil
  def from_name(name) when is_binary(name) do
    module = String.to_existing_atom(name)
    if source?(module), do: module
  rescue
    ArgumentError -> nil
  end
end
