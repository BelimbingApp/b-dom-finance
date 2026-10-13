defmodule Bilimbi.Finance.Payroll.SchemaContract do
  @moduledoc """
  Fresh Bilimbi payroll posting schema.

  Not registered in the descriptor: compatibility verification runs before
  pending Bilimbi-only migrations, when these tables correctly do not exist.
  `test/schema_contract_test.exs` verifies it against the migration.
  """
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check and predicate text is PostgreSQL's canonical form, which the
  # verifier compares after removing whitespace and parentheses.

  def migration_versions, do: [20_261_015_120_000]

  def migration_version, do: List.last(migration_versions())

  @impl true
  def tables do
    [
      %{
        name: "finance_payroll_settings",
        columns:
          owned_columns("finance_payroll_settings")
          |> Map.merge(%{
            "net_pay_account_id" => column(:bigint, false),
            "claims_payable_account_id" => column(:bigint, false),
            "inserted_at" => column({:timestamp, 0}, false),
            "updated_at" => column({:timestamp, 0}, false)
          }),
        indexes: %{
          "finance_payroll_settings_pkey" => index(["id"], true),
          "finance_payroll_settings_company_unique" => index(["company_id"], true),
          "finance_payroll_settings_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{}
      },
      %{
        name: "finance_payroll_settings_changes",
        columns:
          owned_columns("finance_payroll_settings_changes")
          |> Map.merge(%{
            "old_net_pay_account_id" => column(:bigint, true),
            "new_net_pay_account_id" => column(:bigint, false),
            "old_claims_payable_account_id" => column(:bigint, true),
            "new_claims_payable_account_id" => column(:bigint, false),
            "reason" => column({:varchar, 500}, true),
            "changed_by_user_id" => column(:bigint, false),
            "changed_by_impersonator_id" => column(:bigint, true),
            "changed_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_payroll_settings_changes_pkey" => index(["id"], true),
          "finance_payroll_settings_changes_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_payroll_settings_changes_before" =>
            check("(old_net_pay_account_id IS NULL) = (old_claims_payable_account_id IS NULL)")
        }
      },
      %{
        name: "finance_payroll_mappings",
        columns:
          owned_columns("finance_payroll_mappings")
          |> Map.merge(%{
            "kind" => column({:varchar, 20}, false),
            "code" => column({:varchar, 60}, false),
            "direction" => column({:varchar, 20}, false),
            "expense_account_id" => column(:bigint, true),
            "liability_account_id" => column(:bigint, true),
            "inserted_at" => column({:timestamp, 0}, false),
            "updated_at" => column({:timestamp, 0}, false)
          }),
        indexes: %{
          "finance_payroll_mappings_pkey" => index(["id"], true),
          "finance_payroll_mappings_id_company_unique" => index(["id", "company_id"], true),
          "finance_payroll_mappings_company_key_unique" =>
            index(["company_id", "kind", "code", "direction"], true),
          "finance_payroll_mappings_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_payroll_mappings_kind" => check(one_of("kind", ~w(component claim_category))),
          "finance_payroll_mappings_direction" =>
            check(one_of("direction", ~w(earning deduction employer claim))),
          "finance_payroll_mappings_code" => check("(code)::text <> ''::text"),
          "finance_payroll_mappings_claim_direction" =>
            check("((kind)::text = 'claim_category'::text) = ((direction)::text = 'claim'::text)"),
          "finance_payroll_mappings_accounts" =>
            check(
              "(#{one_of("direction", ~w(earning claim))} AND (expense_account_id IS NOT NULL) " <>
                "AND (liability_account_id IS NULL)) OR " <>
                "(((direction)::text = 'deduction'::text) AND (expense_account_id IS NULL) " <>
                "AND (liability_account_id IS NOT NULL)) OR " <>
                "(((direction)::text = 'employer'::text) AND (expense_account_id IS NOT NULL) " <>
                "AND (liability_account_id IS NOT NULL))"
            )
        }
      },
      %{
        name: "finance_payroll_mapping_changes",
        columns:
          owned_columns("finance_payroll_mapping_changes")
          |> Map.merge(%{
            "mapping_id" => column(:bigint, false),
            "old_expense_account_id" => column(:bigint, true),
            "new_expense_account_id" => column(:bigint, true),
            "old_liability_account_id" => column(:bigint, true),
            "new_liability_account_id" => column(:bigint, true),
            "reason" => column({:varchar, 500}, true),
            "changed_by_user_id" => column(:bigint, false),
            "changed_by_impersonator_id" => column(:bigint, true),
            "changed_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_payroll_mapping_changes_pkey" => index(["id"], true),
          "finance_payroll_mapping_changes_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"]),
          "finance_payroll_mapping_changes_mapping_id_index" => index(["mapping_id"])
        },
        foreign_keys: %{
          "finance_payroll_mapping_changes_mapping_fkey" =>
            company_reference("mapping_id", "finance_payroll_mappings")
        },
        checks: %{
          "finance_payroll_mapping_changes_after" =>
            check(
              "(new_expense_account_id IS NOT NULL) OR (new_liability_account_id IS NOT NULL)"
            )
        }
      },
      %{
        name: "finance_payroll_posting_events",
        columns:
          owned_columns("finance_payroll_posting_events")
          |> Map.merge(%{
            "source_kind" => column({:varchar, 20}, false),
            "source_id" => column(:bigint, false),
            "source_reference" => column({:varchar, 100}, false),
            "event" => column({:varchar, 20}, false),
            "entry_id" => column(:bigint, true),
            "entry_number" => column(:bigint, true),
            "entry_date" => column(:date, true),
            "total" => column({:numeric, 20, 4}, true),
            "currency_code" => column({:varchar, 3}, true),
            "reason" => column({:varchar, 500}, true),
            "actor_user_id" => column(:bigint, false),
            "actor_impersonator_id" => column(:bigint, true),
            "occurred_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_payroll_posting_events_pkey" => index(["id"], true),
          "finance_payroll_posting_events_posted_unique" => %{
            columns: ["company_id", "source_kind", "source_id"],
            unique: true,
            where: "((event)::text = 'posted'::text)"
          },
          "finance_payroll_posting_events_reversed_unique" => %{
            columns: ["company_id", "source_kind", "source_id"],
            unique: true,
            where: "((event)::text = 'reversed'::text)"
          },
          "finance_payroll_posting_events_entry_unique" => %{
            columns: ["company_id", "entry_id"],
            unique: true,
            where: "(entry_id IS NOT NULL)"
          },
          "finance_payroll_posting_events_source_index" =>
            index(["company_id", "source_kind", "source_id"]),
          "finance_payroll_posting_events_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_payroll_posting_events_source_kind" =>
            check(one_of("source_kind", ~w(payroll_run claim))),
          "finance_payroll_posting_events_event" =>
            check(one_of("event", ~w(posted posting_failed reversed reversal_failed))),
          "finance_payroll_posting_events_entry" =>
            check(
              Enum.map_join(
                ~w(entry_id entry_number entry_date total currency_code),
                " AND ",
                &"(#{one_of("event", ~w(posted reversed))} = (#{&1} IS NOT NULL))"
              )
            ),
          "finance_payroll_posting_events_reason" =>
            check("((event)::text = 'posted'::text) OR (reason IS NOT NULL)"),
          "finance_payroll_posting_events_total" =>
            check("(total IS NULL) OR (total > (0)::numeric)"),
          "finance_payroll_posting_events_currency_code" =>
            check("(currency_code IS NULL) OR ((currency_code)::text ~ '^[A-Z]{3}$'::text)")
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
