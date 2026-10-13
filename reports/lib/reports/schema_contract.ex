defmodule Bilimbi.Finance.Reports.SchemaContract do
  @moduledoc "Fresh issued-report contract; not registered for pre-migration adoption."
  @behaviour Bilimbi.Base.Database.SchemaContract
  def tables do
    [
      %{
        name: "finance_reports_issued",
        columns: %{
          "id" => column(:bigint, false, {:sequence, "finance_reports_issued_id_seq"}),
          "tenant_id" => column(:bigint, false),
          "company_id" => column(:bigint, false),
          "kind" => column({:varchar, 40}, false),
          "implementation_version" => column({:varchar, 40}, false),
          "through_entry_number" => column(:bigint, false),
          "content" => column(:jsonb, false),
          "chart" => column(:jsonb, false),
          "layout" => column(:jsonb, false),
          "membership" => column(:jsonb, false),
          "issued_by_user_id" => column(:bigint, false),
          "issued_by_impersonator_id" => column(:bigint, true),
          "issued_at" => column({:timestamp, 6}, false)
        },
        indexes: %{
          "finance_reports_issued_pkey" => index(["id"], true),
          "finance_reports_issued_scope" => index(["tenant_id", "company_id", "id"], false)
        },
        foreign_keys: %{},
        checks: %{
          "finance_reports_issued_cutoff" => %{
            expression: "through_entry_number >= 0",
            validated: true
          }
        }
      }
    ]
  end

  def verify_invariants(_repo, _opts), do: :ok

  defp column(type, nullable, default \\ nil),
    do: %{type: type, nullable: nullable, default: default}

  defp index(columns, unique), do: %{columns: columns, unique: unique, where: nil}
end
