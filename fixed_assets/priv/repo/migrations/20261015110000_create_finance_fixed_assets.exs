defmodule Bilimbi.Finance.FixedAssets.Migrations.CreateFixedAssets do
  @moduledoc """
  Bilimbi-only, permanently retained fixed asset records. Category changes are
  new revisions. Assets, monthly runs with their items and exceptions, disposals,
  voided acquisitions and reversals are immutable. PostgreSQL stamps actors' records, numbers assets and events
  per company under a transaction lock, and refuses updates, deletes and truncation.
  Tests build temporary tables from these same statements.
  """
  use Ecto.Migration

  @tables ~w(categories category_revisions assets runs run_items run_exceptions events)
  def up, do: Enum.each(statements(), &execute/1)

  def down do
    for name <- Enum.reverse(@tables), do: execute("DROP TABLE finance_fixed_assets_#{name}")

    for name <- ~w(stamp refuse item check_run event),
        do: execute("DROP FUNCTION finance_fixed_assets_#{name}()")
  end

  def statements(options \\ []) do
    temp = Keyword.get(options, :temporary, false)
    table = if temp, do: "TEMPORARY TABLE", else: "TABLE"
    prefix = if temp, do: "pg_temp.", else: ""

    common =
      "tenant_id bigint NOT NULL, company_id bigint NOT NULL, recorded_by_user_id bigint NOT NULL CHECK (recorded_by_user_id > 0), recorded_by_impersonator_id bigint, recorded_at timestamp(6) NOT NULL"

    definitions = [
      {"categories", "name varchar(200) NOT NULL CHECK (btrim(name) <> '')"},
      {"category_revisions",
       """
         category_id bigint NOT NULL,
         cost_account_id bigint NOT NULL, accumulated_account_id bigint NOT NULL,
         expense_account_id bigint NOT NULL, gain_account_id bigint NOT NULL, loss_account_id bigint NOT NULL,
         method varchar(20) NOT NULL CHECK (method IN ('straight_line', 'reducing_balance')),
         life_months integer NOT NULL CHECK (life_months BETWEEN 1 AND 1200),
         annual_rate numeric(7,4), reason varchar(500) NOT NULL CHECK (btrim(reason) <> ''),
         CHECK ((method = 'straight_line' AND annual_rate IS NULL) OR (method = 'reducing_balance' AND annual_rate > 0 AND annual_rate <= 100)),
         FOREIGN KEY (category_id, tenant_id, company_id) REFERENCES finance_fixed_assets_categories (id, tenant_id, company_id) ON DELETE RESTRICT
       """},
      {"assets",
       """
         asset_number bigint NOT NULL CHECK (asset_number > 0), category_revision_id bigint NOT NULL,
         description varchar(500) NOT NULL CHECK (btrim(description) <> ''),
         acquisition_date date NOT NULL, in_service_date date NOT NULL CHECK (in_service_date >= acquisition_date),
         cost numeric(20,4) NOT NULL CHECK (cost > 0), residual_value numeric(20,4) NOT NULL CHECK (residual_value >= 0 AND residual_value <= cost),
         method varchar(20) NOT NULL CHECK (method IN ('straight_line', 'reducing_balance')),
         life_months integer NOT NULL CHECK (life_months BETWEEN 1 AND 1200), annual_rate numeric(7,4),
         entry_id bigint NOT NULL, entry_number bigint NOT NULL, entry_line_number integer NOT NULL CHECK (entry_line_number > 0),
         bill_id bigint, bill_line_number integer,
         CHECK ((bill_id IS NULL AND bill_line_number IS NULL) OR (bill_id > 0 AND bill_line_number > 0)),
         CHECK ((method = 'straight_line' AND annual_rate IS NULL) OR (method = 'reducing_balance' AND annual_rate > 0 AND annual_rate <= 100)),
         FOREIGN KEY (category_revision_id, tenant_id, company_id) REFERENCES finance_fixed_assets_category_revisions (id, tenant_id, company_id) ON DELETE RESTRICT
       """},
      {"runs",
       """
         period date NOT NULL CHECK (extract(day FROM period) = 1),
         entry_id bigint, entry_number bigint, total numeric(20,4) NOT NULL CHECK (total >= 0),
         CHECK ((total = 0 AND entry_id IS NULL AND entry_number IS NULL) OR (total > 0 AND entry_id IS NOT NULL AND entry_number IS NOT NULL))
       """},
      {"run_items",
       """
         run_id bigint NOT NULL, asset_id bigint NOT NULL, amount numeric(20,4) NOT NULL CHECK (amount > 0),
         FOREIGN KEY (run_id, tenant_id, company_id) REFERENCES finance_fixed_assets_runs (id, tenant_id, company_id) ON DELETE RESTRICT,
         FOREIGN KEY (asset_id, tenant_id, company_id) REFERENCES finance_fixed_assets_assets (id, tenant_id, company_id) ON DELETE RESTRICT
       """},
      {"run_exceptions",
       """
         run_id bigint NOT NULL, asset_id bigint NOT NULL,
         FOREIGN KEY (run_id, tenant_id, company_id) REFERENCES finance_fixed_assets_runs (id, tenant_id, company_id) ON DELETE RESTRICT,
         FOREIGN KEY (asset_id, tenant_id, company_id) REFERENCES finance_fixed_assets_assets (id, tenant_id, company_id) ON DELETE RESTRICT
       """},
      {"events",
       """
         event_number bigint NOT NULL CHECK (event_number > 0), asset_id bigint, run_id bigint,
         action varchar(20) NOT NULL CHECK (action IN ('run_reversed', 'disposed', 'disposal_reversed', 'acquisition_voided')),
         effective_date date NOT NULL, entry_id bigint, entry_number bigint,
         reverses_event_id bigint, proceeds numeric(20,4), accumulated numeric(20,4),
         reason varchar(500) NOT NULL CHECK (btrim(reason) <> ''),
         CHECK ((action = 'run_reversed' AND run_id IS NOT NULL AND asset_id IS NULL AND reverses_event_id IS NULL AND proceeds IS NULL AND accumulated IS NULL)
           OR (action = 'disposed' AND asset_id IS NOT NULL AND run_id IS NULL AND reverses_event_id IS NULL AND proceeds IS NOT NULL AND accumulated IS NOT NULL AND proceeds >= 0 AND accumulated >= 0)
           OR (action = 'disposal_reversed' AND asset_id IS NOT NULL AND run_id IS NULL AND reverses_event_id IS NOT NULL AND proceeds IS NULL AND accumulated IS NULL)
           OR (action = 'acquisition_voided' AND asset_id IS NOT NULL AND run_id IS NULL AND reverses_event_id IS NULL AND proceeds IS NULL AND accumulated IS NOT NULL AND accumulated >= 0)),
         CONSTRAINT finance_fixed_assets_events_entry_check CHECK ((entry_id IS NOT NULL AND entry_number IS NOT NULL) OR (action = 'acquisition_voided' AND accumulated = 0 AND entry_id IS NULL AND entry_number IS NULL)),
         FOREIGN KEY (run_id, tenant_id, company_id) REFERENCES finance_fixed_assets_runs (id, tenant_id, company_id) ON DELETE RESTRICT,
         FOREIGN KEY (asset_id, tenant_id, company_id) REFERENCES finance_fixed_assets_assets (id, tenant_id, company_id) ON DELETE RESTRICT,
         FOREIGN KEY (reverses_event_id, tenant_id, company_id) REFERENCES finance_fixed_assets_events (id, tenant_id, company_id) ON DELETE RESTRICT
       """}
    ]

    tables =
      Enum.flat_map(definitions, fn {name, columns} ->
        name = "finance_fixed_assets_#{name}"

        [
          "CREATE #{table} #{name} (id bigserial PRIMARY KEY, #{common}, CONSTRAINT #{name}_identity UNIQUE (id, tenant_id, company_id), #{columns})",
          "CREATE INDEX #{name}_scope ON #{name} (tenant_id, company_id)"
        ]
      end)

    indexes = [
      "CREATE UNIQUE INDEX finance_fixed_assets_categories_name ON finance_fixed_assets_categories (company_id, name)",
      "CREATE UNIQUE INDEX finance_fixed_assets_assets_number ON finance_fixed_assets_assets (company_id, asset_number)",
      "CREATE UNIQUE INDEX finance_fixed_assets_assets_source ON finance_fixed_assets_assets (company_id, entry_id, entry_line_number)",
      "CREATE UNIQUE INDEX finance_fixed_assets_runs_period ON finance_fixed_assets_runs (company_id, period)",
      "CREATE UNIQUE INDEX finance_fixed_assets_run_items_asset ON finance_fixed_assets_run_items (run_id, asset_id)",
      "CREATE UNIQUE INDEX finance_fixed_assets_run_exceptions_asset ON finance_fixed_assets_run_exceptions (run_id, asset_id)",
      "CREATE UNIQUE INDEX finance_fixed_assets_events_number ON finance_fixed_assets_events (company_id, event_number)",
      "CREATE UNIQUE INDEX finance_fixed_assets_events_run_reversal ON finance_fixed_assets_events (run_id) WHERE action = 'run_reversed'",
      "CREATE UNIQUE INDEX finance_fixed_assets_events_void ON finance_fixed_assets_events (asset_id) WHERE action = 'acquisition_voided'",
      "CREATE UNIQUE INDEX finance_fixed_assets_events_disposal_reversal ON finance_fixed_assets_events (reverses_event_id) WHERE reverses_event_id IS NOT NULL"
    ]

    functions = [
      """
      CREATE FUNCTION #{prefix}finance_fixed_assets_check_run() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE amount numeric;
      BEGIN
        SELECT coalesce(sum(i.amount), 0) INTO amount FROM finance_fixed_assets_run_items i WHERE i.run_id = NEW.id;
        IF amount <> NEW.total THEN RAISE EXCEPTION 'fixed asset run total differs from items'; END IF;
        RETURN NULL;
      END $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_fixed_assets_event() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE previous_action text; original_date date;
      BEGIN
        IF NEW.action = 'disposed' THEN
          SELECT action INTO previous_action FROM finance_fixed_assets_events WHERE asset_id = NEW.asset_id ORDER BY event_number DESC LIMIT 1;
          IF previous_action = 'disposed' THEN RAISE EXCEPTION 'fixed asset already disposed'; END IF;
          IF EXISTS (SELECT 1 FROM finance_fixed_assets_events WHERE asset_id = NEW.asset_id AND action = 'acquisition_voided') THEN RAISE EXCEPTION 'fixed asset acquisition voided'; END IF;
        ELSIF NEW.action = 'acquisition_voided' THEN
          SELECT action INTO previous_action FROM finance_fixed_assets_events WHERE asset_id = NEW.asset_id ORDER BY event_number DESC LIMIT 1;
          IF previous_action = 'disposed' THEN RAISE EXCEPTION 'fixed asset acquisition void is invalid'; END IF;
        ELSIF NEW.action = 'disposal_reversed' THEN
          SELECT action INTO previous_action FROM finance_fixed_assets_events WHERE asset_id = NEW.asset_id ORDER BY event_number DESC LIMIT 1;
          IF previous_action IS DISTINCT FROM 'disposed' OR NOT EXISTS (
            SELECT 1 FROM finance_fixed_assets_events WHERE id = NEW.reverses_event_id AND asset_id = NEW.asset_id AND action = 'disposed' AND effective_date <= NEW.effective_date
          ) THEN RAISE EXCEPTION 'fixed asset disposal reversal is invalid'; END IF;
        ELSE
          SELECT (period + interval '1 month' - interval '1 day')::date INTO original_date FROM finance_fixed_assets_runs WHERE id = NEW.run_id AND entry_id IS NOT NULL;
          IF original_date IS NULL OR NEW.effective_date < original_date THEN RAISE EXCEPTION 'fixed asset run reversal is invalid'; END IF;
        END IF;
        RETURN NEW;
      END $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_fixed_assets_refuse() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'fixed assets retain every record permanently'; END $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_fixed_assets_stamp() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(NEW.company_id);
        NEW.recorded_at := clock_timestamp() AT TIME ZONE 'UTC';
        IF TG_TABLE_NAME = 'finance_fixed_assets_assets' THEN
          SELECT coalesce(max(asset_number), 0) + 1 INTO NEW.asset_number FROM finance_fixed_assets_assets WHERE company_id = NEW.company_id;
        ELSIF TG_TABLE_NAME = 'finance_fixed_assets_events' THEN
          SELECT coalesce(max(event_number), 0) + 1 INTO NEW.event_number FROM finance_fixed_assets_events WHERE company_id = NEW.company_id;
        END IF;
        RETURN NEW;
      END $$
      """,
      """
      CREATE FUNCTION #{prefix}finance_fixed_assets_item() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM finance_fixed_assets_runs WHERE id = NEW.run_id AND pg_xact_status(((pg_current_xact_id()::text::bigint >> 32 << 32) | xmin::text::bigint)::text::xid8) = 'in progress') THEN
          RAISE EXCEPTION 'fixed asset run already recorded';
        END IF;
        RETURN NEW;
      END $$
      """
    ]

    triggers =
      Enum.flat_map(@tables, fn suffix ->
        name = "finance_fixed_assets_#{suffix}"

        [
          "CREATE TRIGGER #{name}_immutable BEFORE UPDATE OR DELETE ON #{name} FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_fixed_assets_refuse()",
          "CREATE TRIGGER #{name}_retain BEFORE TRUNCATE ON #{name} FOR EACH STATEMENT EXECUTE FUNCTION #{prefix}finance_fixed_assets_refuse()",
          "CREATE TRIGGER #{name}_stamp BEFORE INSERT ON #{name} FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_fixed_assets_stamp()"
        ]
      end)

    tables ++
      indexes ++
      functions ++
      triggers ++
      [
        "CREATE TRIGGER finance_fixed_assets_run_items_closed BEFORE INSERT ON finance_fixed_assets_run_items FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_fixed_assets_item()",
        "CREATE TRIGGER finance_fixed_assets_run_exceptions_closed BEFORE INSERT ON finance_fixed_assets_run_exceptions FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_fixed_assets_item()",
        "CREATE CONSTRAINT TRIGGER finance_fixed_assets_runs_total AFTER INSERT ON finance_fixed_assets_runs DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_fixed_assets_check_run()",
        "CREATE TRIGGER finance_fixed_assets_events_transition BEFORE INSERT ON finance_fixed_assets_events FOR EACH ROW EXECUTE FUNCTION #{prefix}finance_fixed_assets_event()"
      ]
  end
end
