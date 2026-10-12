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

  def migration_version, do: 20_261_012_170_100

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
            "updated_at" => column({:timestamp, 0}, false)
          }),
        indexes: %{
          "finance_ledger_accounts_pkey" => index(["id"], true),
          "finance_ledger_accounts_id_company_unique" => index(["id", "company_id"], true),
          "finance_ledger_accounts_company_code_unique" => index(["company_id", "code"], true),
          "finance_ledger_accounts_tenant_id_company_id_index" =>
            index(["tenant_id", "company_id"])
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
            check("parent_id IS NULL OR parent_id <> id")
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
          "finance_ledger_entries_entry_number" => check("entry_number > 0")
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
