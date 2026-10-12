defmodule Bilimbi.Finance.Einvoice.SchemaContract do
  @moduledoc """
  Fresh Bilimbi e-invoicing schema.

  Not registered in the descriptor: compatibility verification runs before
  pending Bilimbi-only migrations, when these tables correctly do not exist.
  `test/schema_contract_test.exs` verifies it against the migration.
  """
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check and predicate text is PostgreSQL's canonical form, which the
  # verifier compares after removing whitespace and parentheses.

  @doc "The migrations that build this contract, in order."
  def migration_versions,
    do: [20_261_012_200_000, 20_261_013_090_000, 20_261_013_143_000, 20_261_013_221_500]

  def migration_version, do: List.last(migration_versions())

  @environments "(environment)::text = ANY ((ARRAY['sandbox'::character varying, " <>
                  "'production'::character varying])::text[])"

  @actor "(((actor_type)::text = 'user'::text) AND (actor_user_id IS NOT NULL) AND " <>
           "(system_principal IS NULL)) OR (((actor_type)::text = 'system'::text) AND " <>
           "(actor_user_id IS NULL) AND (actor_impersonator_id IS NULL) AND " <>
           "(system_principal IS NOT NULL))"

  @impl true
  def tables do
    [
      documents(),
      lines(),
      submissions(),
      status_events(),
      consolidated_sources(),
      code_overrides()
    ]
  end

  defp documents do
    table = "finance_einvoice_documents"

    %{
      name: table,
      columns:
        owned_columns(table)
        |> Map.merge(%{
          "authority" => column({:varchar, 32}, false),
          "environment" => column({:varchar, 16}, false),
          "document_type" => column({:varchar, 8}, false),
          "code_number" => column({:varchar, 50}, false),
          "issued_at" => column({:timestamp, 0}, false),
          "currency_code" => column({:varchar, 3}, false),
          "exchange_rate" => column({:numeric, 20, 6}, true),
          "supplier" => column(:jsonb, false),
          "buyer" => column(:jsonb, false),
          "details" => column(:jsonb, false, {:string, "{}"}),
          "original_document_id" => column(:bigint, true),
          "line_extension_amount" => column({:numeric, 20, 2}, false),
          "tax_exclusive_amount" => column({:numeric, 20, 2}, false),
          "tax_amount" => column({:numeric, 20, 2}, false),
          "tax_inclusive_amount" => column({:numeric, 20, 2}, false),
          "payable_amount" => column({:numeric, 20, 2}, false),
          "issued_by_user_id" => column(:bigint, false),
          "issued_by_impersonator_id" => column(:bigint, true),
          "recorded_at" => column({:timestamp, 6}, false)
        }),
      indexes: %{
        "finance_einvoice_documents_pkey" => index(["id"], true),
        "finance_einvoice_documents_id_company_unique" => index(["id", "company_id"], true),
        "finance_einvoice_documents_code_number_unique" =>
          index(["company_id", "environment", "code_number"], true),
        "finance_einvoice_documents_tenant_id_company_id_issued_at_index" =>
          index(["tenant_id", "company_id", "issued_at"])
      },
      foreign_keys: %{
        "finance_einvoice_documents_original_fkey" =>
          company_reference("original_document_id", table)
      },
      checks: %{
        "finance_einvoice_documents_environment" => check(@environments),
        "finance_einvoice_documents_currency_code" =>
          check("(currency_code)::text ~ '^[A-Z]{3}$'::text"),
        "finance_einvoice_documents_exchange_rate" =>
          check("exchange_rate IS NULL OR exchange_rate > (0)::numeric"),
        "finance_einvoice_documents_not_own_original" =>
          check("original_document_id IS NULL OR original_document_id <> id"),
        "finance_einvoice_documents_totals" =>
          check(
            "line_extension_amount >= (0)::numeric AND tax_amount >= (0)::numeric AND " <>
              "tax_exclusive_amount = line_extension_amount AND " <>
              "tax_inclusive_amount = (tax_exclusive_amount + tax_amount) AND " <>
              "payable_amount = tax_inclusive_amount"
          )
      }
    }
  end

  defp lines do
    table = "finance_einvoice_document_lines"

    %{
      name: table,
      columns:
        owned_columns(table)
        |> Map.merge(%{
          "document_id" => column(:bigint, false),
          "line_number" => column(:integer, false),
          "description" => column({:varchar, 300}, false),
          "classification_code" => column({:varchar, 16}, false),
          "tariff_code" => column({:varchar, 32}, true),
          "origin_country_code" => column({:varchar, 3}, true),
          "quantity" => column({:numeric, 20, 6}, false),
          "unit_code" => column({:varchar, 16}, true),
          "unit_price" => column({:numeric, 20, 6}, false),
          "subtotal" => column({:numeric, 20, 2}, false),
          "discount_amount" => column({:numeric, 20, 2}, false, {:integer, 0}),
          "charge_amount" => column({:numeric, 20, 2}, false, {:integer, 0}),
          "line_extension_amount" => column({:numeric, 20, 2}, false),
          "tax_type" => column({:varchar, 8}, false),
          "tax_rate" => column({:numeric, 9, 4}, true),
          "tax_amount" => column({:numeric, 20, 2}, false),
          "tax_exemption_reason" => column({:varchar, 300}, true)
        }),
      indexes: %{
        "finance_einvoice_document_lines_pkey" => index(["id"], true),
        "finance_einvoice_document_lines_document_line_unique" =>
          index(["document_id", "line_number"], true),
        "finance_einvoice_document_lines_company_id_index" => index(["company_id"])
      },
      foreign_keys: %{
        "finance_einvoice_document_lines_document_fkey" =>
          company_reference("document_id", "finance_einvoice_documents")
      },
      checks: %{
        "finance_einvoice_document_lines_line_number" => check("line_number > 0"),
        "finance_einvoice_document_lines_amounts" =>
          check(
            "quantity > (0)::numeric AND unit_price >= (0)::numeric AND " <>
              "subtotal >= (0)::numeric AND discount_amount >= (0)::numeric AND " <>
              "charge_amount >= (0)::numeric AND tax_amount >= (0)::numeric AND " <>
              "line_extension_amount >= (0)::numeric AND " <>
              "line_extension_amount = ((subtotal - discount_amount) + charge_amount)"
          ),
        "finance_einvoice_document_lines_tax_rate" =>
          check("tax_rate IS NULL OR (tax_rate >= (0)::numeric AND tax_rate <= (100)::numeric)")
      }
    }
  end

  defp submissions do
    table = "finance_einvoice_submissions"

    %{
      name: table,
      columns:
        owned_columns(table)
        |> Map.merge(actor_columns())
        |> Map.merge(%{
          "document_id" => column(:bigint, false),
          "environment" => column({:varchar, 16}, false),
          "format" => column({:varchar, 8}, false),
          "document_version" => column({:varchar, 8}, false),
          "payload" => column(:bytea, false),
          "payload_sha256" => column({:varchar, 64}, false),
          "recorded_at" => column({:timestamp, 6}, false)
        }),
      indexes: %{
        "finance_einvoice_submissions_pkey" => index(["id"], true),
        "finance_einvoice_submissions_id_company_unique" => index(["id", "company_id"], true),
        "finance_einvoice_submissions_company_id_document_id_index" =>
          index(["company_id", "document_id"])
      },
      foreign_keys: %{
        "finance_einvoice_submissions_document_fkey" =>
          company_reference("document_id", "finance_einvoice_documents")
      },
      checks: %{
        "finance_einvoice_submissions_environment" => check(@environments),
        "finance_einvoice_submissions_format" =>
          check(
            "(format)::text = ANY ((ARRAY['JSON'::character varying, " <>
              "'XML'::character varying])::text[])"
          ),
        "finance_einvoice_submissions_payload_sha256" =>
          check(
            "octet_length(payload) > 0 AND " <>
              "(payload_sha256)::text = encode(sha256(payload), 'hex'::text)"
          ),
        "finance_einvoice_submissions_actor" => check(@actor)
      }
    }
  end

  defp status_events do
    table = "finance_einvoice_status_events"

    %{
      name: table,
      columns:
        owned_columns(table)
        |> Map.merge(actor_columns())
        |> Map.merge(%{
          "document_id" => column(:bigint, false),
          "sequence" => column(:integer, false),
          "submission_id" => column(:bigint, true),
          "event" => column({:varchar, 32}, false),
          "authority_status" => column({:varchar, 32}, true),
          "submission_uid" => column({:varchar, 64}, true),
          "document_uuid" => column({:varchar, 64}, true),
          "long_id" => column({:varchar, 128}, true),
          "reason" => column({:varchar, 300}, true),
          "http_status" => column(:integer, true),
          "response" => column(:jsonb, true),
          "ledger_entry_id" => column(:bigint, true),
          "recorded_at" => column({:timestamp, 6}, false)
        }),
      indexes: %{
        "finance_einvoice_status_events_pkey" => index(["id"], true),
        "finance_einvoice_status_events_ledger_entry_index" => %{
          columns: ["company_id", "document_id", "event"],
          unique: false,
          where: "(ledger_entry_id IS NOT NULL)"
        },
        "finance_einvoice_status_events_document_sequence_unique" =>
          index(["document_id", "sequence"], true),
        "finance_einvoice_status_events_posted_unique" => %{
          columns: ["document_id"],
          unique: true,
          where: "((event)::text = 'posted'::text)"
        },
        "finance_einvoice_status_events_reversed_unique" => %{
          columns: ["document_id"],
          unique: true,
          where: "((event)::text = 'posting_reversed'::text)"
        },
        "finance_einvoice_status_events_company_id_document_uuid_index" => %{
          columns: ["company_id", "document_uuid"],
          unique: false,
          where: "(document_uuid IS NOT NULL)"
        }
      },
      foreign_keys: %{
        "finance_einvoice_status_events_document_fkey" =>
          company_reference("document_id", "finance_einvoice_documents"),
        "finance_einvoice_status_events_submission_fkey" =>
          company_reference("submission_id", "finance_einvoice_submissions")
      },
      checks: %{
        "finance_einvoice_status_events_event" => check("(event)::text ~ '^[a-z][a-z_]*$'::text"),
        "finance_einvoice_status_events_http_status" =>
          check("http_status IS NULL OR (http_status >= 100 AND http_status <= 599)"),
        "finance_einvoice_status_events_ledger_entry_id" =>
          check("ledger_entry_id IS NULL OR ledger_entry_id > 0"),
        "finance_einvoice_status_events_actor" => check(@actor)
      }
    }
  end

  defp consolidated_sources do
    table = "finance_einvoice_consolidated_sources"

    %{
      name: table,
      columns:
        owned_columns(table)
        |> Map.merge(%{
          "document_id" => column(:bigint, false),
          "source_document_id" => column(:bigint, false),
          "line_number" => column(:integer, false)
        }),
      indexes: %{
        "finance_einvoice_consolidated_sources_pkey" => index(["id"], true),
        "finance_einvoice_consolidated_sources_unique" =>
          index(["document_id", "line_number", "source_document_id"], true),
        "finance_einvoice_consolidated_sources_source_index" =>
          index(["company_id", "source_document_id"])
      },
      foreign_keys: %{
        "finance_einvoice_consolidated_sources_document_fkey" =>
          company_reference("document_id", "finance_einvoice_documents"),
        "finance_einvoice_consolidated_sources_source_fkey" =>
          company_reference("source_document_id", "finance_einvoice_documents"),
        "finance_einvoice_consolidated_sources_line_fkey" => %{
          columns: ["document_id", "line_number"],
          references: {"finance_einvoice_document_lines", ["document_id", "line_number"]},
          on_delete: :restrict
        }
      },
      checks: %{
        "finance_einvoice_consolidated_sources_not_own_source" =>
          check("source_document_id <> document_id")
      }
    }
  end

  defp code_overrides do
    table = "finance_einvoice_code_overrides"

    %{
      name: table,
      columns:
        owned_columns(table)
        |> Map.merge(%{
          "authority" => column({:varchar, 32}, false),
          "list" => column({:varchar, 32}, false),
          "code" => column({:varchar, 16}, false),
          "description" => column({:varchar, 500}, true),
          "active" => column(:boolean, false, {:boolean, true}),
          "inserted_at" => column({:timestamp, 0}, false),
          "updated_at" => column({:timestamp, 0}, false)
        }),
      indexes: %{
        "finance_einvoice_code_overrides_pkey" => index(["id"], true),
        "finance_einvoice_code_overrides_unique" =>
          index(["company_id", "authority", "list", "code"], true),
        "finance_einvoice_code_overrides_tenant_id_company_id_index" =>
          index(["tenant_id", "company_id"])
      },
      foreign_keys: %{},
      checks: %{}
    }
  end

  defp owned_columns(table) do
    %{
      "id" => column(:bigint, false, {:sequence, "#{table}_id_seq"}),
      "tenant_id" => column(:bigint, false),
      "company_id" => column(:bigint, false)
    }
  end

  defp actor_columns do
    %{
      "actor_type" => column({:varchar, 16}, false),
      "actor_user_id" => column(:bigint, true),
      "actor_impersonator_id" => column(:bigint, true),
      "system_principal" => column({:varchar, 100}, true)
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
