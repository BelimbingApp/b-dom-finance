defmodule Bilimbi.Finance.Attachments.Web.Panel do
  @moduledoc """
  The source documents of one record, for the record's page: a list of the
  standing attachments with a download link each, an upload form for the
  next, and, while the record is not final, a replace and a remove action
  per attachment. Every action is a facade call that re-asks its capability;
  the `can_*?` assigns only decide which controls show.

  The page renders it with the record's identity and standing:

      <.live_component
        module={Bilimbi.Finance.Attachments.Web.Panel}
        id="payables-bill-attachments"
        current_scope={@current_scope}
        company_id={@company_id}
        source={Bilimbi.Finance.Payables.Attachments.Bill}
        document_id={@document.id}
        final?={@document.status in ~w(approved held posted voided)}
      />
  """

  use Bilimbi.Base.UI, :live_component

  alias Bilimbi.Base.Authz.LiveAuthorization
  alias Bilimbi.Finance.Attachments
  alias Bilimbi.Finance.Attachments.Web.Format

  @create Attachments.create_capability()
  @delete Attachments.delete_capability()

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:action, nil)
     |> assign(:reason, "")
     |> assign(:notice, nil)
     |> allow_upload(:file,
       accept: :any,
       max_entries: 1,
       max_file_size: Attachments.max_file_bytes()
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> load()}
  end

  defp load(socket) do
    %{current_scope: %{scope: scope} = current_scope, company_id: company_id} = socket.assigns

    attachments =
      case Attachments.list_attachments(
             scope,
             company_id,
             socket.assigns.source,
             socket.assigns.document_id
           ) do
        {:ok, attachments} -> attachments
        {:error, _reason} -> []
      end

    socket
    |> assign(:attachments, attachments)
    |> assign(:can_create?, LiveAuthorization.allowed_now?(current_scope, @create))
    |> assign(:can_delete?, LiveAuthorization.allowed_now?(current_scope, @delete))
  end

  @impl true
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :file, ref)}

  def handle_event("attach", _params, socket) do
    case LiveAuthorization.authorize_event(socket, @create) do
      {:denied, socket} -> {:noreply, socket}
      {:ok, socket} -> {:noreply, attach(socket)}
    end
  end

  def handle_event("open_replace", %{"id" => id}, socket),
    do: {:noreply, assign(socket, action: {:replace, id}, notice: nil)}

  def handle_event("open_remove", %{"id" => id}, socket),
    do: {:noreply, assign(socket, action: {:remove, id}, reason: "", notice: nil)}

  def handle_event("cancel_action", _params, socket),
    do: {:noreply, assign(socket, action: nil, reason: "")}

  def handle_event("reason", %{"removal" => %{"reason" => reason}}, socket),
    do: {:noreply, assign(socket, :reason, reason)}

  def handle_event("remove", %{"removal" => %{"reason" => reason}}, socket) do
    case LiveAuthorization.authorize_event(socket, @delete) do
      {:denied, socket} -> {:noreply, socket}
      {:ok, socket} -> {:noreply, remove(socket, reason)}
    end
  end

  def report_action_failure(socket, message), do: assign(socket, :notice, {:error, message})

  # The uploaded bytes are read once, here, and handed to the facade, which
  # keeps them as a records-grade document.
  defp attach(socket) do
    files =
      consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
        {:ok,
         %{
           file_name: entry.client_name,
           content: File.read!(path),
           content_type: entry.client_type
         }}
      end)

    case files do
      [] ->
        assign(socket, :notice, {:error, "Choose a file first."})

      [file] ->
        %{current_scope: %{scope: scope}, company_id: company_id} = socket.assigns

        result =
          case socket.assigns.action do
            {:replace, id} ->
              Attachments.replace(scope, company_id, id, file)

            _attach ->
              Attachments.attach(
                scope,
                company_id,
                socket.assigns.source,
                socket.assigns.document_id,
                file
              )
          end

        case result do
          {:ok, attachment} ->
            socket
            |> assign(:action, nil)
            |> assign(
              :notice,
              {:success,
               "#{attachment.file_name} is kept until #{Format.retain_until(attachment.retain_until)}."}
            )
            |> load()

          {:error, reason} ->
            assign(socket, :notice, {:error, Format.refusal(reason)})
        end
    end
  end

  defp remove(socket, reason) do
    %{current_scope: %{scope: scope}, company_id: company_id, action: {:remove, id}} =
      socket.assigns

    case Attachments.remove(scope, company_id, id, %{reason: reason}) do
      {:ok, attachment} ->
        socket
        |> assign(action: nil, reason: "")
        |> assign(
          :notice,
          {:success, "#{attachment.file_name} was removed; its bytes stay retained."}
        )
        |> load()

      {:error, reason} ->
        assign(socket, :notice, {:error, Format.refusal(reason)})
    end
  end

  defp replacing?(%{action: {:replace, id}}, attachment), do: to_string(attachment.id) == id
  defp replacing?(_assigns, _attachment), do: false

  defp removing?(%{action: {:remove, id}}, attachment), do: to_string(attachment.id) == id
  defp removing?(_assigns, _attachment), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.card id={"#{@id}-card"} inner_class="p-5 sm:p-6" role="region" aria-labelledby={"#{@id}-heading"}>
        <.section_heading id={"#{@id}-heading"} title="Source documents" count={length(@attachments)}>
          <:description>
            The original files behind this record, kept until their retain-until date; nothing deletes them before it.
          </:description>
        </.section_heading>

        <p
          :if={@notice}
          id={"#{@id}-notice"}
          role="status"
          class={["mt-3 text-sm", if(elem(@notice, 0) == :error, do: "text-danger", else: "text-success")]}
        >
          {elem(@notice, 1)}
        </p>

        <ul :if={@attachments != []} id={"#{@id}-list"} class="mt-4 divide-y divide-line">
          <li
            :for={attachment <- @attachments}
            id={"#{@id}-#{attachment.id}"}
            class="flex flex-wrap items-center justify-between gap-2 py-3 text-sm"
          >
            <div class="min-w-0">
              <.link
                id={"#{@id}-#{attachment.id}-download"}
                href={~p"/finance/attachments/#{attachment.id}/download"}
                download={attachment.file_name}
                class="font-medium"
              >
                {attachment.file_name}
              </.link>
              <p class="text-ink-muted">
                {Format.bytes(attachment.byte_size)} · SHA-256
                <span title={attachment.sha256} class="font-mono">{Format.short_hash(attachment.sha256)}</span>
                · kept until {Format.retain_until(attachment.retain_until)}{if attachment.on_hold, do: " (on legal hold)"} · captured
                <.datetime id={"#{@id}-#{attachment.id}-captured"} value={attachment.captured_at} />
              </p>
            </div>
            <div :if={!@final? and (@can_create? or @can_delete?)} class="flex gap-2">
              <.button
                :if={@can_create? and !replacing?(assigns, attachment)}
                type="button"
                id={"#{@id}-#{attachment.id}-replace"}
                phx-click="open_replace"
                phx-value-id={attachment.id}
                phx-target={@myself}
              >
                Replace
              </.button>
              <.button
                :if={@can_delete? and !removing?(assigns, attachment)}
                type="button"
                id={"#{@id}-#{attachment.id}-remove"}
                phx-click="open_remove"
                phx-value-id={attachment.id}
                phx-target={@myself}
                variant="danger"
              >
                Remove
              </.button>
            </div>
            <.form
              :if={removing?(assigns, attachment)}
              for={%{}}
              as={:removal}
              id={"#{@id}-#{attachment.id}-remove-form"}
              phx-change="reason"
              phx-submit="remove"
              phx-target={@myself}
              class="basis-full"
            >
              <.input
                type="text"
                name="removal[reason]"
                id={"#{@id}-#{attachment.id}-remove-reason"}
                value={@reason}
                label="Reason for removing (1 to 500 characters)"
                maxlength="500"
                required
              />
              <div class="mt-2 flex justify-end gap-2">
                <.button type="button" phx-click="cancel_action" phx-target={@myself}>Keep file</.button>
                <.button
                  type="submit"
                  id={"#{@id}-#{attachment.id}-remove-confirm"}
                  variant="danger"
                  phx-disable-with="Removing…"
                >
                  Remove file
                </.button>
              </div>
            </.form>
          </li>
        </ul>

        <.empty_state
          :if={@attachments == [] and !@can_create?}
          id={"#{@id}-empty"}
          title="No source documents"
          reason="Nothing has been attached to this record."
        />

        <.form
          :if={@can_create?}
          for={%{}}
          id={"#{@id}-form"}
          phx-change="validate_upload"
          phx-submit="attach"
          phx-target={@myself}
          class="mt-4 space-y-3"
        >
          <p :if={match?({:replace, _}, @action)} id={"#{@id}-replacing"} class="text-sm">
            The file you choose replaces the one selected; the old one stays in the record's history.
            <.button type="button" phx-click="cancel_action" phx-target={@myself}>Keep it instead</.button>
          </p>
          <.live_file_input upload={@uploads.file} class="block text-sm" />
          <div :for={entry <- @uploads.file.entries} id={"#{@id}-upload-#{entry.ref}"} class="text-sm">
            {entry.client_name} · {entry.progress}%
            <.button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              phx-target={@myself}
              aria-label="Cancel upload"
            >
              Remove
            </.button>
            <p :for={error <- upload_errors(@uploads.file, entry)} class="text-danger">
              {upload_error(error)}
            </p>
          </div>
          <p :for={error <- upload_errors(@uploads.file)} class="text-sm text-danger">
            {upload_error(error)}
          </p>
          <.button type="submit" id={"#{@id}-submit"} variant="primary" phx-disable-with="Keeping…">
            {if match?({:replace, _}, @action), do: "Replace file", else: "Attach file"}
          </.button>
        </.form>
      </.card>
    </div>
    """
  end

  defp upload_error(:too_large), do: "The file is larger than this page accepts."
  defp upload_error(:too_many_files), do: "Choose one file at a time."
  defp upload_error(:not_accepted), do: "That kind of file is not accepted."
  defp upload_error(other), do: "The upload failed: #{inspect(other)}."
end
