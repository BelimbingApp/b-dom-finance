defmodule Bilimbi.Finance.Sst.SchemaContract do
  @moduledoc """
  Fresh Bilimbi SST return schema.

  Not registered in the descriptor: compatibility verification runs before
  pending Bilimbi-only migrations, when these tables correctly do not exist.
  `test/schema_contract_test.exs` verifies it against the migration.
  """
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check text is PostgreSQL's canonical form, which the verifier compares
  # after removing whitespace and parentheses.

  def migration_version, do: 20_261_015_090_000

  @impl true
  def tables do
    [
      %{
        name: "finance_sst_registrations",
        columns:
          owned_columns("finance_sst_registrations")
          |> Map.merge(%{
            "version" => column(:bigint, false),
            "sales_tax_number" => column({:varchar, 30}, true),
            "service_tax_number" => column({:varchar, 30}, true),
            "period_months" => column(:smallint, false),
            "period_start" => column(:date, false),
            "service_tax_basis" => column({:varchar, 16}, false),
            "reason" => column({:varchar, 500}, true),
            "recorded_by_user_id" => column(:bigint, false),
            "recorded_by_impersonator_id" => column(:bigint, true),
            "recorded_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_sst_registrations_company_version_unique" =>
            index(["company_id", "version"], true),
          "finance_sst_registrations_id_company_unique" => index(["id", "company_id"], true),
          "finance_sst_registrations_pkey" => index(["id"], true),
          "finance_sst_registrations_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_sst_registrations_number" =>
            check("(((sales_tax_number IS NOT NULL) OR (service_tax_number IS NOT NULL)))"),
          "finance_sst_registrations_period_months" =>
            check("(((period_months >= 1) AND (period_months <= 12)))"),
          "finance_sst_registrations_service_tax_basis" =>
            check(
              "(((service_tax_basis)::text = ANY ((ARRAY['payment'::character varying, 'invoice'::character varying])::text[])))"
            ),
          "finance_sst_registrations_version" => check("((version > 0))")
        }
      },
      %{
        name: "finance_sst_mappings",
        columns:
          owned_columns("finance_sst_mappings")
          |> Map.merge(%{
            "mapping_number" => column(:bigint, false),
            "source" => column({:varchar, 16}, false),
            "tax_code_id" => column(:bigint, false),
            "tax_code" => column({:varchar, 50}, false),
            "box" => column({:varchar, 32}, true),
            "reason" => column({:varchar, 500}, true),
            "recorded_by_user_id" => column(:bigint, false),
            "recorded_by_impersonator_id" => column(:bigint, true),
            "recorded_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_sst_mappings_company_number_unique" =>
            index(["company_id", "mapping_number"], true),
          "finance_sst_mappings_pkey" => index(["id"], true),
          "finance_sst_mappings_tax_code_index" =>
            index(["company_id", "source", "tax_code_id", "mapping_number"]),
          "finance_sst_mappings_tenant_id_company_id_index" => index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_sst_mappings_box" => check("(((box)::text ~ '^[a-z0-9_]+$'::text))"),
          "finance_sst_mappings_mapping_number" => check("((mapping_number > 0))"),
          "finance_sst_mappings_source" =>
            check(
              "(((source)::text = ANY ((ARRAY['receivables'::character varying, 'payables'::character varying])::text[])))"
            )
        }
      },
      %{
        name: "finance_sst_returns",
        columns:
          owned_columns("finance_sst_returns")
          |> Map.merge(%{
            "return_number" => column(:bigint, false),
            "tax_type" => column({:varchar, 16}, false),
            "registration_id" => column(:bigint, false),
            "period_start" => column(:date, false),
            "period_end" => column(:date, false),
            "due_date" => column(:date, false),
            "amends_return_id" => column(:bigint, true),
            "reason" => column({:varchar, 500}, true),
            "opened_by_user_id" => column(:bigint, false),
            "opened_by_impersonator_id" => column(:bigint, true),
            "opened_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_sst_returns_company_number_unique" =>
            index(["company_id", "return_number"], true),
          "finance_sst_returns_id_company_unique" => index(["id", "company_id"], true),
          "finance_sst_returns_period_index" => index(["company_id", "tax_type", "period_start"]),
          "finance_sst_returns_pkey" => index(["id"], true),
          "finance_sst_returns_tenant_id_company_id_index" => index(["tenant_id", "company_id"])
        },
        foreign_keys: %{
          "finance_sst_returns_amends_fkey" =>
            company_reference("amends_return_id", "finance_sst_returns"),
          "finance_sst_returns_registration_fkey" =>
            company_reference("registration_id", "finance_sst_registrations")
        },
        checks: %{
          "finance_sst_returns_amendment_reason" =>
            check(
              "(((amends_return_id IS NULL) OR ((reason IS NOT NULL) AND (btrim((reason)::text) <> ''::text))))"
            ),
          "finance_sst_returns_due_date" => check("((due_date > period_end))"),
          "finance_sst_returns_period" => check("((period_end >= period_start))"),
          "finance_sst_returns_return_number" => check("((return_number > 0))"),
          "finance_sst_returns_tax_type" =>
            check(
              "(((tax_type)::text = ANY ((ARRAY['sales_tax'::character varying, 'service_tax'::character varying])::text[])))"
            )
        }
      },
      %{
        name: "finance_sst_return_events",
        columns:
          owned_columns("finance_sst_return_events")
          |> Map.merge(%{
            "event_number" => column(:bigint, false),
            "return_id" => column(:bigint, false),
            "action" => column({:varchar, 16}, false),
            "reason" => column({:varchar, 500}, true),
            "version" => column(:integer, true),
            "through_entry_number" => column(:bigint, true),
            "through_mapping_number" => column(:bigint, true),
            "through_adjustment_number" => column(:bigint, true),
            "currency_code" => column({:varchar, 3}, true),
            "minor_units" => column(:smallint, true),
            "tax_payable" => column({:numeric, 20, 4}, true),
            "recorded_by_user_id" => column(:bigint, false),
            "recorded_by_impersonator_id" => column(:bigint, true),
            "recorded_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_sst_return_events_company_number_unique" =>
            index(["company_id", "event_number"], true),
          "finance_sst_return_events_pkey" => index(["id"], true),
          "finance_sst_return_events_return_action_unique" => index(["return_id", "action"], true)
        },
        foreign_keys: %{
          "finance_sst_return_events_return_fkey" =>
            company_reference("return_id", "finance_sst_returns")
        },
        checks: %{
          "finance_sst_return_events_action" =>
            check(
              "(((action)::text = ANY ((ARRAY['opened'::character varying, 'finalised'::character varying, 'discarded'::character varying])::text[])))"
            ),
          "finance_sst_return_events_discard_reason" =>
            check(
              "((((action)::text <> 'discarded'::text) OR ((reason IS NOT NULL) AND (btrim((reason)::text) <> ''::text))))"
            ),
          "finance_sst_return_events_event_number" => check("((event_number > 0))"),
          "finance_sst_return_events_figures" =>
            check(
              "(((((action)::text = 'finalised'::text) = (version IS NOT NULL)) AND (((action)::text = 'finalised'::text) = (through_entry_number IS NOT NULL)) AND (((action)::text = 'finalised'::text) = (through_mapping_number IS NOT NULL)) AND (((action)::text = 'finalised'::text) = (through_adjustment_number IS NOT NULL)) AND (((action)::text = 'finalised'::text) = (currency_code IS NOT NULL)) AND (((action)::text = 'finalised'::text) = (minor_units IS NOT NULL)) AND (((action)::text = 'finalised'::text) = (tax_payable IS NOT NULL))))"
            )
        }
      },
      %{
        name: "finance_sst_return_adjustments",
        columns:
          owned_columns("finance_sst_return_adjustments")
          |> Map.merge(%{
            "adjustment_number" => column(:bigint, false),
            "return_id" => column(:bigint, false),
            "action" => column({:varchar, 16}, false),
            "withdraws_adjustment_id" => column(:bigint, true),
            "copied_from_adjustment_id" => column(:bigint, true),
            "box" => column({:varchar, 32}, true),
            "taxable_amount" => column({:numeric, 20, 4}, true),
            "tax_amount" => column({:numeric, 20, 4}, true),
            "description" => column({:varchar, 500}, false),
            "reference" => column({:varchar, 100}, true),
            "recorded_by_user_id" => column(:bigint, false),
            "recorded_by_impersonator_id" => column(:bigint, true),
            "recorded_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_sst_return_adjustments_company_number_unique" =>
            index(["company_id", "adjustment_number"], true),
          "finance_sst_return_adjustments_id_company_unique" => index(["id", "company_id"], true),
          "finance_sst_return_adjustments_pkey" => index(["id"], true),
          "finance_sst_return_adjustments_return_index" => index(["company_id", "return_id"]),
          "finance_sst_return_adjustments_withdraws_unique" =>
            index(["withdraws_adjustment_id"], true)
        },
        foreign_keys: %{
          "finance_sst_return_adjustments_copied_fkey" =>
            company_reference("copied_from_adjustment_id", "finance_sst_return_adjustments"),
          "finance_sst_return_adjustments_return_fkey" =>
            company_reference("return_id", "finance_sst_returns"),
          "finance_sst_return_adjustments_withdraws_fkey" =>
            company_reference("withdraws_adjustment_id", "finance_sst_return_adjustments")
        },
        checks: %{
          "finance_sst_return_adjustments_action" =>
            check(
              "(((action)::text = ANY ((ARRAY['added'::character varying, 'withdrawn'::character varying])::text[])))"
            ),
          "finance_sst_return_adjustments_adjustment_number" =>
            check("((adjustment_number > 0))"),
          "finance_sst_return_adjustments_amounts" =>
            check(
              "(((taxable_amount IS NULL) OR ((taxable_amount >= (0)::numeric) AND (tax_amount >= (0)::numeric) AND ((taxable_amount > (0)::numeric) OR (tax_amount > (0)::numeric)))))"
            ),
          "finance_sst_return_adjustments_box" => check("(((box)::text ~ '^[a-z0-9_]+$'::text))"),
          "finance_sst_return_adjustments_description" =>
            check("((btrim((description)::text) <> ''::text))"),
          "finance_sst_return_adjustments_shape" =>
            check(
              "(((((action)::text = 'added'::text) = (box IS NOT NULL)) AND (((action)::text = 'added'::text) = (taxable_amount IS NOT NULL)) AND (((action)::text = 'added'::text) = (tax_amount IS NOT NULL)) AND (((action)::text = 'withdrawn'::text) = (withdraws_adjustment_id IS NOT NULL)) AND (((action)::text = 'added'::text) OR (copied_from_adjustment_id IS NULL))))"
            )
        }
      },
      %{
        name: "finance_sst_return_boxes",
        columns:
          owned_columns("finance_sst_return_boxes")
          |> Map.merge(%{
            "return_id" => column(:bigint, false),
            "line_number" => column(:integer, false),
            "box" => column({:varchar, 32}, false),
            "taxable_amount" => column({:numeric, 20, 4}, true),
            "tax_amount" => column({:numeric, 20, 4}, true)
          }),
        indexes: %{
          "finance_sst_return_boxes_pkey" => index(["id"], true),
          "finance_sst_return_boxes_return_box_unique" => index(["return_id", "box"], true),
          "finance_sst_return_boxes_return_line_unique" =>
            index(["return_id", "line_number"], true)
        },
        foreign_keys: %{
          "finance_sst_return_boxes_return_fkey" =>
            company_reference("return_id", "finance_sst_returns")
        },
        checks: %{
          "finance_sst_return_boxes_box" => check("(((box)::text ~ '^[a-z0-9_]+$'::text))"),
          "finance_sst_return_boxes_line_number" => check("((line_number > 0))")
        }
      },
      %{
        name: "finance_sst_return_sources",
        columns:
          owned_columns("finance_sst_return_sources")
          |> Map.merge(%{
            "return_id" => column(:bigint, false),
            "line_number" => column(:integer, false),
            "source" => column({:varchar, 16}, false),
            "document_kind" => column({:varchar, 32}, false),
            "measure" => column({:varchar, 32}, false),
            "prior_period" => column(:boolean, false),
            "tax_code_id" => column(:bigint, false),
            "tax_code" => column({:varchar, 50}, false),
            "rate" => column({:numeric, 9, 4}, false),
            "account_id" => column(:bigint, false),
            "box" => column({:varchar, 32}, true),
            "mapping_number" => column(:bigint, false),
            "document_count" => column(:integer, false),
            "taxable_amount" => column({:numeric, 20, 4}, false),
            "tax_amount" => column({:numeric, 20, 4}, false)
          }),
        indexes: %{
          "finance_sst_return_sources_pkey" => index(["id"], true),
          "finance_sst_return_sources_return_line_unique" =>
            index(["return_id", "line_number"], true)
        },
        foreign_keys: %{
          "finance_sst_return_sources_return_fkey" =>
            company_reference("return_id", "finance_sst_returns")
        },
        checks: %{
          "finance_sst_return_sources_box" => check("(((box)::text ~ '^[a-z0-9_]+$'::text))"),
          "finance_sst_return_sources_document_count" => check("((document_count > 0))"),
          "finance_sst_return_sources_line_number" => check("((line_number > 0))"),
          "finance_sst_return_sources_measure" =>
            check(
              "(((measure)::text = ANY ((ARRAY['documents'::character varying, 'received'::character varying, 'unpaid'::character varying, 'credited_after_due'::character varying])::text[])))"
            ),
          "finance_sst_return_sources_source" =>
            check(
              "(((source)::text = ANY ((ARRAY['receivables'::character varying, 'payables'::character varying])::text[])))"
            )
        }
      },
      %{
        name: "finance_sst_return_accounts",
        columns:
          owned_columns("finance_sst_return_accounts")
          |> Map.merge(%{
            "return_id" => column(:bigint, false),
            "line_number" => column(:integer, false),
            "account_id" => column(:bigint, false),
            "account_code" => column({:varchar, 50}, false),
            "account_name" => column({:varchar, 200}, false),
            "ledger_debits" => column({:numeric, 20, 4}, false),
            "ledger_credits" => column({:numeric, 20, 4}, false),
            "document_debits" => column({:numeric, 20, 4}, false),
            "document_credits" => column({:numeric, 20, 4}, false),
            "difference" => column({:numeric, 20, 4}, false)
          }),
        indexes: %{
          "finance_sst_return_accounts_pkey" => index(["id"], true),
          "finance_sst_return_accounts_return_account_unique" =>
            index(["return_id", "account_id"], true),
          "finance_sst_return_accounts_return_line_unique" =>
            index(["return_id", "line_number"], true)
        },
        foreign_keys: %{
          "finance_sst_return_accounts_return_fkey" =>
            company_reference("return_id", "finance_sst_returns")
        },
        checks: %{
          "finance_sst_return_accounts_difference" =>
            check(
              "((difference = ((ledger_credits - ledger_debits) - (document_credits - document_debits))))"
            ),
          "finance_sst_return_accounts_line_number" => check("((line_number > 0))")
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
