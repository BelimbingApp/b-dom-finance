defmodule Bilimbi.Finance.Ledger.SchemaContract do
  @moduledoc """
  Fresh Bilimbi ledger schema.

  Not registered in the descriptor: compatibility verification runs before
  pending Bilimbi-only migrations, when these tables correctly do not exist.
  `test/schema_contract_test.exs` verifies it against the migration.
  """
  @behaviour Bilimbi.Base.Database.SchemaContract

  # Check and predicate text is PostgreSQL's canonical form, which the
  # verifier compares after removing whitespace and parentheses.

  @doc "The migrations that build the schema, oldest first; the contract is their result."
  def migration_versions,
    do: [20_261_012_170_100, 20_261_012_214_100, 20_261_013_101_700, 20_261_015_150_000]

  @impl true
  def tables do
    [
      %{
        name: "finance_ledger_books",
        columns:
          owned_columns("finance_ledger_books")
          |> Map.merge(%{
            "currency_code" => column({:varchar, 3}, false),
            "minor_units" => column(:smallint, false),
            "inserted_at" => column({:timestamp, 0}, false)
          }),
        indexes: %{
          "finance_ledger_books_pkey" => index(["id"], true),
          "finance_ledger_books_company_unique" => index(["company_id"], true),
          "finance_ledger_books_company_currency_unique" =>
            index(["company_id", "currency_code"], true),
          "finance_ledger_books_tenant_id_company_id_index" => index(["tenant_id", "company_id"])
        },
        foreign_keys: %{},
        checks: %{
          "finance_ledger_books_currency_code" =>
            check("(currency_code)::text ~ '^[A-Z]{3}$'::text"),
          "finance_ledger_books_minor_units" => check("minor_units >= 0 AND minor_units <= 4")
        }
      },
      %{
        name: "finance_ledger_accounts",
        columns:
          owned_columns("finance_ledger_accounts")
          |> Map.merge(%{
            "code" => column({:varchar, 50}, false),
            "name" => column({:varchar, 200}, false),
            "account_type" => column({:varchar, 16}, false),
            "parent_id" => column(:bigint, true),
            "active" => column(:boolean, false, {:boolean, true}),
            "inserted_at" => column({:timestamp, 0}, false),
            "updated_at" => column({:timestamp, 0}, false),
            "retained_earnings" => column(:boolean, false, {:boolean, false})
          }),
        indexes: %{
          "finance_ledger_accounts_pkey" => index(["id"], true),
          "finance_ledger_accounts_id_company_unique" => index(["id", "company_id"], true),
          "finance_ledger_accounts_company_code_unique" => index(["company_id", "code"], true),
          "finance_ledger_accounts_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"]),
          "finance_ledger_accounts_one_retained_earnings" => %{
            columns: ["company_id"],
            unique: true,
            where: "retained_earnings"
          }
        },
        foreign_keys: %{
          "finance_ledger_accounts_parent_fkey" =>
            company_reference("parent_id", "finance_ledger_accounts")
        },
        checks: %{
          "finance_ledger_accounts_account_type" =>
            check(
              "(account_type)::text = ANY ((ARRAY['asset'::character varying, " <>
                "'liability'::character varying, 'equity'::character varying, " <>
                "'income'::character varying, 'expense'::character varying])::text[])"
            ),
          "finance_ledger_accounts_not_own_parent" =>
            check("parent_id IS NULL OR parent_id <> id"),
          "finance_ledger_accounts_retained_earnings_equity" =>
            check("NOT retained_earnings OR (account_type)::text = 'equity'::text")
        }
      },
      %{
        name: "finance_ledger_entries",
        columns:
          owned_columns("finance_ledger_entries")
          |> Map.merge(%{
            "entry_number" => column(:bigint, false),
            "entry_date" => column(:date, false),
            "description" => column({:varchar, 500}, false),
            "reference" => column({:varchar, 100}, true),
            "currency_code" => column({:varchar, 3}, false),
            "reverses_entry_id" => column(:bigint, true),
            "owner_module" => column({:varchar, 100}, true),
            "owner_record" => column({:varchar, 100}, true),
            "legacy" => column(:boolean, false, {:boolean, false}),
            "posted_by_user_id" => column(:bigint, false),
            "posted_by_impersonator_id" => column(:bigint, true),
            "posted_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_ledger_entries_pkey" => index(["id"], true),
          "finance_ledger_entries_id_company_unique" => index(["id", "company_id"], true),
          "finance_ledger_entries_reversed_once" => %{
            columns: ["reverses_entry_id"],
            unique: true,
            where: "(reverses_entry_id IS NOT NULL)"
          },
          "finance_ledger_entries_owner_record_unique" => %{
            columns: ["company_id", "owner_module", "owner_record"],
            unique: true,
            where: "((owner_module IS NOT NULL) AND (reverses_entry_id IS NULL))"
          },
          "finance_ledger_entries_tenant_id_company_id_entry_date_index" =>
            index(["tenant_id", "company_id", "entry_date"]),
          "finance_ledger_entries_company_number_unique" =>
            index(["company_id", "entry_number"], true)
        },
        foreign_keys: %{
          "finance_ledger_entries_book_fkey" => %{
            columns: ["currency_code", "company_id"],
            references: {"finance_ledger_books", ["currency_code", "company_id"]},
            on_delete: :restrict
          },
          "finance_ledger_entries_reverses_entry_fkey" =>
            company_reference("reverses_entry_id", "finance_ledger_entries")
        },
        checks: %{
          "finance_ledger_entries_not_own_reversal" =>
            check("reverses_entry_id IS NULL OR reverses_entry_id <> id"),
          "finance_ledger_entries_entry_number" => check("entry_number > 0"),
          "finance_ledger_entries_owner_pair" =>
            check("(owner_module IS NULL) = (owner_record IS NULL)"),
          "finance_ledger_entries_owner_module" =>
            check(
              "owner_module IS NULL OR (owner_module)::text ~ '^[a-z][a-z0-9_]*/[a-z][a-z0-9_]*$'::text"
            ),
          "finance_ledger_entries_owner_record" =>
            check(
              "owner_record IS NULL OR (owner_record)::text ~ '^[a-z][a-z0-9_]*:[1-9][0-9]*$'::text"
            )
        }
      },
      %{
        name: "finance_ledger_entry_lines",
        columns:
          owned_columns("finance_ledger_entry_lines")
          |> Map.merge(%{
            "entry_id" => column(:bigint, false),
            "line_number" => column(:integer, false),
            "account_id" => column(:bigint, false),
            "debit" => column({:numeric, 20, 4}, false),
            "credit" => column({:numeric, 20, 4}, false),
            "description" => column({:varchar, 500}, true)
          }),
        indexes: %{
          "finance_ledger_entry_lines_pkey" => index(["id"], true),
          "finance_ledger_entry_lines_entry_line_unique" =>
            index(["entry_id", "line_number"], true),
          "finance_ledger_entry_lines_company_id_account_id_index" =>
            index(["company_id", "account_id"])
        },
        foreign_keys: %{
          "finance_ledger_entry_lines_entry_fkey" =>
            company_reference("entry_id", "finance_ledger_entries"),
          "finance_ledger_entry_lines_account_fkey" =>
            company_reference("account_id", "finance_ledger_accounts")
        },
        checks: %{
          "finance_ledger_entry_lines_line_number" => check("line_number > 0"),
          "finance_ledger_entry_lines_one_side" =>
            check(
              "debit >= (0)::numeric AND credit >= (0)::numeric AND " <>
                "((debit = (0)::numeric) <> (credit = (0)::numeric))"
            )
        }
      }
    ] ++ closing_tables()
  end

  defp closing_tables do
    [
      %{
        name: "finance_ledger_fiscal_years",
        columns:
          owned_columns("finance_ledger_fiscal_years")
          |> Map.merge(%{
            "start_date" => column(:date, false),
            "end_date" => column(:date, false),
            "opened_by_user_id" => column(:bigint, false),
            "opened_by_impersonator_id" => column(:bigint, true),
            "opened_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_ledger_fiscal_years_pkey" => index(["id"], true),
          "finance_ledger_fiscal_years_id_company_unique" => index(["id", "company_id"], true),
          "finance_ledger_fiscal_years_company_start_unique" =>
            index(["company_id", "start_date"], true),
          "finance_ledger_fiscal_years_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{
          "finance_ledger_fiscal_years_book_fkey" => %{
            columns: ["company_id"],
            references: {"finance_ledger_books", ["company_id"]},
            on_delete: :restrict
          }
        },
        checks: %{
          "finance_ledger_fiscal_years_months" =>
            check(
              "EXTRACT(day FROM start_date) = (1)::numeric AND " <>
                "EXTRACT(day FROM (end_date + 1)) = (1)::numeric AND end_date > start_date AND " <>
                "end_date < (start_date + '2 years'::interval)"
            )
        }
      },
      %{
        name: "finance_ledger_periods",
        columns:
          owned_columns("finance_ledger_periods")
          |> Map.merge(%{
            "fiscal_year_id" => column(:bigint, false),
            "period_number" => column(:smallint, false),
            "start_date" => column(:date, false),
            "end_date" => column(:date, false)
          }),
        indexes: %{
          "finance_ledger_periods_pkey" => index(["id"], true),
          "finance_ledger_periods_id_company_unique" => index(["id", "company_id"], true),
          "finance_ledger_periods_id_fiscal_year_unique" => index(["id", "fiscal_year_id"], true),
          "finance_ledger_periods_fiscal_year_number_unique" =>
            index(["fiscal_year_id", "period_number"], true),
          "finance_ledger_periods_company_start_unique" =>
            index(["company_id", "start_date"], true),
          "finance_ledger_periods_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{
          "finance_ledger_periods_fiscal_year_fkey" =>
            company_reference("fiscal_year_id", "finance_ledger_fiscal_years")
        },
        checks: %{
          "finance_ledger_periods_period_number" => check("period_number > 0"),
          "finance_ledger_periods_one_month" =>
            check(
              "EXTRACT(day FROM start_date) = (1)::numeric AND " <>
                "end_date = ((start_date + '1 mon'::interval) - '1 day'::interval)::date"
            )
        }
      },
      %{
        name: "finance_ledger_closing_events",
        columns:
          owned_columns("finance_ledger_closing_events")
          |> Map.merge(%{
            "event_number" => column(:bigint, false),
            "fiscal_year_id" => column(:bigint, false),
            "period_id" => column(:bigint, true),
            "action" => column({:varchar, 16}, false),
            "reason" => column({:varchar, 500}, true),
            "entry_id" => column(:bigint, true),
            "retained_earnings_account_id" => column(:bigint, true),
            "recorded_by_user_id" => column(:bigint, false),
            "recorded_by_impersonator_id" => column(:bigint, true),
            "recorded_at" => column({:timestamp, 6}, false)
          }),
        indexes: %{
          "finance_ledger_closing_events_pkey" => index(["id"], true),
          "finance_ledger_closing_events_company_number_unique" =>
            index(["company_id", "event_number"], true),
          "finance_ledger_closing_events_entry_unique" => %{
            columns: ["entry_id"],
            unique: true,
            where: "(entry_id IS NOT NULL)"
          },
          "finance_ledger_closing_events_fiscal_year_id_event_number_index" =>
            index(["fiscal_year_id", "event_number"]),
          "finance_ledger_closing_events_period_id_event_number_index" =>
            index(["period_id", "event_number"]),
          "finance_ledger_closing_events_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
        },
        foreign_keys: %{
          "finance_ledger_closing_events_fiscal_year_fkey" =>
            company_reference("fiscal_year_id", "finance_ledger_fiscal_years"),
          "finance_ledger_closing_events_period_fkey" => %{
            columns: ["period_id", "fiscal_year_id"],
            references: {"finance_ledger_periods", ["id", "fiscal_year_id"]},
            on_delete: :restrict
          },
          "finance_ledger_closing_events_entry_fkey" =>
            company_reference("entry_id", "finance_ledger_entries"),
          "finance_ledger_closing_events_retained_earnings_fkey" =>
            company_reference("retained_earnings_account_id", "finance_ledger_accounts")
        },
        checks: %{
          "finance_ledger_closing_events_action" =>
            check(
              "(action)::text = ANY ((ARRAY['close'::character varying, " <>
                "'reopen'::character varying, 'lock'::character varying])::text[])"
            ),
          "finance_ledger_closing_events_event_number" => check("event_number > 0"),
          "finance_ledger_closing_events_reopen_reason" =>
            check(
              "(action)::text <> 'reopen'::text OR " <>
                "(reason IS NOT NULL AND btrim((reason)::text) <> ''::text)"
            ),
          "finance_ledger_closing_events_year_fields" =>
            check(
              "(period_id IS NOT NULL OR (action)::text <> 'lock'::text) AND " <>
                "((period_id IS NULL AND (action)::text = 'close'::text) OR " <>
                "(entry_id IS NULL AND retained_earnings_account_id IS NULL))"
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
