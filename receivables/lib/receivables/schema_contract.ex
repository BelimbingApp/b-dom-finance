defmodule Bilimbi.Finance.Receivables.SchemaContract do
  @moduledoc """
  Fresh Bilimbi receivables schema.

  Not registered in the descriptor: compatibility verification runs before
  pending Bilimbi-only migrations, when these tables correctly do not exist.
  `test/schema_contract_test.exs` verifies it against the migration.
  """
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check and predicate text is PostgreSQL's canonical form, which the
  # verifier compares after removing whitespace and parentheses.

  @doc "The migrations that build this contract, in order."
  def migration_versions, do: [20_261_012_214_517, 20_261_015_150_100]

  def migration_version, do: List.last(migration_versions())

  @impl true
  def tables do
    [
      %{
        name: "finance_receivables_setups",
        columns:
          owned_columns("finance_receivables_setups")
          |> Map.merge(%{
            "receivable_account_id" => column(:bigint, false),
            "income_account_id" => column(:bigint, false)
          })
          |> Map.merge(timestamps()),
        indexes: %{
          "finance_receivables_setups_pkey" => index(["id"], true),
          "finance_receivables_setups_company_unique" => index(["company_id"], true),
          "finance_receivables_setups_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{}
      },
      %{
        name: "finance_receivables_setup_changes",
        columns:
          owned_columns("finance_receivables_setup_changes")
          |> Map.merge(%{
            "field" => column({:varchar, 32}, false),
            "old_value" => column(:bigint, true),
            "new_value" => column(:bigint, false),
            "changed_by_user_id" => column(:bigint, false),
            "changed_by_impersonator_id" => column(:bigint, true),
            "changed_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_receivables_setup_changes_pkey" => index(["id"], true),
          "finance_receivables_setup_changes_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_receivables_setup_changes_field" =>
            check(
              "(field)::text = ANY ((ARRAY['receivable_account_id'::character varying, " <>
                "'income_account_id'::character varying])::text[])"
            )
        }
      },
      %{
        name: "finance_receivables_series",
        columns:
          owned_columns("finance_receivables_series")
          |> Map.merge(%{
            "code" => column({:varchar, 50}, false),
            "name" => column({:varchar, 200}, false),
            "kind" => column({:varchar, 16}, false),
            "prefix" => column({:varchar, 20}, false),
            "number_width" => column(:smallint, false),
            "active" => column(:boolean, false, {:boolean, true})
          })
          |> Map.merge(timestamps()),
        indexes: %{
          "finance_receivables_series_pkey" => index(["id"], true),
          "finance_receivables_series_id_company_unique" => index(["id", "company_id"], true),
          "finance_receivables_series_id_company_kind_unique" =>
            index(["id", "company_id", "kind"], true),
          "finance_receivables_series_company_code_unique" => index(["company_id", "code"], true),
          "finance_receivables_series_company_prefix_unique" =>
            index(["company_id", "prefix"], true),
          "finance_receivables_series_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_receivables_series_kind" =>
            check(
              "(kind)::text = ANY ((ARRAY['invoice'::character varying, " <>
                "'credit_note'::character varying, 'payment'::character varying])::text[])"
            ),
          "finance_receivables_series_number_width" =>
            check("number_width >= 1 AND number_width <= 12")
        }
      },
      %{
        name: "finance_receivables_tax_codes",
        columns:
          owned_columns("finance_receivables_tax_codes")
          |> Map.merge(%{
            "code" => column({:varchar, 50}, false),
            "name" => column({:varchar, 200}, false),
            "rate" => column({:numeric, 9, 4}, false),
            "account_id" => column(:bigint, false),
            "active" => column(:boolean, false, {:boolean, true})
          })
          |> Map.merge(timestamps()),
        indexes: %{
          "finance_receivables_tax_codes_pkey" => index(["id"], true),
          "finance_receivables_tax_codes_id_company_unique" => index(["id", "company_id"], true),
          "finance_receivables_tax_codes_company_code_unique" =>
            index(["company_id", "code"], true),
          "finance_receivables_tax_codes_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_receivables_tax_codes_rate" =>
            check("rate >= (0)::numeric AND rate < (1000)::numeric")
        }
      },
      %{
        name: "finance_receivables_customers",
        columns:
          owned_columns("finance_receivables_customers")
          |> Map.merge(%{
            "code" => column({:varchar, 50}, false),
            "payment_terms_days" => column(:integer, false, {:integer, 0}),
            "active" => column(:boolean, false, {:boolean, true})
          })
          |> Map.merge(party_columns(""))
          |> Map.put("name", column({:varchar, 200}, false))
          |> Map.merge(timestamps()),
        indexes: %{
          "finance_receivables_customers_pkey" => index(["id"], true),
          "finance_receivables_customers_id_company_unique" => index(["id", "company_id"], true),
          "finance_receivables_customers_company_code_unique" =>
            index(["company_id", "code"], true),
          "finance_receivables_customers_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_receivables_customers_country_iso" =>
            check("(country_iso)::text ~ '^[A-Z]{2}$'::text"),
          "finance_receivables_customers_payment_terms_days" =>
            check("payment_terms_days >= 0 AND payment_terms_days <= 3650")
        }
      },
      %{
        name: "finance_receivables_documents",
        columns:
          owned_columns("finance_receivables_documents")
          |> Map.merge(%{
            "kind" => column({:varchar, 16}, false),
            "status" => column({:varchar, 16}, false),
            "series_id" => column(:bigint, false),
            "customer_id" => column(:bigint, false),
            "credited_document_id" => column(:bigint, true),
            "receivable_account_id" => column(:bigint, true),
            "currency_code" => column({:varchar, 3}, false),
            "issue_date" => column(:date, true),
            "due_date" => column(:date, true),
            "description" => column({:varchar, 500}, true),
            "subtotal" => column({:numeric, 20, 4}, false),
            "tax_total" => column({:numeric, 20, 4}, false),
            "total" => column({:numeric, 20, 4}, false),
            "document_number" => column(:bigint, true),
            "document_reference" => column({:varchar, 50}, true),
            "ledger_entry_id" => column(:bigint, true),
            "ledger_entry_number" => column(:bigint, true),
            "issued_by_user_id" => column(:bigint, true),
            "issued_by_impersonator_id" => column(:bigint, true),
            "issued_at" => column({:timestamp, 6}, true),
            "discarded_by_user_id" => column(:bigint, true),
            "discarded_at" => column({:timestamp, 6}, true)
          })
          |> Map.merge(party_columns("party_"))
          |> Map.merge(timestamps()),
        indexes: %{
          "finance_receivables_documents_pkey" => index(["id"], true),
          "finance_receivables_documents_id_company_unique" => index(["id", "company_id"], true),
          "finance_receivables_documents_series_number_unique" => %{
            columns: ["series_id", "document_number"],
            unique: true,
            where: "(document_number IS NOT NULL)"
          },
          "finance_receivables_documents_company_reference_unique" => %{
            columns: ["company_id", "document_reference"],
            unique: true,
            where: "(document_reference IS NOT NULL)"
          },
          "finance_receivables_documents_company_entry_number_index" => %{
            columns: ["company_id", "ledger_entry_number"],
            unique: false,
            where: "(ledger_entry_number IS NOT NULL)"
          },
          "finance_receivables_documents_customer_index" =>
            index(["tenant_id", "company_id", "customer_id"]),
          "finance_receivables_documents_credited_document_id_index" =>
            index(["credited_document_id"])
        },
        foreign_keys: %{
          "finance_receivables_documents_series_fkey" => %{
            columns: ["series_id", "company_id", "kind"],
            references: {"finance_receivables_series", ["id", "company_id", "kind"]},
            on_delete: :restrict
          },
          "finance_receivables_documents_customer_fkey" =>
            company_reference("customer_id", "finance_receivables_customers"),
          "finance_receivables_documents_credited_fkey" =>
            company_reference("credited_document_id", "finance_receivables_documents")
        },
        checks: %{
          "finance_receivables_documents_kind" =>
            check(
              "(kind)::text = ANY ((ARRAY['invoice'::character varying, " <>
                "'credit_note'::character varying])::text[])"
            ),
          "finance_receivables_documents_status" =>
            check(
              "(status)::text = ANY ((ARRAY['draft'::character varying, " <>
                "'issued'::character varying, 'discarded'::character varying])::text[])"
            ),
          "finance_receivables_documents_credited" =>
            check("((kind)::text = 'credit_note'::text) = (credited_document_id IS NOT NULL)"),
          "finance_receivables_documents_amounts" =>
            check(
              "subtotal >= (0)::numeric AND tax_total >= (0)::numeric AND " <>
                "total = (subtotal + tax_total)"
            ),
          "finance_receivables_documents_due_date" =>
            check("due_date IS NULL OR due_date >= issue_date"),
          "finance_receivables_documents_issued" =>
            check(
              "((status)::text = 'issued'::text) = (document_number IS NOT NULL) AND " <>
                "((status)::text <> 'issued'::text OR (document_number > 0 AND " <>
                "document_reference IS NOT NULL AND issue_date IS NOT NULL AND " <>
                "((kind)::text <> 'invoice'::text OR due_date IS NOT NULL) AND " <>
                "total > (0)::numeric AND party_name IS NOT NULL AND " <>
                "receivable_account_id IS NOT NULL AND " <>
                "ledger_entry_id IS NOT NULL AND ledger_entry_number IS NOT NULL AND " <>
                "issued_by_user_id IS NOT NULL AND issued_at IS NOT NULL))"
            ),
          "finance_receivables_documents_discarded" =>
            check(
              "((status)::text = 'discarded'::text) = (discarded_at IS NOT NULL) AND " <>
                "((status)::text <> 'discarded'::text OR discarded_by_user_id IS NOT NULL)"
            )
        }
      },
      %{
        name: "finance_receivables_document_lines",
        columns:
          owned_columns("finance_receivables_document_lines")
          |> Map.merge(%{
            "document_id" => column(:bigint, false),
            "line_number" => column(:integer, false),
            "description" => column({:varchar, 500}, false),
            "quantity" => column({:numeric, 20, 4}, false),
            "unit_price" => column({:numeric, 20, 4}, false),
            "amount" => column({:numeric, 20, 4}, false),
            "account_id" => column(:bigint, false),
            "tax_code_id" => column(:bigint, true),
            "tax_rate" => column({:numeric, 9, 4}, true),
            "tax_amount" => column({:numeric, 20, 4}, false)
          }),
        indexes: %{
          "finance_receivables_document_lines_pkey" => index(["id"], true),
          "finance_receivables_document_lines_document_line_unique" =>
            index(["document_id", "line_number"], true)
        },
        foreign_keys: %{
          "finance_receivables_document_lines_document_fkey" =>
            company_reference("document_id", "finance_receivables_documents"),
          "finance_receivables_document_lines_tax_code_fkey" =>
            company_reference("tax_code_id", "finance_receivables_tax_codes")
        },
        checks: %{
          "finance_receivables_document_lines_line_number" => check("line_number > 0"),
          "finance_receivables_document_lines_amounts" =>
            check(
              "quantity > (0)::numeric AND unit_price >= (0)::numeric AND " <>
                "amount >= (0)::numeric AND tax_amount >= (0)::numeric"
            ),
          "finance_receivables_document_lines_tax" =>
            check(
              "(tax_code_id IS NULL) = (tax_rate IS NULL) AND " <>
                "(tax_code_id IS NOT NULL OR tax_amount = (0)::numeric)"
            )
        }
      },
      %{
        name: "finance_receivables_document_tax_lines",
        columns:
          owned_columns("finance_receivables_document_tax_lines")
          |> Map.merge(%{
            "document_id" => column(:bigint, false),
            "tax_code_id" => column(:bigint, false),
            "tax_code" => column({:varchar, 50}, false),
            "tax_rate" => column({:numeric, 9, 4}, false),
            "taxable_amount" => column({:numeric, 20, 4}, false),
            "tax_amount" => column({:numeric, 20, 4}, false),
            "account_id" => column(:bigint, false)
          }),
        indexes: %{
          "finance_receivables_document_tax_lines_pkey" => index(["id"], true),
          "finance_receivables_document_tax_lines_document_tax_code_unique" =>
            index(["document_id", "tax_code_id"], true)
        },
        foreign_keys: %{
          "finance_receivables_document_tax_lines_document_fkey" =>
            company_reference("document_id", "finance_receivables_documents"),
          "finance_receivables_document_tax_lines_tax_code_fkey" =>
            company_reference("tax_code_id", "finance_receivables_tax_codes")
        },
        checks: %{
          "finance_receivables_document_tax_lines_amounts" =>
            check("taxable_amount >= (0)::numeric AND tax_amount >= (0)::numeric")
        }
      },
      %{
        name: "finance_receivables_payments",
        columns:
          owned_columns("finance_receivables_payments")
          |> Map.merge(%{
            "series_id" => column(:bigint, false),
            "customer_id" => column(:bigint, false),
            "payment_number" => column(:bigint, false),
            "payment_reference" => column({:varchar, 50}, false),
            "payment_date" => column(:date, false),
            "amount" => column({:numeric, 20, 4}, false),
            "currency_code" => column({:varchar, 3}, false),
            "deposit_account_id" => column(:bigint, false),
            "reference" => column({:varchar, 100}, true),
            "description" => column({:varchar, 500}, true),
            "ledger_entry_id" => column(:bigint, false),
            "ledger_entry_number" => column(:bigint, false),
            "recorded_by_user_id" => column(:bigint, false),
            "recorded_by_impersonator_id" => column(:bigint, true),
            "recorded_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_receivables_payments_pkey" => index(["id"], true),
          "finance_receivables_payments_id_company_unique" => index(["id", "company_id"], true),
          "finance_receivables_payments_series_number_unique" =>
            index(["series_id", "payment_number"], true),
          "finance_receivables_payments_company_reference_unique" =>
            index(["company_id", "payment_reference"], true),
          "finance_receivables_payments_customer_index" =>
            index(["tenant_id", "company_id", "customer_id"])
        },
        foreign_keys: %{
          "finance_receivables_payments_series_fkey" =>
            company_reference("series_id", "finance_receivables_series"),
          "finance_receivables_payments_customer_fkey" =>
            company_reference("customer_id", "finance_receivables_customers")
        },
        checks: %{
          "finance_receivables_payments_amount" =>
            check("amount > (0)::numeric AND payment_number > 0")
        }
      },
      %{
        name: "finance_receivables_allocations",
        columns:
          owned_columns("finance_receivables_allocations")
          |> Map.merge(%{
            "payment_id" => column(:bigint, false),
            "document_id" => column(:bigint, false),
            "amount" => column({:numeric, 20, 4}, false)
          }),
        indexes: %{
          "finance_receivables_allocations_pkey" => index(["id"], true),
          "finance_receivables_allocations_payment_document_unique" =>
            index(["payment_id", "document_id"], true),
          "finance_receivables_allocations_document_id_index" => index(["document_id"])
        },
        foreign_keys: %{
          "finance_receivables_allocations_payment_fkey" =>
            company_reference("payment_id", "finance_receivables_payments"),
          "finance_receivables_allocations_document_fkey" =>
            company_reference("document_id", "finance_receivables_documents")
        },
        checks: %{
          "finance_receivables_allocations_amount" => check("amount > (0)::numeric")
        }
      },
      %{
        name: "finance_receivables_payment_reversals",
        columns:
          owned_columns("finance_receivables_payment_reversals")
          |> Map.merge(%{
            "payment_id" => column(:bigint, false),
            "reversal_date" => column(:date, false),
            "reason" => column({:varchar, 500}, false),
            "ledger_entry_id" => column(:bigint, false),
            "ledger_entry_number" => column(:bigint, false),
            "reversed_by_user_id" => column(:bigint, false),
            "reversed_by_impersonator_id" => column(:bigint, true),
            "reversed_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_receivables_payment_reversals_pkey" => index(["id"], true),
          "finance_receivables_payment_reversals_payment_unique" => index(["payment_id"], true),
          "finance_receivables_payment_reversals_company_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{
          "finance_receivables_payment_reversals_payment_fkey" =>
            company_reference("payment_id", "finance_receivables_payments")
        },
        checks: %{}
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

  # A customer's party fields, and an issued document's snapshot of them.
  defp party_columns(prefix) do
    Map.new(
      [
        {"name", 200},
        {"tax_identifier", 50},
        {"registration_identifier", 50},
        {"email", 255},
        {"phone", 50},
        {"line1", 255},
        {"line2", 255},
        {"line3", 255},
        {"locality", 100},
        {"postcode", 20},
        {"admin1_code", 20},
        {"country_iso", 2}
      ],
      fn {name, size} -> {prefix <> name, column({:varchar, size}, true)} end
    )
  end

  defp timestamps do
    %{
      "inserted_at" => column({:timestamp, 0}, false),
      "updated_at" => column({:timestamp, 0}, false)
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
