defmodule Bilimbi.Finance.FixedAssets.SchemaContract do
  @moduledoc "Fresh Bilimbi-only structure, verified after migration rather than during adoption."
  @behaviour Bilimbi.Base.Database.SchemaContract
  @doc "The migrations that build this contract, in order."
  def migration_versions, do: [20_261_015_110_000, 20_261_015_150_700]

  def migration_version, do: List.last(migration_versions())
  @impl true
  def tables,
    do: [
      %{
        name: "finance_fixed_assets_categories",
        columns: %{
          "company_id" => %{default: nil, type: :bigint, nullable: false},
          "id" => %{
            default: {:sequence, "finance_fixed_assets_categories_id_seq"},
            type: :bigint,
            nullable: false
          },
          "name" => %{default: nil, type: {:varchar, 200}, nullable: false},
          "recorded_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "recorded_by_impersonator_id" => %{default: nil, type: :bigint, nullable: true},
          "recorded_by_user_id" => %{default: nil, type: :bigint, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false}
        },
        indexes: %{
          "finance_fixed_assets_categories_identity" => %{
            where: nil,
            columns: ["id", "tenant_id", "company_id"],
            unique: true
          },
          "finance_fixed_assets_categories_name" => %{
            where: nil,
            columns: ["company_id", "name"],
            unique: true
          },
          "finance_fixed_assets_categories_pkey" => %{where: nil, columns: ["id"], unique: true},
          "finance_fixed_assets_categories_scope" => %{
            where: nil,
            columns: ["tenant_id", "company_id"],
            unique: false
          }
        },
        checks: %{
          "finance_fixed_assets_categories_name_check" => %{
            expression: "btrim(name::text) <> ''::text"
          },
          "finance_fixed_assets_categories_recorded_by_user_id_check" => %{
            expression: "recorded_by_user_id > 0"
          }
        },
        foreign_keys: %{}
      },
      %{
        name: "finance_fixed_assets_category_revisions",
        columns: %{
          "accumulated_account_id" => %{default: nil, type: :bigint, nullable: false},
          "annual_rate" => %{default: nil, type: {:numeric, 7, 4}, nullable: true},
          "category_id" => %{default: nil, type: :bigint, nullable: false},
          "company_id" => %{default: nil, type: :bigint, nullable: false},
          "cost_account_id" => %{default: nil, type: :bigint, nullable: false},
          "expense_account_id" => %{default: nil, type: :bigint, nullable: false},
          "gain_account_id" => %{default: nil, type: :bigint, nullable: false},
          "id" => %{
            default: {:sequence, "finance_fixed_assets_category_revisions_id_seq"},
            type: :bigint,
            nullable: false
          },
          "life_months" => %{default: nil, type: :integer, nullable: false},
          "loss_account_id" => %{default: nil, type: :bigint, nullable: false},
          "method" => %{default: nil, type: {:varchar, 20}, nullable: false},
          "reason" => %{default: nil, type: {:varchar, 500}, nullable: false},
          "recorded_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "recorded_by_impersonator_id" => %{default: nil, type: :bigint, nullable: true},
          "recorded_by_user_id" => %{default: nil, type: :bigint, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false}
        },
        indexes: %{
          "finance_fixed_assets_category_revisions_identity" => %{
            where: nil,
            columns: ["id", "tenant_id", "company_id"],
            unique: true
          },
          "finance_fixed_assets_category_revisions_pkey" => %{
            where: nil,
            columns: ["id"],
            unique: true
          },
          "finance_fixed_assets_category_revisions_scope" => %{
            where: nil,
            columns: ["tenant_id", "company_id"],
            unique: false
          }
        },
        checks: %{
          "finance_fixed_assets_category_revisio_recorded_by_user_id_check" => %{
            expression: "recorded_by_user_id > 0"
          },
          "finance_fixed_assets_category_revisions_check" => %{
            expression:
              "method::text = 'straight_line'::text AND annual_rate IS NULL OR method::text = 'reducing_balance'::text AND annual_rate > 0::numeric AND annual_rate <= 100::numeric"
          },
          "finance_fixed_assets_category_revisions_life_months_check" => %{
            expression: "life_months >= 1 AND life_months <= 1200"
          },
          "finance_fixed_assets_category_revisions_method_check" => %{
            expression:
              "method::text = ANY (ARRAY['straight_line'::character varying, 'reducing_balance'::character varying]::text[]"
          },
          "finance_fixed_assets_category_revisions_reason_check" => %{
            expression: "btrim(reason::text) <> ''::text"
          }
        },
        foreign_keys: %{
          "finance_fixed_assets_category_category_id_tenant_id_compan_fkey" => %{
            columns: ["category_id", "tenant_id", "company_id"],
            references: {"finance_fixed_assets_categories", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict,
            on_update: :nothing
          }
        }
      },
      %{
        name: "finance_fixed_assets_assets",
        columns: %{
          "acquisition_date" => %{default: nil, type: :date, nullable: false},
          "annual_rate" => %{default: nil, type: {:numeric, 7, 4}, nullable: true},
          "asset_number" => %{default: nil, type: :bigint, nullable: false},
          "bill_id" => %{default: nil, type: :bigint, nullable: true},
          "bill_line_number" => %{default: nil, type: :integer, nullable: true},
          "category_revision_id" => %{default: nil, type: :bigint, nullable: false},
          "company_id" => %{default: nil, type: :bigint, nullable: false},
          "cost" => %{default: nil, type: {:numeric, 20, 4}, nullable: false},
          "description" => %{default: nil, type: {:varchar, 500}, nullable: false},
          "entry_id" => %{default: nil, type: :bigint, nullable: false},
          "entry_line_number" => %{default: nil, type: :integer, nullable: false},
          "entry_number" => %{default: nil, type: :bigint, nullable: false},
          "id" => %{
            default: {:sequence, "finance_fixed_assets_assets_id_seq"},
            type: :bigint,
            nullable: false
          },
          "in_service_date" => %{default: nil, type: :date, nullable: false},
          "life_months" => %{default: nil, type: :integer, nullable: false},
          "method" => %{default: nil, type: {:varchar, 20}, nullable: false},
          "recorded_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "recorded_by_impersonator_id" => %{default: nil, type: :bigint, nullable: true},
          "recorded_by_user_id" => %{default: nil, type: :bigint, nullable: false},
          "residual_value" => %{default: nil, type: {:numeric, 20, 4}, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false}
        },
        indexes: %{
          "finance_fixed_assets_assets_identity" => %{
            where: nil,
            columns: ["id", "tenant_id", "company_id"],
            unique: true
          },
          "finance_fixed_assets_assets_number" => %{
            where: nil,
            columns: ["company_id", "asset_number"],
            unique: true
          },
          "finance_fixed_assets_assets_pkey" => %{where: nil, columns: ["id"], unique: true},
          "finance_fixed_assets_assets_scope" => %{
            where: nil,
            columns: ["tenant_id", "company_id"],
            unique: false
          },
          "finance_fixed_assets_assets_source" => %{
            where: nil,
            columns: ["company_id", "entry_id", "entry_line_number"],
            unique: true
          }
        },
        checks: %{
          "finance_fixed_assets_assets_asset_number_check" => %{expression: "asset_number > 0"},
          "finance_fixed_assets_assets_check" => %{
            expression: "in_service_date >= acquisition_date"
          },
          "finance_fixed_assets_assets_check1" => %{
            expression: "residual_value >= 0::numeric AND residual_value <= cost"
          },
          "finance_fixed_assets_assets_check2" => %{
            expression:
              "bill_id IS NULL AND bill_line_number IS NULL OR bill_id > 0 AND bill_line_number > 0"
          },
          "finance_fixed_assets_assets_check3" => %{
            expression:
              "method::text = 'straight_line'::text AND annual_rate IS NULL OR method::text = 'reducing_balance'::text AND annual_rate > 0::numeric AND annual_rate <= 100::numeric"
          },
          "finance_fixed_assets_assets_cost_check" => %{expression: "cost > 0::numeric"},
          "finance_fixed_assets_assets_description_check" => %{
            expression: "btrim(description::text) <> ''::text"
          },
          "finance_fixed_assets_assets_entry_line_number_check" => %{
            expression: "entry_line_number > 0"
          },
          "finance_fixed_assets_assets_life_months_check" => %{
            expression: "life_months >= 1 AND life_months <= 1200"
          },
          "finance_fixed_assets_assets_method_check" => %{
            expression:
              "method::text = ANY (ARRAY['straight_line'::character varying, 'reducing_balance'::character varying]::text[]"
          },
          "finance_fixed_assets_assets_recorded_by_user_id_check" => %{
            expression: "recorded_by_user_id > 0"
          }
        },
        foreign_keys: %{
          "finance_fixed_assets_assets_category_revision_id_tenant_id_fkey" => %{
            columns: ["category_revision_id", "tenant_id", "company_id"],
            references:
              {"finance_fixed_assets_category_revisions", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict,
            on_update: :nothing
          }
        }
      },
      %{
        name: "finance_fixed_assets_runs",
        columns: %{
          "company_id" => %{default: nil, type: :bigint, nullable: false},
          "entry_id" => %{default: nil, type: :bigint, nullable: true},
          "entry_number" => %{default: nil, type: :bigint, nullable: true},
          "id" => %{
            default: {:sequence, "finance_fixed_assets_runs_id_seq"},
            type: :bigint,
            nullable: false
          },
          "period" => %{default: nil, type: :date, nullable: false},
          "recorded_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "recorded_by_impersonator_id" => %{default: nil, type: :bigint, nullable: true},
          "recorded_by_user_id" => %{default: nil, type: :bigint, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false},
          "total" => %{default: nil, type: {:numeric, 20, 4}, nullable: false}
        },
        indexes: %{
          "finance_fixed_assets_runs_identity" => %{
            where: nil,
            columns: ["id", "tenant_id", "company_id"],
            unique: true
          },
          "finance_fixed_assets_runs_period" => %{
            where: nil,
            columns: ["company_id", "period"],
            unique: true
          },
          "finance_fixed_assets_runs_pkey" => %{where: nil, columns: ["id"], unique: true},
          "finance_fixed_assets_runs_scope" => %{
            where: nil,
            columns: ["tenant_id", "company_id"],
            unique: false
          }
        },
        checks: %{
          "finance_fixed_assets_runs_check" => %{
            expression:
              "total = 0::numeric AND entry_id IS NULL AND entry_number IS NULL OR total > 0::numeric AND entry_id IS NOT NULL AND entry_number IS NOT NULL"
          },
          "finance_fixed_assets_runs_period_check" => %{
            expression: "EXTRACT(day FROM period) = 1::numeric"
          },
          "finance_fixed_assets_runs_recorded_by_user_id_check" => %{
            expression: "recorded_by_user_id > 0"
          },
          "finance_fixed_assets_runs_total_check" => %{expression: "total >= 0::numeric"}
        },
        foreign_keys: %{}
      },
      %{
        name: "finance_fixed_assets_run_items",
        columns: %{
          "amount" => %{default: nil, type: {:numeric, 20, 4}, nullable: false},
          "asset_id" => %{default: nil, type: :bigint, nullable: false},
          "company_id" => %{default: nil, type: :bigint, nullable: false},
          "id" => %{
            default: {:sequence, "finance_fixed_assets_run_items_id_seq"},
            type: :bigint,
            nullable: false
          },
          "recorded_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "recorded_by_impersonator_id" => %{default: nil, type: :bigint, nullable: true},
          "recorded_by_user_id" => %{default: nil, type: :bigint, nullable: false},
          "run_id" => %{default: nil, type: :bigint, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false}
        },
        indexes: %{
          "finance_fixed_assets_run_items_asset" => %{
            where: nil,
            columns: ["run_id", "asset_id"],
            unique: true
          },
          "finance_fixed_assets_run_items_identity" => %{
            where: nil,
            columns: ["id", "tenant_id", "company_id"],
            unique: true
          },
          "finance_fixed_assets_run_items_pkey" => %{where: nil, columns: ["id"], unique: true},
          "finance_fixed_assets_run_items_scope" => %{
            where: nil,
            columns: ["tenant_id", "company_id"],
            unique: false
          }
        },
        checks: %{
          "finance_fixed_assets_run_items_amount_check" => %{expression: "amount > 0::numeric"},
          "finance_fixed_assets_run_items_recorded_by_user_id_check" => %{
            expression: "recorded_by_user_id > 0"
          }
        },
        foreign_keys: %{
          "finance_fixed_assets_run_item_asset_id_tenant_id_company_i_fkey" => %{
            columns: ["asset_id", "tenant_id", "company_id"],
            references: {"finance_fixed_assets_assets", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict,
            on_update: :nothing
          },
          "finance_fixed_assets_run_items_run_id_tenant_id_company_id_fkey" => %{
            columns: ["run_id", "tenant_id", "company_id"],
            references: {"finance_fixed_assets_runs", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict,
            on_update: :nothing
          }
        }
      },
      %{
        name: "finance_fixed_assets_run_exceptions",
        columns: %{
          "asset_id" => %{default: nil, type: :bigint, nullable: false},
          "company_id" => %{default: nil, type: :bigint, nullable: false},
          "id" => %{
            default: {:sequence, "finance_fixed_assets_run_exceptions_id_seq"},
            type: :bigint,
            nullable: false
          },
          "recorded_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "recorded_by_impersonator_id" => %{default: nil, type: :bigint, nullable: true},
          "recorded_by_user_id" => %{default: nil, type: :bigint, nullable: false},
          "run_id" => %{default: nil, type: :bigint, nullable: false},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false}
        },
        indexes: %{
          "finance_fixed_assets_run_exceptions_asset" => %{
            where: nil,
            columns: ["run_id", "asset_id"],
            unique: true
          },
          "finance_fixed_assets_run_exceptions_identity" => %{
            where: nil,
            columns: ["id", "tenant_id", "company_id"],
            unique: true
          },
          "finance_fixed_assets_run_exceptions_pkey" => %{
            where: nil,
            columns: ["id"],
            unique: true
          },
          "finance_fixed_assets_run_exceptions_scope" => %{
            where: nil,
            columns: ["tenant_id", "company_id"],
            unique: false
          }
        },
        checks: %{
          "finance_fixed_assets_run_exceptions_recorded_by_user_id_check" => %{
            expression: "recorded_by_user_id > 0"
          }
        },
        foreign_keys: %{
          "finance_fixed_assets_run_exce_asset_id_tenant_id_company_i_fkey" => %{
            columns: ["asset_id", "tenant_id", "company_id"],
            references: {"finance_fixed_assets_assets", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict,
            on_update: :nothing
          },
          "finance_fixed_assets_run_excep_run_id_tenant_id_company_id_fkey" => %{
            columns: ["run_id", "tenant_id", "company_id"],
            references: {"finance_fixed_assets_runs", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict,
            on_update: :nothing
          }
        }
      },
      %{
        name: "finance_fixed_assets_events",
        columns: %{
          "accumulated" => %{default: nil, type: {:numeric, 20, 4}, nullable: true},
          "action" => %{default: nil, type: {:varchar, 20}, nullable: false},
          "asset_id" => %{default: nil, type: :bigint, nullable: true},
          "company_id" => %{default: nil, type: :bigint, nullable: false},
          "effective_date" => %{default: nil, type: :date, nullable: false},
          "entry_id" => %{default: nil, type: :bigint, nullable: true},
          "entry_number" => %{default: nil, type: :bigint, nullable: true},
          "event_number" => %{default: nil, type: :bigint, nullable: false},
          "id" => %{
            default: {:sequence, "finance_fixed_assets_events_id_seq"},
            type: :bigint,
            nullable: false
          },
          "proceeds" => %{default: nil, type: {:numeric, 20, 4}, nullable: true},
          "reason" => %{default: nil, type: {:varchar, 500}, nullable: false},
          "recorded_at" => %{default: nil, type: {:timestamp, 6}, nullable: false},
          "recorded_by_impersonator_id" => %{default: nil, type: :bigint, nullable: true},
          "recorded_by_user_id" => %{default: nil, type: :bigint, nullable: false},
          "reverses_event_id" => %{default: nil, type: :bigint, nullable: true},
          "run_id" => %{default: nil, type: :bigint, nullable: true},
          "tenant_id" => %{default: nil, type: :bigint, nullable: false}
        },
        indexes: %{
          "finance_fixed_assets_events_disposal_reversal" => %{
            where: "(reverses_event_id IS NOT NULL)",
            columns: ["reverses_event_id"],
            unique: true
          },
          "finance_fixed_assets_events_void" => %{
            where: "((action)::text = 'acquisition_voided'::text)",
            columns: ["asset_id"],
            unique: true
          },
          "finance_fixed_assets_events_identity" => %{
            where: nil,
            columns: ["id", "tenant_id", "company_id"],
            unique: true
          },
          "finance_fixed_assets_events_number" => %{
            where: nil,
            columns: ["company_id", "event_number"],
            unique: true
          },
          "finance_fixed_assets_events_pkey" => %{where: nil, columns: ["id"], unique: true},
          "finance_fixed_assets_events_run_reversal" => %{
            where: "((action)::text = 'run_reversed'::text)",
            columns: ["run_id"],
            unique: true
          },
          "finance_fixed_assets_events_scope" => %{
            where: nil,
            columns: ["tenant_id", "company_id"],
            unique: false
          }
        },
        checks: %{
          "finance_fixed_assets_events_action_check" => %{
            expression:
              "action::text = ANY (ARRAY['run_reversed'::character varying, 'disposed'::character varying, 'disposal_reversed'::character varying, 'acquisition_voided'::character varying]::text[]"
          },
          "finance_fixed_assets_events_check" => %{
            expression:
              "action::text = 'run_reversed'::text AND run_id IS NOT NULL AND asset_id IS NULL AND reverses_event_id IS NULL AND proceeds IS NULL AND accumulated IS NULL OR action::text = 'disposed'::text AND asset_id IS NOT NULL AND run_id IS NULL AND reverses_event_id IS NULL AND proceeds IS NOT NULL AND accumulated IS NOT NULL AND proceeds >= 0::numeric AND accumulated >= 0::numeric OR action::text = 'disposal_reversed'::text AND asset_id IS NOT NULL AND run_id IS NULL AND reverses_event_id IS NOT NULL AND proceeds IS NULL AND accumulated IS NULL OR action::text = 'acquisition_voided'::text AND asset_id IS NOT NULL AND run_id IS NULL AND reverses_event_id IS NULL AND proceeds IS NULL AND accumulated IS NOT NULL AND accumulated >= 0::numeric"
          },
          "finance_fixed_assets_events_entry_check" => %{
            expression:
              "entry_id IS NOT NULL AND entry_number IS NOT NULL OR action::text = 'acquisition_voided'::text AND accumulated = 0::numeric AND entry_id IS NULL AND entry_number IS NULL"
          },
          "finance_fixed_assets_events_event_number_check" => %{expression: "event_number > 0"},
          "finance_fixed_assets_events_reason_check" => %{
            expression: "btrim(reason::text) <> ''::text"
          },
          "finance_fixed_assets_events_recorded_by_user_id_check" => %{
            expression: "recorded_by_user_id > 0"
          }
        },
        foreign_keys: %{
          "finance_fixed_assets_events_asset_id_tenant_id_company_id_fkey" => %{
            columns: ["asset_id", "tenant_id", "company_id"],
            references: {"finance_fixed_assets_assets", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict,
            on_update: :nothing
          },
          "finance_fixed_assets_events_reverses_event_id_tenant_id_co_fkey" => %{
            columns: ["reverses_event_id", "tenant_id", "company_id"],
            references: {"finance_fixed_assets_events", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict,
            on_update: :nothing
          },
          "finance_fixed_assets_events_run_id_tenant_id_company_id_fkey" => %{
            columns: ["run_id", "tenant_id", "company_id"],
            references: {"finance_fixed_assets_runs", ["id", "tenant_id", "company_id"]},
            on_delete: :restrict,
            on_update: :nothing
          }
        }
      }
    ]
end
