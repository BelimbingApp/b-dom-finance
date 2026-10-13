defmodule Bilimbi.Finance.Attachments.SchemaContract do
  @moduledoc """
  Fresh Bilimbi source document attachments schema.

  Not registered in the descriptor: compatibility verification runs before
  pending Bilimbi-only migrations, when these tables correctly do not exist.
  `test/schema_contract_test.exs` verifies it against the migration.
  """
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check text is PostgreSQL's canonical form, which the verifier compares
  # after removing whitespace and parentheses.

  def migration_versions, do: [20_261_017_090_000]

  def migration_version, do: List.last(migration_versions())

  @impl true
  def tables do
    [
      %{
        name: "finance_attachments_retention_changes",
        columns:
          owned_columns("finance_attachments_retention_changes")
          |> Map.merge(%{
            "change_number" => column(:bigint, false),
            "years" => column(:integer, false),
            "reason" => column({:varchar, 500}, false),
            "changed_by_user_id" => column(:bigint, false),
            "changed_by_impersonator_id" => column(:bigint, true),
            "changed_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_attachments_retention_changes_pkey" => index(["id"], true),
          "finance_attachments_retention_changes_id_company_unique" =>
            index(["id", "company_id"], true),
          "finance_attachments_retention_changes_company_number_unique" =>
            index(["company_id", "change_number"], true),
          "finance_attachments_retention_changes_tenant_company_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_attachments_retention_changes_change_number" => check("(change_number > 0)"),
          "finance_attachments_retention_changes_years" => check("(years > 0)"),
          "finance_attachments_retention_changes_reason" =>
            check("(btrim((reason)::text) <> ''::text)")
        }
      },
      %{
        name: "finance_attachments",
        columns:
          owned_columns("finance_attachments")
          |> Map.merge(%{
            "attachment_number" => column(:bigint, false),
            "source" => column({:varchar, 100}, false),
            "source_module" => column({:varchar, 255}, false),
            "document_id" => column(:bigint, false),
            "document_label" => column({:varchar, 100}, false),
            "document_date" => column(:date, false),
            "artifact_id" => column(:uuid, false),
            "file_name" => column({:varchar, 255}, false),
            "content_type" => column({:varchar, 255}, false),
            "byte_size" => column(:bigint, false),
            "sha256" => column({:varchar, 64}, false),
            "retention_years" => column(:integer, false),
            "retain_until" => column({:timestamp, 6}, false),
            "captured_by_user_id" => column(:bigint, false),
            "captured_by_impersonator_id" => column(:bigint, true),
            "captured_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_attachments_pkey" => index(["id"], true),
          "finance_attachments_id_company_unique" => index(["id", "company_id"], true),
          "finance_attachments_company_number_unique" =>
            index(["company_id", "attachment_number"], true),
          "finance_attachments_artifact_unique" => index(["artifact_id"], true),
          "finance_attachments_document_index" =>
            index(["company_id", "source", "document_id", "id"]),
          "finance_attachments_tenant_company_index" => index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_attachments_attachment_number" => check("(attachment_number > 0)"),
          "finance_attachments_source" => check("(btrim((source)::text) <> ''::text)"),
          "finance_attachments_document_id" => check("(document_id > 0)"),
          "finance_attachments_document_label" =>
            check("(btrim((document_label)::text) <> ''::text)"),
          "finance_attachments_file_name" => check("(btrim((file_name)::text) <> ''::text)"),
          "finance_attachments_byte_size" => check("(byte_size > 0)"),
          "finance_attachments_sha256" => check("((sha256)::text ~ '^[0-9a-f]{64}$'::text)"),
          "finance_attachments_retention_years" => check("(retention_years > 0)"),
          "finance_attachments_retain_until" => check("(retain_until > document_date)")
        }
      },
      %{
        name: "finance_attachment_events",
        columns:
          owned_columns("finance_attachment_events")
          |> Map.merge(%{
            "attachment_id" => column(:bigint, false),
            "event" => column({:varchar, 30}, false),
            "replacement_id" => column(:bigint, true),
            "retain_until" => column({:timestamp, 6}, true),
            "reason" => column({:varchar, 500}, true),
            "actor_user_id" => column(:bigint, false),
            "actor_impersonator_id" => column(:bigint, true),
            "actor_system_principal" => column({:varchar, 100}, true),
            "occurred_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_attachment_events_pkey" => index(["id"], true),
          "finance_attachment_events_standing_unique" => %{
            columns: ["attachment_id"],
            unique: true,
            where:
              "((event)::text = ANY ((ARRAY['replaced'::character varying, 'removed'::character varying])::text[]))"
          },
          "finance_attachment_events_attachment_index" =>
            index(["company_id", "attachment_id", "id"]),
          "finance_attachment_events_tenant_company_index" => index(["tenant_id", "company_id"])
        },
        foreign_keys: %{
          "finance_attachment_events_attachment_fkey" =>
            company_reference("attachment_id", "finance_attachments"),
          "finance_attachment_events_replacement_fkey" =>
            company_reference("replacement_id", "finance_attachments")
        },
        checks: %{
          "finance_attachment_events_event" =>
            check(
              one_of("event", ~w(replaced removed retention_extended hold_placed hold_released))
            ),
          "finance_attachment_events_replacement" =>
            check("(((event)::text = 'replaced'::text) = (replacement_id IS NOT NULL))"),
          "finance_attachment_events_not_self" =>
            check("((replacement_id IS NULL) OR (replacement_id <> attachment_id))"),
          "finance_attachment_events_retain_until" =>
            check("(((event)::text = 'retention_extended'::text) = (retain_until IS NOT NULL))"),
          "finance_attachment_events_reason" =>
            check(
              "(#{one_of("event", ~w(replaced retention_extended))} OR " <>
                "((reason IS NOT NULL) AND (btrim((reason)::text) <> ''::text)))"
            )
        }
      }
    ]
  end

  defp one_of(column, values) do
    list = Enum.map_join(values, ", ", &"'#{&1}'::character varying")
    "((#{column})::text = ANY ((ARRAY[#{list}])::text[]))"
  end

  defp owned_columns(table) do
    %{
      "id" => column(:bigint, false, {:sequence, "#{table}_id_seq"}),
      "tenant_id" => column(:bigint, false),
      "company_id" => column(:bigint, false)
    }
  end

  # Rows of one company reference each other through `(id, company_id)`.
  defp company_reference(column, table) do
    %{
      columns: [column, "company_id"],
      references: {table, ["id", "company_id"]},
      on_delete: :restrict
    }
  end

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique \\ false), do: %{columns: columns, unique: unique, where: nil}

  defp check(expression), do: %{expression: expression}
end
