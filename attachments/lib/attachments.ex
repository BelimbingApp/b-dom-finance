defmodule Bilimbi.Finance.Attachments do
  @moduledoc """
  Source documents kept with the Finance records they support: a supplier's
  invoice scan behind a bill, a remittance behind a payment, a contract
  behind an invoice, a voucher behind a manual journal, the bank's own file
  behind an imported statement.

  Every function takes the validated `Bilimbi.Base.Tenancy.Scope` it was
  handed and an explicit company ID. Reads authorize `finance.attachments.view`
  and writes their own capability (`finance.attachments.create` to attach or
  replace, `finance.attachments.delete` to remove, and
  `finance.attachments.retention.manage` to lengthen the company's retention
  or an attachment's, or to place and release a legal hold) for the scope's
  signed-in actor and the target company at the moment they run, through
  `Bilimbi.Core.Company.authorize_company_target/3`: a system scope, a
  missing grant, or a sibling company without tenant-wide reach is
  `{:error, :unauthorized}`, and a company the scope cannot see is
  `{:error, :company_not_found}`. A write then holds
  `Bilimbi.Core.Company.lock_writable_company/2` for its transaction, so an
  archived company is `{:error, :company_archived}`.

  The record an attachment supports is described by a
  `Bilimbi.Finance.Attachments.Source` module of the Finance module that
  owns it, which reads the record through its own facade with the same
  scope: an attachment also needs whatever that facade asks to read the
  record, and answers that facade's refusal when it is not readable. Reading
  an attachment's metadata (`get_attachment/3`, the lists) needs the source's
  `view_capability/0` as well as `finance.attachments.view`: a list leaves
  out the attachments of every source the caller cannot read (one capability
  check per source module), and a single read or a retention change of one
  is `{:error, :unauthorized}`.

  The file's bytes are a records-grade document in `Bilimbi.Base.Artifacts`:
  stored once, hashed, and retained until the company's retention years
  (`get_retention/2`; seven until the company lengthens it) have passed
  after the end of the financial year the record's date falls in, the
  ledger's fiscal year when one covers the date, else the calendar year.
  Base refuses to delete the bytes before then, and a legal hold refuses it
  after. An attachment row is the link from the record to that artifact with
  the file's name, type, size, SHA-256, retain-until, and who captured it
  when; it is never changed. Its standing is its latest event: a draft
  record's attachment can be replaced (`replace/4`, which captures the new
  file and records `replaced` on the old) or removed (`remove/4`, an event
  with its reason), and once the record is final (posted, issued, approved,
  imported) its attachments are kept as they are, though one can still be
  added. A replaced or removed attachment's bytes stay retained and readable
  from its history; nothing here deletes them.

  Base Artifacts stores a file outside any transaction, so `attach/5` stores
  the bytes first and records the link in its own transaction; a record
  inserted in the same transaction as its file (a bank statement) uses
  `capture_file/5` before the transaction and `attach_capture/5` inside it.
  A storage refusal (`{:error, :retention_not_configured}` until an operator
  sets Base Artifacts' storage root, `{:error, :invalid_size}` over its
  limit) stores nothing.

  Results are plain maps; the schemas stay private to this module.
  """

  import Ecto.Query

  alias Bilimbi.Base.Artifacts
  alias Bilimbi.Base.Repo
  alias Bilimbi.Base.Tenancy
  alias Bilimbi.Base.Tenancy.Actor
  alias Bilimbi.Base.Tenancy.Scope
  alias Bilimbi.Core.Company
  alias Bilimbi.Finance.Attachments.ArtifactOwner
  alias Bilimbi.Finance.Attachments.Attachment
  alias Bilimbi.Finance.Attachments.AttachmentEvent
  alias Bilimbi.Finance.Attachments.Retention
  alias Bilimbi.Finance.Attachments.RetentionChange
  alias Bilimbi.Finance.Attachments.Source
  alias Ecto.Changeset

  @view "finance.attachments.view"
  @create "finance.attachments.create"
  @delete "finance.attachments.delete"
  @manage_retention "finance.attachments.retention.manage"

  # Base Artifacts' own `artifacts.max_bytes` setting is the limit that
  # holds; this one bounds what a page offers to upload.
  @max_file_bytes 25 * 1024 * 1024
  @default_content_type "application/octet-stream"
  @content_type ~r{^[\w.+-]+/[\w.+-]+$}
  @max_bigint 9_223_372_036_854_775_807
  @default_limit 100
  @max_limit 500

  @type refusal :: :unauthorized | :company_not_found
  @type write_refusal :: refusal() | :company_archived
  @type file :: %{
          required(:file_name) => String.t(),
          required(:content) => binary(),
          optional(:content_type) => String.t() | nil
        }
  @typedoc "A file stored by `capture_file/5`, waiting for `attach_capture/5`."
  @type capture :: map()

  @doc "The capability every attachments read asks for."
  def view_capability, do: @view

  @doc "The capability that attaches and replaces a source document."
  def create_capability, do: @create

  @doc "The capability that removes a draft record's attachment."
  def delete_capability, do: @delete

  @doc "The capability that lengthens retention and places or releases a legal hold."
  def manage_retention_capability, do: @manage_retention

  @doc "The largest file a page offers to upload, in bytes."
  def max_file_bytes, do: @max_file_bytes

  @doc "The years a company keeps source documents until it sets its own."
  def default_retention_years, do: Retention.default_years()

  @doc "The statuses an attachment moves through: `standing`, `replaced`, `removed`."
  def statuses, do: Attachment.statuses()

  ## Retention setting

  @doc """
  The company's retention: `%{years, change}`, where `change` is the latest
  change (`list_retention_changes/2` shows them) or nil for a company that
  keeps the default.
  """
  @spec get_retention(Scope.t(), term()) :: {:ok, map()} | {:error, refusal()}
  def get_retention(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok, retention_view(latest_retention_change(scope, company_id))}
    end
  end

  @doc """
  Lengthens the company's retention to `years` with a `reason`. The change
  applies to documents captured afterwards; an attachment already captured
  keeps its retain-until unless `extend_retention/4` moves it. Fewer or the
  same years is `{:error, :retention_not_lengthened}`.
  """
  @spec set_retention(Scope.t(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | :retention_not_lengthened | Changeset.t()}
  def set_retention(%Scope{} = scope, company_id, attributes) when is_map(attributes) do
    write(scope, company_id, @manage_retention, fn ->
      {user_id, impersonator_id} = actor_ids(scope)
      current = retention_years(latest_retention_change(scope, company_id))

      changeset =
        %RetentionChange{
          tenant_id: Scope.tenant_id(scope),
          company_id: company_id,
          changed_by_user_id: user_id,
          changed_by_impersonator_id: impersonator_id
        }
        |> RetentionChange.changeset(attributes)

      with {:ok, years} <- Changeset.fetch_change(changeset, :years),
           true <- years > current || {:error, :retention_not_lengthened},
           {:ok, change} <- Repo.insert(changeset) do
        {:ok, retention_view(change)}
      else
        :error -> {:error, changeset}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc "Every change of the company's retention, oldest first."
  @spec list_retention_changes(Scope.t(), term()) :: {:ok, [map()]} | {:error, refusal()}
  def list_retention_changes(%Scope{} = scope, company_id) do
    with :ok <- authorize(scope, company_id, @view) do
      {:ok,
       scope
       |> company_query(RetentionChange, company_id)
       |> order_by([c], asc: c.change_number)
       |> Repo.all()
       |> Enum.map(&retention_change_view/1)}
    end
  end

  @doc """
  The retain-until a document dated `date` gets now: the company's retention
  years after the end of the financial year the date falls in (the ledger's
  fiscal year covering it when the company has opened one, else the calendar
  year), at the end of that day in UTC. Reads the ledger's fiscal years, so
  it also needs `finance.ledger.view`.
  """
  @spec retain_until(Scope.t(), term(), Date.t()) ::
          {:ok, DateTime.t()} | {:error, refusal()}
  def retain_until(%Scope{} = scope, company_id, %Date{} = date) do
    with :ok <- authorize(scope, company_id, @view) do
      years = retention_years(latest_retention_change(scope, company_id))
      Retention.retain_until(scope, company_id, date, years)
    end
  end

  ## Attaching

  @doc """
  Keeps `file` (`file_name`, `content`, and an optional `content_type`) as a
  source document of the record `document_id` that `source` describes:
  stores the bytes as a records-grade artifact retained as
  `retain_until/3` says for the record's date, then records the attachment
  with who captured it and when. A record that is final takes more
  attachments; nothing is replaced.

  Refusals: the source's own (`{:error, :not_found}`, ...), an undated record
  (`{:error, :document_undated}`), the file's (`{:error, :invalid_file_name}`,
  `{:error, :empty_file}`, `{:error, :file_too_large}`,
  `{:error, :invalid_content_type}`), and Base Artifacts' storage refusals.
  """
  @spec attach(Scope.t(), term(), module(), term(), file()) ::
          {:ok, map()} | {:error, write_refusal() | term()}
  def attach(%Scope{} = scope, company_id, source, document_id, file) when is_map(file) do
    with :ok <- authorize(scope, company_id, @create),
         {:ok, source} <- valid_source(source),
         {:ok, document} <- source_document(scope, company_id, source, document_id),
         {:ok, capture} <- capture_file(scope, company_id, source, file, document.date) do
      attach_capture(scope, company_id, source, document_id, capture)
    end
  end

  @doc """
  Stores `file` as a records-grade artifact for a record of `source` dated
  `document_date`, before the transaction that creates the record. The
  capture it returns is handed to `attach_capture/5` inside that
  transaction; a capture whose record is never created stays a retained,
  unlinked document, so check what can be checked first.
  """
  @spec capture_file(Scope.t(), term(), module(), file(), Date.t()) ::
          {:ok, capture()} | {:error, write_refusal() | term()}
  def capture_file(%Scope{} = scope, company_id, source, file, document_date)
      when is_map(file) do
    with :ok <- authorize(scope, company_id, @create),
         {:ok, source} <- valid_source(source),
         {:ok, %Date{} = date} <- dated(document_date),
         {:ok, file} <- file_attributes(file),
         years = retention_years(latest_retention_change(scope, company_id)),
         {:ok, year_end} <- Retention.financial_year_end(scope, company_id, date),
         until = Retention.until(year_end, years),
         {:ok, stored} <-
           Artifacts.put(
             scope,
             company_id,
             ArtifactOwner,
             ArtifactOwner.reference(source.source_id()),
             file.content,
             file.content_type,
             retain_until: until,
             reason: retention_reason(source, years, year_end)
           ) do
      {:ok,
       %{
         source: source,
         document_date: date,
         artifact_id: stored.id,
         file_name: file.file_name,
         content_type: stored.content_type,
         byte_size: stored.byte_size,
         sha256: stored.sha256,
         retention_years: years,
         retain_until: stored.retain_until
       }}
    end
  end

  @doc """
  Records a `capture_file/5` capture as an attachment of `document_id`, which
  `source` reads back (so a record inserted in the caller's transaction is
  read in it). Authorizes and locks like any write; inside a caller's
  transaction it joins it.
  """
  @spec attach_capture(Scope.t(), term(), module(), term(), capture()) ::
          {:ok, map()} | {:error, write_refusal() | term()}
  def attach_capture(%Scope{} = scope, company_id, source, document_id, %{} = capture) do
    write(scope, company_id, @create, fn ->
      with {:ok, source} <- valid_source(source),
           true <- capture.source == source || {:error, :capture_mismatch},
           {:ok, document} <- source_document(scope, company_id, source, document_id),
           {:ok, attachment} <-
             insert_attachment(scope, company_id, document_id, document, capture) do
        {:ok, attachment_view(fetch_attachment(scope, company_id, attachment.id))}
      end
    end)
  end

  @doc """
  Replaces a standing attachment of a record that is not final with `file`:
  captures the new file as `attach/5` does and records `replaced` on the
  old, naming the new. A final record's attachment is
  `{:error, :document_final}`; a replaced or removed one is
  `{:error, :attachment_not_standing}`.
  """
  @spec replace(Scope.t(), term(), term(), file()) ::
          {:ok, map()} | {:error, write_refusal() | term()}
  def replace(%Scope{} = scope, company_id, attachment_id, file) when is_map(file) do
    with :ok <- authorize(scope, company_id, @create),
         {:ok, attachment, source} <- standing_attachment(scope, company_id, attachment_id),
         {:ok, document} <- source_document(scope, company_id, source, attachment.document_id),
         :ok <- changeable(document),
         {:ok, capture} <- capture_file(scope, company_id, source, file, document.date) do
      write(scope, company_id, @create, fn ->
        with {:ok, old, source} <- standing_attachment(scope, company_id, attachment_id),
             {:ok, document} <- source_document(scope, company_id, source, old.document_id),
             :ok <- changeable(document),
             {:ok, new} <-
               insert_attachment(scope, company_id, old.document_id, document, capture),
             {:ok, _event} <- insert_event(scope, old, "replaced", %{}, replacement_id: new.id) do
          {:ok, attachment_view(fetch_attachment(scope, company_id, new.id))}
        end
      end)
    end
  end

  @doc """
  Removes a standing attachment of a record that is not final: an event
  with its `reason`; the bytes stay retained and readable from the
  attachment's history (`get_attachment/3`, `read_attachment/3`). A final
  record's attachment is `{:error, :document_final}`.
  """
  @spec remove(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | term()}
  def remove(%Scope{} = scope, company_id, attachment_id, attributes) when is_map(attributes) do
    write(scope, company_id, @delete, fn ->
      with {:ok, attachment, source} <- standing_attachment(scope, company_id, attachment_id),
           {:ok, document} <- source_document(scope, company_id, source, attachment.document_id),
           :ok <- changeable(document),
           {:ok, _event} <- insert_event(scope, attachment, "removed", attributes) do
        {:ok, attachment_view(fetch_attachment(scope, company_id, attachment.id))}
      end
    end)
  end

  ## Retention of one attachment

  @doc """
  Moves an attachment's retain-until later, to the end of `retain_until`
  (a date) in UTC, with a `reason`: Base Artifacts refuses an equal or
  earlier date (`{:error, :retention_not_extended}`) and keeps the change
  with its own history; this records the event too. Any attachment, standing
  or not.
  """
  @spec extend_retention(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | term()}
  def extend_retention(%Scope{} = scope, company_id, attachment_id, attributes)
      when is_map(attributes) do
    with :ok <- authorize(scope, company_id, @manage_retention),
         {:ok, attachment} <- readable_attachment(scope, company_id, attachment_id),
         {:ok, %Date{} = date} <- dated(fetch(attributes, :retain_until)),
         until = Retention.end_of_day(date),
         {:ok, reason} <- event_reason(attributes),
         {:ok, _stored} <-
           Artifacts.retain(scope, company_id, ArtifactOwner, attachment.artifact_id, until,
             reason: reason
           ) do
      record_retention_event(scope, company_id, attachment, "retention_extended", attributes,
        retain_until: until
      )
    end
  end

  @doc """
  Places a legal hold on an attachment's bytes with a `reason`: Base
  Artifacts refuses their deletion past retain-until until the hold is
  released (`{:error, :already_on_hold}` for a second hold).
  """
  @spec place_hold(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | term()}
  def place_hold(%Scope{} = scope, company_id, attachment_id, attributes)
      when is_map(attributes),
      do: hold(scope, company_id, attachment_id, attributes, :place_hold, "hold_placed")

  @doc "Releases an attachment's legal hold with a `reason` (`{:error, :not_on_hold}` without one)."
  @spec release_hold(Scope.t(), term(), term(), map()) ::
          {:ok, map()} | {:error, write_refusal() | term()}
  def release_hold(%Scope{} = scope, company_id, attachment_id, attributes)
      when is_map(attributes),
      do: hold(scope, company_id, attachment_id, attributes, :release_hold, "hold_released")

  defp hold(scope, company_id, attachment_id, attributes, operation, event) do
    with :ok <- authorize(scope, company_id, @manage_retention),
         {:ok, attachment} <- readable_attachment(scope, company_id, attachment_id),
         {:ok, reason} <- event_reason(attributes),
         {:ok, _stored} <-
           apply(Artifacts, operation, [
             scope,
             company_id,
             ArtifactOwner,
             attachment.artifact_id,
             [reason: reason]
           ]) do
      record_retention_event(scope, company_id, attachment, event, attributes)
    end
  end

  defp record_retention_event(scope, company_id, attachment, event, attributes, extra \\ []) do
    write(scope, company_id, @manage_retention, fn ->
      with {:ok, _event} <- insert_event(scope, attachment, event, attributes, extra) do
        {:ok, attachment_view(fetch_attachment(scope, company_id, attachment.id))}
      end
    end)
  end

  ## Reading

  @doc """
  The standing attachments of the record `document_id` that `source`
  describes, oldest first, as `get_attachment/3` shows them.
  """
  @spec list_attachments(Scope.t(), term(), module(), term()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_source}
  def list_attachments(%Scope{} = scope, company_id, source, document_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, source} <- valid_source(source),
         {:ok, document_id} <- document_id(document_id) do
      if readable?(scope, company_id, source) do
        {:ok,
         scope
         |> attachments_query(company_id)
         |> where([a], a.source == ^source.source_id() and a.document_id == ^document_id)
         |> status_filter(scope, "standing")
         |> order_by([a], asc: a.id)
         |> preload_events(scope)
         |> Repo.all()
         |> Enum.map(&attachment_view/1)}
      else
        {:ok, []}
      end
    end
  end

  @doc """
  The company's attachments by number, as `get_attachment/3` shows them,
  leaving out those of a source the caller cannot read.
  Options: `source` (a source ID, `"finance/payables/bill"`), `document_ids`
  (only the attachments of those records of `source`), `status`
  (one of `statuses/0`; by default only standing attachments), `limit`
  (default 100, at most 500), and `after`, the last `attachment_number` of
  the previous page.
  """
  @spec list_company_attachments(Scope.t(), term(), keyword()) ::
          {:ok, [map()]} | {:error, refusal() | :invalid_option}
  def list_company_attachments(%Scope{} = scope, company_id, options \\ [])
      when is_list(options) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, filters} <- list_options(options) do
      {:ok,
       scope
       |> attachments_query(company_id)
       |> where([a], a.source_module in ^readable_source_modules(scope, company_id))
       |> then(fn query ->
         if filters.source, do: where(query, [a], a.source == ^filters.source), else: query
       end)
       |> then(fn query ->
         if filters.document_ids,
           do: where(query, [a], a.document_id in ^filters.document_ids),
           else: query
       end)
       |> status_filter(scope, filters.status)
       |> then(fn query ->
         if filters.after,
           do: where(query, [a], a.attachment_number > ^filters.after),
           else: query
       end)
       |> order_by([a], asc: a.attachment_number)
       |> limit(^filters.limit)
       |> preload_events(scope)
       |> Repo.all()
       |> Enum.map(&attachment_view/1)}
    end
  end

  @doc """
  One attachment: the record it supports (`source`, `source_label`,
  `document_id`, `document_label`, `document_date`), the file (`file_name`,
  `content_type`, `byte_size`, `sha256`), its retention (`retention_years`,
  `retain_until`, which follows the latest extension, and `on_hold`), who
  captured it when, its `status`, and its `events` oldest first. The caller must also be able to read the record's source
  (`{:error, :unauthorized}` otherwise).
  """
  @spec get_attachment(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :attachment_not_found | :source_unavailable}
  def get_attachment(%Scope{} = scope, company_id, attachment_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, attachment} <- readable_attachment(scope, company_id, attachment_id) do
      {:ok, attachment_view(attachment)}
    end
  end

  @doc """
  An attachment's bytes, for a download: `%{bytes, file_name, content_type,
  byte_size, sha256}`. Re-reads the record through its source (the actor
  must still be able to read it) and the bytes through Base Artifacts, which
  re-authorizes, checks the SHA-256, and records the read. A replaced or
  removed attachment is still read: its bytes are retained.
  """
  @spec read_attachment(Scope.t(), term(), term()) ::
          {:ok, map()} | {:error, refusal() | :attachment_not_found | term()}
  def read_attachment(%Scope{} = scope, company_id, attachment_id) do
    with :ok <- authorize(scope, company_id, @view),
         {:ok, attachment} <- readable_attachment(scope, company_id, attachment_id),
         {:ok, source} <- source_of(attachment),
         {:ok, _document} <- source_document(scope, company_id, source, attachment.document_id),
         {:ok, %{bytes: bytes}} <-
           Artifacts.read(scope, company_id, ArtifactOwner, attachment.artifact_id) do
      {:ok,
       %{
         bytes: bytes,
         file_name: attachment.file_name,
         content_type: attachment.content_type,
         byte_size: attachment.byte_size,
         sha256: attachment.sha256
       }}
    end
  end

  ## Writing

  defp insert_attachment(scope, company_id, document_id, document, capture) do
    {user_id, impersonator_id} = actor_ids(scope)

    with {:ok, %Date{} = date} <- dated(document.date),
         true <- Date.compare(date, capture.document_date) == :eq || {:error, :capture_mismatch} do
      %Attachment{
        tenant_id: Scope.tenant_id(scope),
        company_id: company_id,
        captured_by_user_id: user_id,
        captured_by_impersonator_id: impersonator_id
      }
      |> Attachment.changeset(%{
        source: capture.source.source_id(),
        source_module: Atom.to_string(capture.source),
        document_id: id(document_id),
        document_label: document.label,
        document_date: date,
        artifact_id: capture.artifact_id,
        file_name: capture.file_name,
        content_type: capture.content_type,
        byte_size: capture.byte_size,
        sha256: capture.sha256,
        retention_years: capture.retention_years,
        retain_until: capture.retain_until
      })
      |> Repo.insert()
    end
  end

  defp insert_event(scope, attachment, event, attributes, extra \\ []) do
    {user_id, impersonator_id} = actor_ids(scope)

    %AttachmentEvent{
      tenant_id: attachment.tenant_id,
      company_id: attachment.company_id,
      attachment_id: attachment.id,
      event: event,
      replacement_id: Keyword.get(extra, :replacement_id),
      retain_until: Keyword.get(extra, :retain_until),
      actor_user_id: user_id,
      actor_impersonator_id: impersonator_id
    }
    |> AttachmentEvent.changeset(Map.take(attributes, [:reason, "reason"]))
    |> Repo.insert()
  end

  defp retention_reason(source, years, year_end),
    do: "#{source.source_id()}: kept #{years} years after the financial year ending #{year_end}"

  ## Fetching

  defp fetch_attachment(scope, company_id, attachment_id) do
    case id(attachment_id) do
      nil ->
        nil

      attachment_id ->
        scope
        |> attachments_query(company_id)
        |> where([a], a.id == ^attachment_id)
        |> preload_events(scope)
        |> Repo.one()
    end
  end

  defp any_attachment(scope, company_id, attachment_id) do
    case fetch_attachment(scope, company_id, attachment_id) do
      nil -> {:error, :attachment_not_found}
      attachment -> {:ok, attachment}
    end
  end

  defp readable_attachment(scope, company_id, attachment_id) do
    with {:ok, attachment} <- any_attachment(scope, company_id, attachment_id),
         {:ok, source} <- source_of(attachment),
         :ok <- authorize(scope, company_id, source.view_capability()) do
      {:ok, attachment}
    end
  end

  defp readable?(scope, company_id, source),
    do: authorize(scope, company_id, source.view_capability()) == :ok

  defp readable_source_modules(scope, company_id) do
    scope
    |> attachments_query(company_id)
    |> distinct(true)
    |> select([a], a.source_module)
    |> Repo.all()
    |> Enum.filter(&((source = Source.from_name(&1)) && readable?(scope, company_id, source)))
  end

  defp standing_attachment(scope, company_id, attachment_id) do
    with {:ok, attachment} <- any_attachment(scope, company_id, attachment_id),
         "standing" <- Attachment.status(attachment) || {:error, :attachment_not_standing},
         {:ok, source} <- source_of(attachment) do
      {:ok, attachment, source}
    else
      {:error, _reason} = error -> error
      _ended -> {:error, :attachment_not_standing}
    end
  end

  defp source_of(%Attachment{source_module: name}) do
    case Source.from_name(name) do
      nil -> {:error, :source_unavailable}
      source -> {:ok, source}
    end
  end

  defp source_document(scope, company_id, source, document_id) do
    with {:ok, document_id} <- document_id(document_id),
         {:ok, %{} = document} <- source.document(scope, company_id, document_id),
         {:ok, _date} <- dated(document.date) do
      {:ok, document}
    end
  end

  # A final record keeps its attachments as they are.
  defp changeable(%{final?: true}), do: {:error, :document_final}
  defp changeable(%{final?: false}), do: :ok

  defp document_id(value) do
    case id(value) do
      nil -> {:error, :not_found}
      document_id -> {:ok, document_id}
    end
  end

  defp valid_source(source) do
    if Source.source?(source), do: {:ok, source}, else: {:error, :invalid_source}
  end

  defp dated(%Date{} = date), do: {:ok, date}
  defp dated(_other), do: {:error, :document_undated}

  defp file_attributes(file) do
    name = fetch(file, :file_name)
    content = fetch(file, :content)
    type = blank_to_nil(fetch(file, :content_type)) || @default_content_type

    cond do
      not is_binary(name) or String.trim(name) == "" or String.length(String.trim(name)) > 255 ->
        {:error, :invalid_file_name}

      not is_binary(content) or byte_size(content) == 0 ->
        {:error, :empty_file}

      byte_size(content) > @max_file_bytes ->
        {:error, :file_too_large}

      not is_binary(type) or not Regex.match?(@content_type, type) or byte_size(type) > 255 ->
        {:error, :invalid_content_type}

      true ->
        {:ok, %{file_name: String.trim(name), content: content, content_type: type}}
    end
  end

  defp event_reason(attributes) do
    case fetch(attributes, :reason) do
      reason when is_binary(reason) and byte_size(reason) <= 255 ->
        if String.trim(reason) == "", do: {:error, :reason_required}, else: {:ok, reason}

      nil ->
        {:error, :reason_required}

      _other ->
        {:error, :reason_required}
    end
  end

  defp list_options(options) do
    with true <- Keyword.keyword?(options),
         {:ok, filters} <-
           Keyword.validate(options,
             source: nil,
             document_ids: nil,
             status: "standing",
             limit: @default_limit,
             after: nil
           ),
         filters = Map.new(filters),
         true <- is_nil(filters.source) or is_binary(filters.source),
         true <- is_nil(filters.document_ids) or valid_document_ids?(filters.document_ids),
         true <- filters.status in ["all" | Attachment.statuses()],
         true <- is_integer(filters.limit) and filters.limit in 1..@max_limit,
         true <- is_nil(filters.after) or (is_integer(filters.after) and filters.after >= 0) do
      {:ok, filters}
    else
      _invalid -> {:error, :invalid_option}
    end
  end

  defp valid_document_ids?(ids), do: is_list(ids) and Enum.all?(ids, &(id(&1) == &1))

  ## Queries

  defp company_query(scope, schema, company_id) do
    schema
    |> Tenancy.scope_query(scope)
    |> where([r], r.company_id == ^company_id)
  end

  defp attachments_query(scope, company_id), do: company_query(scope, Attachment, company_id)

  defp preload_events(query, scope) do
    events =
      AttachmentEvent
      |> Tenancy.scope_query(scope)
      |> order_by([e], asc: e.id)

    preload(query, events: ^events)
  end

  # Which attachments an event ended; both reads start from the scope, as
  # every read of a tenant-owned table does.
  defp status_filter(query, _scope, "all"), do: query

  defp status_filter(query, scope, "standing") do
    ended = ended_ids(scope, ~w(replaced removed))
    where(query, [a], a.id not in subquery(ended))
  end

  defp status_filter(query, scope, status) do
    ended = ended_ids(scope, [status])
    where(query, [a], a.id in subquery(ended))
  end

  defp ended_ids(scope, events) do
    AttachmentEvent
    |> Tenancy.scope_query(scope)
    |> where([e], e.event in ^events)
    |> select([e], e.attachment_id)
  end

  defp latest_retention_change(scope, company_id) do
    scope
    |> company_query(RetentionChange, company_id)
    |> order_by([c], desc: c.change_number)
    |> limit(1)
    |> Repo.one()
  end

  defp retention_years(nil), do: Retention.default_years()
  defp retention_years(%RetentionChange{years: years}), do: years

  ## Views

  defp retention_view(change),
    do: %{years: retention_years(change), change: change && retention_change_view(change)}

  defp retention_change_view(change) do
    Map.take(change, [
      :id,
      :change_number,
      :years,
      :reason,
      :changed_by_user_id,
      :changed_by_impersonator_id,
      :changed_at
    ])
  end

  defp attachment_view(%Attachment{} = attachment) do
    source = Source.from_name(attachment.source_module)

    attachment
    |> Map.take([
      :id,
      :attachment_number,
      :source,
      :document_id,
      :document_label,
      :document_date,
      :artifact_id,
      :file_name,
      :content_type,
      :byte_size,
      :sha256,
      :retention_years,
      :retain_until,
      :captured_by_user_id,
      :captured_by_impersonator_id,
      :captured_at
    ])
    |> Map.merge(%{
      retain_until: effective_retain_until(attachment),
      on_hold: on_hold?(attachment),
      source_label: source && source.source_label(),
      status: Attachment.status(attachment),
      events: Enum.map(attachment.events, &event_view/1)
    })
  end

  defp effective_retain_until(%Attachment{events: events} = attachment) do
    events
    |> Enum.filter(&(&1.event == "retention_extended"))
    |> Enum.map(& &1.retain_until)
    |> Enum.reduce(attachment.retain_until, fn until, latest ->
      if DateTime.compare(until, latest) == :gt, do: until, else: latest
    end)
  end

  defp on_hold?(%Attachment{events: events}) do
    events
    |> Enum.filter(&(&1.event in ~w(hold_placed hold_released)))
    |> List.last()
    |> then(&(&1 != nil and &1.event == "hold_placed"))
  end

  defp event_view(%AttachmentEvent{} = event) do
    Map.take(event, [
      :id,
      :event,
      :replacement_id,
      :retain_until,
      :reason,
      :actor_user_id,
      :actor_impersonator_id,
      :occurred_at
    ])
  end

  ## Helpers

  defp actor_ids(scope) do
    %Actor{type: :user, user_id: user_id, impersonator_id: impersonator_id} = Scope.actor(scope)
    {user_id, impersonator_id}
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: value

  defp fetch(attributes, key), do: Map.get(attributes, key, Map.get(attributes, to_string(key)))

  defp id(value) when is_integer(value) and value in 1..@max_bigint, do: value

  defp id(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> id(integer)
      _other -> nil
    end
  end

  defp id(_value), do: nil

  defp authorize(scope, company_id, capability) do
    case Company.authorize_company_target(scope, company_id, capability) do
      {:ok, _company} -> :ok
      {:error, :not_found} -> {:error, :company_not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  defp write(scope, company_id, capability, fun) do
    with :ok <- authorize(scope, company_id, capability) do
      Repo.transact(fn ->
        case Company.lock_writable_company(scope, company_id) do
          {:ok, _proof} -> fun.()
          {:error, :not_found} -> {:error, :company_not_found}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end
end
