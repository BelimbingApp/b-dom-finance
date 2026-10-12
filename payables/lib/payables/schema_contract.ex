defmodule Bilimbi.Finance.Payables.SchemaContract do
  @moduledoc """
  Fresh Bilimbi payables schema.

  Not registered in the descriptor: compatibility verification runs before
  pending Bilimbi-only migrations, when these tables correctly do not exist.
  `test/schema_contract_test.exs` verifies it against the migration.
  """
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check and predicate text is PostgreSQL's canonical form, which the
  # verifier compares after removing whitespace and parentheses.

  def migration_version, do: 20_261_012_213_700

  @impl true
  def tables do
    [
      %{
        name: "finance_payables_settings",
        columns:
          owned_columns("finance_payables_settings")
          |> Map.merge(%{
            "payable_account_id" => column(:bigint, false),
            "inserted_at" => column({:timestamp, 0}, false),
            "updated_at" => column({:timestamp, 0}, false)
          }),
        indexes: %{
          "finance_payables_settings_pkey" => index(["id"], true),
          "finance_payables_settings_company_unique" => index(["company_id"], true),
          "finance_payables_settings_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{}
      },
      %{
        name: "finance_payables_tax_codes",
        columns:
          owned_columns("finance_payables_tax_codes")
          |> Map.merge(%{
            "code" => column({:varchar, 50}, false),
            "name" => column({:varchar, 200}, false),
            "rate" => column({:numeric, 7, 4}, false),
            "account_id" => column(:bigint, false),
            "active" => column(:boolean, false, {:boolean, true}),
            "inserted_at" => column({:timestamp, 0}, false),
            "updated_at" => column({:timestamp, 0}, false)
          }),
        indexes: %{
          "finance_payables_tax_codes_pkey" => index(["id"], true),
          "finance_payables_tax_codes_id_company_unique" => index(["id", "company_id"], true),
          "finance_payables_tax_codes_company_code_unique" => index(["company_id", "code"], true),
          "finance_payables_tax_codes_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{"finance_payables_tax_codes_rate" => check("rate >= (0)::numeric")}
      },
      %{
        name: "finance_payables_documents",
        columns:
          owned_columns("finance_payables_documents")
          |> Map.merge(%{
            "document_type" => column({:varchar, 16}, false),
            "status" => column({:varchar, 16}, false),
            "document_number" => column(:bigint, true),
            "corrects_document_id" => column(:bigint, true),
            "party_key" => column({:varchar, 100}, false),
            "party_name" => column({:varchar, 200}, false),
            "party_tax_id" => column({:varchar, 50}, true),
            "party_registration_id" => column({:varchar, 50}, true),
            "party_address" => column({:varchar, 1000}, true),
            "party_document_number" => column({:varchar, 100}, true),
            "document_date" => column(:date, false),
            "due_date" => column(:date, false),
            "currency_code" => column({:varchar, 3}, false),
            "description" => column({:varchar, 500}, true),
            "total_net" => column({:numeric, 20, 4}, false),
            "total_tax" => column({:numeric, 20, 4}, false),
            "total" => column({:numeric, 20, 4}, false),
            "created_by_user_id" => column(:bigint, false),
            "created_by_impersonator_id" => column(:bigint, true),
            "created_at" => column({:timestamp, 6}, false),
            "approved_by_user_id" => column(:bigint, true),
            "approved_by_impersonator_id" => column(:bigint, true),
            "approved_at" => column({:timestamp, 6}, true),
            "posted_by_user_id" => column(:bigint, true),
            "posted_by_impersonator_id" => column(:bigint, true),
            "posted_at" => column({:timestamp, 6}, true),
            "payable_account_id" => column(:bigint, true),
            "entry_id" => column(:bigint, true),
            "entry_number" => column(:bigint, true),
            "voided_by_user_id" => column(:bigint, true),
            "voided_by_impersonator_id" => column(:bigint, true),
            "voided_at" => column({:timestamp, 6}, true),
            "void_reason" => column({:varchar, 500}, true)
          }),
        indexes: %{
          "finance_payables_documents_pkey" => index(["id"], true),
          "finance_payables_documents_id_company_unique" => index(["id", "company_id"], true),
          "finance_payables_documents_company_number_unique" => %{
            columns: ["company_id", "document_type", "document_number"],
            unique: true,
            where: "(document_number IS NOT NULL)"
          },
          "finance_payables_documents_party_document_unique" => %{
            columns: ["company_id", "party_key", "party_document_number"],
            unique: true,
            where:
              "(((document_type)::text = 'bill'::text) AND ((status)::text <> 'voided'::text))"
          },
          "finance_payables_documents_company_date_index" =>
            index(["tenant_id", "company_id", "document_date"]),
          "finance_payables_documents_corrects_document_id_index" => %{
            columns: ["corrects_document_id"],
            unique: false,
            where: "(corrects_document_id IS NOT NULL)"
          }
        },
        foreign_keys: %{
          "finance_payables_documents_corrects_document_fkey" =>
            company_reference("corrects_document_id", "finance_payables_documents")
        },
        checks: %{
          "finance_payables_documents_document_type" =>
            check(
              "(document_type)::text = ANY ((ARRAY['bill'::character varying, " <>
                "'debit_note'::character varying])::text[])"
            ),
          "finance_payables_documents_status" =>
            check(
              "(status)::text = ANY ((ARRAY['draft'::character varying, " <>
                "'approved'::character varying, 'posted'::character varying, " <>
                "'voided'::character varying])::text[])"
            ),
          "finance_payables_documents_currency_code" =>
            check("(currency_code)::text ~ '^[A-Z]{3}$'::text"),
          "finance_payables_documents_correction" =>
            check(
              "((document_type)::text = 'debit_note'::text) = (corrects_document_id IS NOT NULL)"
            ),
          "finance_payables_documents_party_document_number" =>
            check(
              "((document_type)::text <> 'bill'::text) OR (party_document_number IS NOT NULL)"
            ),
          "finance_payables_documents_due_date" => check("due_date >= document_date"),
          "finance_payables_documents_totals" =>
            check(
              "(total_net > (0)::numeric) AND (total_tax >= (0)::numeric) AND " <>
                "(total = (total_net + total_tax))"
            ),
          "finance_payables_documents_approval" =>
            check(
              "((approved_at IS NULL) = (approved_by_user_id IS NULL)) AND " <>
                "(((status)::text <> ALL ((ARRAY['approved'::character varying, " <>
                "'posted'::character varying])::text[])) OR (approved_at IS NOT NULL)) AND " <>
                "(((status)::text <> 'draft'::text) OR (approved_at IS NULL))"
            ),
          "finance_payables_documents_posting" =>
            check(
              Enum.map_join(
                ~w(posted_at document_number posted_by_user_id payable_account_id entry_id
                   entry_number),
                " AND ",
                &"(((status)::text = 'posted'::text) = (#{&1} IS NOT NULL))"
              )
            ),
          "finance_payables_documents_void" =>
            check(
              Enum.map_join(
                ~w(voided_at voided_by_user_id void_reason),
                " AND ",
                &"(((status)::text = 'voided'::text) = (#{&1} IS NOT NULL))"
              )
            ),
          "finance_payables_documents_document_number" => check("document_number > 0")
        }
      },
      %{
        name: "finance_payables_document_lines",
        columns:
          owned_columns("finance_payables_document_lines")
          |> Map.merge(%{
            "document_id" => column(:bigint, false),
            "line_number" => column(:integer, false),
            "description" => column({:varchar, 500}, false),
            "account_id" => column(:bigint, false),
            "amount" => column({:numeric, 20, 4}, false),
            "tax_code_id" => column(:bigint, true),
            "external_order_line_id" => column({:varchar, 100}, true)
          }),
        indexes: %{
          "finance_payables_document_lines_pkey" => index(["id"], true),
          "finance_payables_document_lines_document_line_unique" =>
            index(["document_id", "line_number"], true)
        },
        foreign_keys: %{
          "finance_payables_document_lines_document_fkey" =>
            company_reference("document_id", "finance_payables_documents"),
          "finance_payables_document_lines_tax_code_fkey" =>
            company_reference("tax_code_id", "finance_payables_tax_codes")
        },
        checks: %{
          "finance_payables_document_lines_line_number" => check("line_number > 0"),
          "finance_payables_document_lines_amount" => check("amount > (0)::numeric")
        }
      },
      %{
        name: "finance_payables_document_tax_lines",
        columns:
          owned_columns("finance_payables_document_tax_lines")
          |> Map.merge(%{
            "document_id" => column(:bigint, false),
            "line_number" => column(:integer, false),
            "tax_code_id" => column(:bigint, false),
            "tax_code" => column({:varchar, 50}, false),
            "rate" => column({:numeric, 7, 4}, false),
            "account_id" => column(:bigint, false),
            "taxable_amount" => column({:numeric, 20, 4}, false),
            "tax_amount" => column({:numeric, 20, 4}, false)
          }),
        indexes: %{
          "finance_payables_document_tax_lines_pkey" => index(["id"], true),
          "finance_payables_document_tax_lines_document_line_unique" =>
            index(["document_id", "line_number"], true),
          "finance_payables_document_tax_lines_document_tax_code_unique" =>
            index(["document_id", "tax_code_id"], true)
        },
        foreign_keys: %{
          "finance_payables_document_tax_lines_document_fkey" =>
            company_reference("document_id", "finance_payables_documents"),
          "finance_payables_document_tax_lines_tax_code_fkey" =>
            company_reference("tax_code_id", "finance_payables_tax_codes")
        },
        checks: %{
          "finance_payables_document_tax_lines_line_number" => check("line_number > 0"),
          "finance_payables_document_tax_lines_amounts" =>
            check(
              "(rate >= (0)::numeric) AND (taxable_amount > (0)::numeric) AND " <>
                "(tax_amount >= (0)::numeric)"
            )
        }
      },
      %{
        name: "finance_payables_payments",
        columns:
          owned_columns("finance_payables_payments")
          |> Map.merge(%{
            "payment_number" => column(:bigint, false),
            "payment_date" => column(:date, false),
            "party_key" => column({:varchar, 100}, false),
            "party_name" => column({:varchar, 200}, false),
            "paid_from_account_id" => column(:bigint, false),
            "amount" => column({:numeric, 20, 4}, false),
            "currency_code" => column({:varchar, 3}, false),
            "reference" => column({:varchar, 100}, true),
            "description" => column({:varchar, 500}, true),
            "reverses_payment_id" => column(:bigint, true),
            "entry_id" => column(:bigint, false),
            "entry_number" => column(:bigint, false),
            "posted_by_user_id" => column(:bigint, false),
            "posted_by_impersonator_id" => column(:bigint, true),
            "posted_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_payables_payments_pkey" => index(["id"], true),
          "finance_payables_payments_id_company_unique" => index(["id", "company_id"], true),
          "finance_payables_payments_company_number_unique" =>
            index(["company_id", "payment_number"], true),
          "finance_payables_payments_reversed_once" => %{
            columns: ["reverses_payment_id"],
            unique: true,
            where: "(reverses_payment_id IS NOT NULL)"
          },
          "finance_payables_payments_company_date_index" =>
            index(["tenant_id", "company_id", "payment_date"])
        },
        foreign_keys: %{
          "finance_payables_payments_reverses_payment_fkey" =>
            company_reference("reverses_payment_id", "finance_payables_payments")
        },
        checks: %{
          "finance_payables_payments_amount" => check("amount > (0)::numeric"),
          "finance_payables_payments_currency_code" =>
            check("(currency_code)::text ~ '^[A-Z]{3}$'::text"),
          "finance_payables_payments_payment_number" => check("payment_number > 0"),
          "finance_payables_payments_not_own_reversal" =>
            check("reverses_payment_id IS NULL OR reverses_payment_id <> id")
        }
      },
      %{
        name: "finance_payables_payment_allocations",
        columns:
          owned_columns("finance_payables_payment_allocations")
          |> Map.merge(%{
            "payment_id" => column(:bigint, false),
            "line_number" => column(:integer, false),
            "document_id" => column(:bigint, false),
            "amount" => column({:numeric, 20, 4}, false)
          }),
        indexes: %{
          "finance_payables_payment_allocations_pkey" => index(["id"], true),
          "finance_payables_payment_allocations_payment_line_unique" =>
            index(["payment_id", "line_number"], true),
          "finance_payables_payment_allocations_payment_document_unique" =>
            index(["payment_id", "document_id"], true),
          "finance_payables_payment_allocations_document_index" =>
            index(["company_id", "document_id"])
        },
        foreign_keys: %{
          "finance_payables_payment_allocations_payment_fkey" =>
            company_reference("payment_id", "finance_payables_payments"),
          "finance_payables_payment_allocations_document_fkey" =>
            company_reference("document_id", "finance_payables_documents")
        },
        checks: %{
          "finance_payables_payment_allocations_line_number" => check("line_number > 0"),
          "finance_payables_payment_allocations_amount" => check("amount > (0)::numeric")
        }
      }
    ]
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
