defmodule Bilimbi.Finance.Reconciliation.SchemaContract do
  @moduledoc """
  Fresh Bilimbi bank reconciliation schema.

  Not registered in the descriptor: compatibility verification runs before
  pending Bilimbi-only migrations, when these tables correctly do not exist.
  `test/schema_contract_test.exs` verifies it against the migration.
  """
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check text is PostgreSQL's canonical form, which the verifier compares
  # after removing whitespace and parentheses.

  def migration_versions,
    do: [20_261_014_090_000, 20_261_015_150_600, 20_261_017_090_100]

  def migration_version, do: List.last(migration_versions())

  @impl true
  def tables do
    [
      %{
        name: "finance_reconciliation_bank_accounts",
        columns:
          owned_columns("finance_reconciliation_bank_accounts")
          |> Map.merge(%{
            "name" => column({:varchar, 200}, false),
            "ledger_account_id" => column(:bigint, false),
            "charges_account_id" => column(:bigint, true),
            "interest_account_id" => column(:bigint, true),
            "match_window_days" => column(:smallint, false, {:integer, 5}),
            "import_mapping" => column(:jsonb, false),
            "active" => column(:boolean, false, {:boolean, true}),
            "inserted_at" => column({:timestamp, 0}, false),
            "updated_at" => column({:timestamp, 0}, false)
          }),
        indexes: %{
          "finance_reconciliation_bank_accounts_company_name_unique" =>
            index(["company_id", "name"], true),
          "finance_reconciliation_bank_accounts_id_company_unique" =>
            index(["id", "company_id"], true),
          "finance_reconciliation_bank_accounts_ledger_account_unique" =>
            index(["company_id", "ledger_account_id"], true),
          "finance_reconciliation_bank_accounts_pkey" => index(["id"], true),
          "finance_reconciliation_bank_accounts_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_reconciliation_bank_accounts_match_window_days" =>
            check("((match_window_days >= 0) AND (match_window_days <= 90))")
        }
      },
      %{
        name: "finance_reconciliation_bank_account_changes",
        columns:
          owned_columns("finance_reconciliation_bank_account_changes")
          |> Map.merge(%{
            "bank_account_id" => column(:bigint, false),
            "field" => column({:varchar, 50}, false),
            "old_value" => column(:text, true),
            "new_value" => column(:text, true),
            "reason" => column({:varchar, 500}, true),
            "changed_by_user_id" => column(:bigint, false),
            "changed_by_impersonator_id" => column(:bigint, true),
            "changed_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_reconciliation_bank_account_changes_bank_account_index" =>
            index(["company_id", "bank_account_id"]),
          "finance_reconciliation_bank_account_changes_pkey" => index(["id"], true)
        },
        foreign_keys: %{
          "finance_reconciliation_bank_account_changes_bank_account_fkey" =>
            company_reference("bank_account_id", "finance_reconciliation_bank_accounts")
        },
        checks: %{}
      },
      %{
        name: "finance_reconciliation_statements",
        columns:
          owned_columns("finance_reconciliation_statements")
          |> Map.merge(%{
            "bank_account_id" => column(:bigint, false),
            "statement_number" => column(:bigint, false),
            "file_name" => column({:varchar, 255}, false),
            "file_sha256" => column({:varchar, 64}, false),
            "import_mapping" => column(:jsonb, true),
            "line_count" => column(:integer, false),
            "start_date" => column(:date, false),
            "end_date" => column(:date, false),
            "opening_balance" => column({:numeric, 20, 4}, true),
            "closing_balance" => column({:numeric, 20, 4}, true),
            "imported_by_user_id" => column(:bigint, false),
            "imported_by_impersonator_id" => column(:bigint, true),
            "imported_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_reconciliation_statements_bank_account_index" =>
            index(["company_id", "bank_account_id", "end_date"]),
          "finance_reconciliation_statements_company_number_unique" =>
            index(["company_id", "statement_number"], true),
          "finance_reconciliation_statements_file_unique" =>
            index(["company_id", "file_sha256"], true),
          "finance_reconciliation_statements_id_company_unique" =>
            index(["id", "company_id"], true),
          "finance_reconciliation_statements_pkey" => index(["id"], true)
        },
        foreign_keys: %{
          "finance_reconciliation_statements_bank_account_fkey" =>
            company_reference("bank_account_id", "finance_reconciliation_bank_accounts")
        },
        checks: %{
          "finance_reconciliation_statements_balances" =>
            check("((opening_balance IS NULL) = (closing_balance IS NULL))"),
          "finance_reconciliation_statements_dates" => check("(end_date >= start_date)"),
          "finance_reconciliation_statements_file_sha256" =>
            check("((file_sha256)::text ~ '^[0-9a-f]{64}$'::text)"),
          "finance_reconciliation_statements_line_count" => check("(line_count > 0)"),
          "finance_reconciliation_statements_statement_number" => check("(statement_number > 0)")
        }
      },
      %{
        name: "finance_reconciliation_statement_lines",
        columns:
          owned_columns("finance_reconciliation_statement_lines")
          |> Map.merge(%{
            "statement_id" => column(:bigint, false),
            "bank_account_id" => column(:bigint, false),
            "line_number" => column(:integer, false),
            "line_date" => column(:date, false),
            "description" => column({:varchar, 500}, false),
            "reference" => column({:varchar, 100}, true),
            "amount" => column({:numeric, 20, 4}, false),
            "running_balance" => column({:numeric, 20, 4}, true),
            "fingerprint" => column({:varchar, 64}, false)
          }),
        indexes: %{
          "finance_reconciliation_statement_lines_bank_account_date_index" =>
            index(["company_id", "bank_account_id", "line_date"]),
          "finance_reconciliation_statement_lines_fingerprint_unique" =>
            index(["company_id", "bank_account_id", "fingerprint"], true),
          "finance_reconciliation_statement_lines_id_company_unique" =>
            index(["id", "company_id"], true),
          "finance_reconciliation_statement_lines_pkey" => index(["id"], true),
          "finance_reconciliation_statement_lines_statement_line_unique" =>
            index(["statement_id", "line_number"], true)
        },
        foreign_keys: %{
          "finance_reconciliation_statement_lines_bank_account_fkey" =>
            company_reference("bank_account_id", "finance_reconciliation_bank_accounts"),
          "finance_reconciliation_statement_lines_statement_fkey" =>
            company_reference("statement_id", "finance_reconciliation_statements")
        },
        checks: %{
          "finance_reconciliation_statement_lines_amount" => check("(amount <> (0)::numeric)"),
          "finance_reconciliation_statement_lines_fingerprint" =>
            check("((fingerprint)::text ~ '^[0-9a-f]{64}$'::text)"),
          "finance_reconciliation_statement_lines_line_number" => check("(line_number > 0)")
        }
      },
      %{
        name: "finance_reconciliation_matches",
        columns:
          owned_columns("finance_reconciliation_matches")
          |> Map.merge(%{
            "bank_account_id" => column(:bigint, false),
            "match_number" => column(:bigint, false),
            "note" => column({:varchar, 500}, true),
            "matched_by_user_id" => column(:bigint, false),
            "matched_by_impersonator_id" => column(:bigint, true),
            "matched_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_reconciliation_matches_bank_account_index" =>
            index(["company_id", "bank_account_id"]),
          "finance_reconciliation_matches_company_number_unique" =>
            index(["company_id", "match_number"], true),
          "finance_reconciliation_matches_id_company_unique" => index(["id", "company_id"], true),
          "finance_reconciliation_matches_pkey" => index(["id"], true)
        },
        foreign_keys: %{
          "finance_reconciliation_matches_bank_account_fkey" =>
            company_reference("bank_account_id", "finance_reconciliation_bank_accounts")
        },
        checks: %{
          "finance_reconciliation_matches_match_number" => check("(match_number > 0)")
        }
      },
      %{
        name: "finance_reconciliation_match_lines",
        columns:
          owned_columns("finance_reconciliation_match_lines")
          |> Map.merge(%{
            "match_id" => column(:bigint, false),
            "statement_line_id" => column(:bigint, false)
          }),
        indexes: %{
          "finance_reconciliation_match_lines_match_line_unique" =>
            index(["match_id", "statement_line_id"], true),
          "finance_reconciliation_match_lines_pkey" => index(["id"], true),
          "finance_reconciliation_match_lines_statement_line_index" =>
            index(["statement_line_id"])
        },
        foreign_keys: %{
          "finance_reconciliation_match_lines_match_fkey" =>
            company_reference("match_id", "finance_reconciliation_matches"),
          "finance_reconciliation_match_lines_statement_line_fkey" =>
            company_reference("statement_line_id", "finance_reconciliation_statement_lines")
        },
        checks: %{}
      },
      %{
        name: "finance_reconciliation_match_entries",
        columns:
          owned_columns("finance_reconciliation_match_entries")
          |> Map.merge(%{
            "match_id" => column(:bigint, false),
            "bank_account_id" => column(:bigint, false),
            "entry_id" => column(:bigint, false),
            "entry_number" => column(:bigint, false),
            "entry_date" => column(:date, false),
            "description" => column({:varchar, 500}, false),
            "reference" => column({:varchar, 100}, true),
            "amount" => column({:numeric, 20, 4}, false)
          }),
        indexes: %{
          "finance_reconciliation_match_entries_entry_index" =>
            index(["company_id", "bank_account_id", "entry_id"]),
          "finance_reconciliation_match_entries_match_entry_unique" =>
            index(["match_id", "entry_id"], true),
          "finance_reconciliation_match_entries_pkey" => index(["id"], true)
        },
        foreign_keys: %{
          "finance_reconciliation_match_entries_bank_account_fkey" =>
            company_reference("bank_account_id", "finance_reconciliation_bank_accounts"),
          "finance_reconciliation_match_entries_match_fkey" =>
            company_reference("match_id", "finance_reconciliation_matches")
        },
        checks: %{
          "finance_reconciliation_match_entries_amount" => check("(amount <> (0)::numeric)")
        }
      },
      %{
        name: "finance_reconciliation_match_events",
        columns:
          owned_columns("finance_reconciliation_match_events")
          |> Map.merge(%{
            "event_number" => column(:bigint, false),
            "match_id" => column(:bigint, false),
            "action" => column({:varchar, 16}, false),
            "reason" => column({:varchar, 500}, true),
            "recorded_by_user_id" => column(:bigint, false),
            "recorded_by_impersonator_id" => column(:bigint, true),
            "recorded_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_reconciliation_match_events_company_number_unique" =>
            index(["company_id", "event_number"], true),
          "finance_reconciliation_match_events_match_action_unique" =>
            index(["match_id", "action"], true),
          "finance_reconciliation_match_events_pkey" => index(["id"], true)
        },
        foreign_keys: %{
          "finance_reconciliation_match_events_match_fkey" =>
            company_reference("match_id", "finance_reconciliation_matches")
        },
        checks: %{
          "finance_reconciliation_match_events_action" =>
            check(
              "((action)::text = ANY ((ARRAY['matched'::character varying, 'unmatched'::character varying])::text[]))"
            ),
          "finance_reconciliation_match_events_event_number" => check("(event_number > 0)"),
          "finance_reconciliation_match_events_unmatch_reason" =>
            check(
              "(((action)::text <> 'unmatched'::text) OR ((reason IS NOT NULL) AND (btrim((reason)::text) <> ''::text)))"
            )
        }
      },
      %{
        name: "finance_reconciliation_reconciliations",
        columns:
          owned_columns("finance_reconciliation_reconciliations")
          |> Map.merge(%{
            "bank_account_id" => column(:bigint, false),
            "reconciliation_number" => column(:bigint, false),
            "end_date" => column(:date, false),
            "statement_balance" => column({:numeric, 20, 4}, false),
            "opened_by_user_id" => column(:bigint, false),
            "opened_by_impersonator_id" => column(:bigint, true),
            "opened_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_reconciliation_reconciliations_bank_account_index" =>
            index(["company_id", "bank_account_id", "end_date"]),
          "finance_reconciliation_reconciliations_company_number_unique" =>
            index(["company_id", "reconciliation_number"], true),
          "finance_reconciliation_reconciliations_id_company_unique" =>
            index(["id", "company_id"], true),
          "finance_reconciliation_reconciliations_pkey" => index(["id"], true)
        },
        foreign_keys: %{
          "finance_reconciliation_reconciliations_bank_account_fkey" =>
            company_reference("bank_account_id", "finance_reconciliation_bank_accounts")
        },
        checks: %{
          "finance_reconciliation_reconciliations_reconciliation_number" =>
            check("(reconciliation_number > 0)")
        }
      },
      %{
        name: "finance_reconciliation_reconciliation_events",
        columns:
          owned_columns("finance_reconciliation_reconciliation_events")
          |> Map.merge(%{
            "event_number" => column(:bigint, false),
            "reconciliation_id" => column(:bigint, false),
            "action" => column({:varchar, 16}, false),
            "reason" => column({:varchar, 500}, true),
            "book_balance" => column({:numeric, 20, 4}, true),
            "difference" => column({:numeric, 20, 4}, true),
            "through_entry_number" => column(:bigint, true),
            "through_statement_number" => column(:bigint, true),
            "through_match_event_number" => column(:bigint, true),
            "recorded_by_user_id" => column(:bigint, false),
            "recorded_by_impersonator_id" => column(:bigint, true),
            "recorded_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_reconciliation_reconciliation_events_action_unique" =>
            index(["reconciliation_id", "action"], true),
          "finance_reconciliation_reconciliation_events_number_unique" =>
            index(["company_id", "event_number"], true),
          "finance_reconciliation_reconciliation_events_pkey" => index(["id"], true)
        },
        foreign_keys: %{
          "finance_reconciliation_reconciliation_events_parent_fkey" =>
            company_reference("reconciliation_id", "finance_reconciliation_reconciliations")
        },
        checks: %{
          "finance_reconciliation_reconciliation_events_abandon_reason" =>
            check(
              "(((action)::text <> 'abandoned'::text) OR ((reason IS NOT NULL) AND (btrim((reason)::text) <> ''::text)))"
            ),
          "finance_reconciliation_reconciliation_events_action" =>
            check(
              "((action)::text = ANY ((ARRAY['opened'::character varying, 'finalised'::character varying, 'abandoned'::character varying])::text[]))"
            ),
          "finance_reconciliation_reconciliation_events_event_number" =>
            check("(event_number > 0)"),
          "finance_reconciliation_reconciliation_events_figures" =>
            check(
              "((((action)::text = 'finalised'::text) = (book_balance IS NOT NULL)) AND (((action)::text = 'finalised'::text) = (difference IS NOT NULL)) AND (((action)::text = 'finalised'::text) = (through_entry_number IS NOT NULL)) AND (((action)::text = 'finalised'::text) = (through_statement_number IS NOT NULL)) AND (((action)::text = 'finalised'::text) = (through_match_event_number IS NOT NULL)) AND ((difference IS NULL) OR (difference = (0)::numeric)))"
            )
        }
      },
      %{
        name: "finance_reconciliation_reconciliation_items",
        columns:
          owned_columns("finance_reconciliation_reconciliation_items")
          |> Map.merge(%{
            "reconciliation_id" => column(:bigint, false),
            "item_number" => column(:integer, false),
            "kind" => column({:varchar, 32}, false),
            "statement_line_id" => column(:bigint, true),
            "entry_id" => column(:bigint, true),
            "match_id" => column(:bigint, true),
            "item_date" => column(:date, false),
            "description" => column({:varchar, 500}, false),
            "reference" => column({:varchar, 100}, true),
            "amount" => column({:numeric, 20, 4}, false)
          }),
        indexes: %{
          "finance_reconciliation_reconciliation_items_number_unique" =>
            index(["reconciliation_id", "item_number"], true),
          "finance_reconciliation_reconciliation_items_pkey" => index(["id"], true)
        },
        foreign_keys: %{
          "finance_reconciliation_reconciliation_items_reconciliation_fkey" =>
            company_reference("reconciliation_id", "finance_reconciliation_reconciliations")
        },
        checks: %{
          "finance_reconciliation_reconciliation_items_item_number" => check("(item_number > 0)"),
          "finance_reconciliation_reconciliation_items_kind" =>
            check(
              "((kind)::text = ANY ((ARRAY['statement_line'::character varying, 'entry'::character varying, 'timing'::character varying])::text[]))"
            ),
          "finance_reconciliation_reconciliation_items_subject" =>
            check(
              "((((kind)::text = 'statement_line'::text) = (statement_line_id IS NOT NULL)) AND (((kind)::text = 'entry'::text) = (entry_id IS NOT NULL)) AND (((kind)::text = 'timing'::text) = (match_id IS NOT NULL)))"
            )
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
