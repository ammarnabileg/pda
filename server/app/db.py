from sqlalchemy import create_engine, text
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from . import config

engine = create_engine(config.DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def next_version(db) -> int:
    """Global, ever-increasing number used by devices to pull only what changed."""
    return db.execute(text("SELECT nextval('sync_version')")).scalar_one()


def init_db():
    from . import models  # noqa: F401  (register tables)

    with engine.begin() as conn:
        conn.execute(text("CREATE SEQUENCE IF NOT EXISTS sync_version"))
        conn.execute(text("CREATE SEQUENCE IF NOT EXISTS sale_no"))
        conn.execute(text("CREATE SEQUENCE IF NOT EXISTS count_no"))
        first_audit = conn.execute(text("SELECT to_regclass('audit_log') IS NULL")).scalar_one()
    Base.metadata.create_all(engine)
    # Columns added after the first release. create_all does not alter existing tables.
    with engine.begin() as conn:
        conn.execute(text("SELECT set_config('tamween.actor', 'system', true), "
                          "set_config('tamween.reason', 'ترقية قاعدة البيانات', true)"))
        for sql in UPGRADES:
            conn.execute(text(sql))
        for sql in KEEP_FOREVER:
            conn.execute(text(sql))
    seed_roles(add_accountant=first_audit)
    with engine.begin() as conn:
        conn.execute(text("CREATE INDEX IF NOT EXISTS audit_log_row ON audit_log (table_name, row_id)"))


def seed_roles(add_accountant=False):
    """The four starting roles, once. Afterwards roles are managed in the dashboard."""
    from .models import ADMIN_ROLE, DEFAULT_ROLES, Role

    with SessionLocal() as db:
        db.execute(text("SELECT set_config('tamween.actor', 'system', true)"))
        if db.get(Role, ADMIN_ROLE) is None and not db.query(Role).count():
            for key, name, perms in DEFAULT_ROLES:
                db.add(Role(key=key, name=name, permissions=",".join(sorted(perms))))
        elif db.get(Role, ADMIN_ROLE) is None:
            db.add(Role(key=ADMIN_ROLE, name="مدير", permissions=""))
        db.flush()
        # Databases from before the accounting permission get the accountant role once.
        if add_accountant and db.get(Role, "accountant") is None:
            key, name, perms = next(r for r in DEFAULT_ROLES if r[0] == "accountant")
            if not db.query(Role).filter(Role.name == name).count():
                db.add(Role(key=key, name=name, permissions=",".join(sorted(perms))))
        db.commit()


UPGRADES = [
    "ALTER TABLE receipt_lines ADD COLUMN IF NOT EXISTS note VARCHAR(200)",
    "ALTER TABLE receipts ADD COLUMN IF NOT EXISTS client_id VARCHAR(40)",
    "CREATE UNIQUE INDEX IF NOT EXISTS receipts_client_id ON receipts (client_id)",
    "ALTER TABLE receipts ADD COLUMN IF NOT EXISTS approved_by INTEGER REFERENCES employees(id)",
    "ALTER TABLE receipts ADD COLUMN IF NOT EXISTS approved_at TIMESTAMPTZ",
    """DO $$ BEGIN
         IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'audit_log' AND column_name = 'action'
                    AND character_maximum_length < 20) THEN
           ALTER TABLE audit_log ALTER COLUMN action TYPE VARCHAR(20);
         END IF;
       END $$""",
    "ALTER TABLE sales ADD COLUMN IF NOT EXISTS device_no INTEGER",
    "ALTER TABLE count_sessions ADD COLUMN IF NOT EXISTS device_no INTEGER",
    "ALTER TABLE count_sessions ADD COLUMN IF NOT EXISTS count_date DATE",
    "ALTER TABLE count_sessions ADD COLUMN IF NOT EXISTS committee VARCHAR(20)",
    "CREATE INDEX IF NOT EXISTS ix_count_sessions_count_date ON count_sessions (count_date)",
    *[stmt for table, seq, order in (("sales", "sale_no", "created_at, synced_at"),
                                     ("count_sessions", "count_no", "synced_at"))
      for stmt in (
        f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS no BIGINT",
        # Number records from before serial numbers existed, oldest first, once. The audit trigger is paused
        # for this one update (one log line per old invoice would bury the log); a single entry records it.
        f"""DO $$ DECLARE c bigint; BEGIN
              SELECT COUNT(*) INTO c FROM {table} WHERE no IS NULL;
              IF c > 0 THEN
                ALTER TABLE {table} DISABLE TRIGGER USER;
                UPDATE {table} t SET no = x.n FROM (
                  SELECT id, (SELECT COALESCE(MAX(no), 0) FROM {table}) + row_number() OVER (ORDER BY {order}) AS n
                  FROM {table} WHERE no IS NULL) x WHERE t.id = x.id;
                ALTER TABLE {table} ENABLE TRIGGER USER;
                IF to_regclass('audit_log') IS NOT NULL THEN
                  INSERT INTO audit_log (at, actor, reason, table_name, row_id, action, changes)
                  VALUES (clock_timestamp(), 'system', 'ترقية قاعدة البيانات', 'app', 'numbered', 'numbered',
                          jsonb_build_object('{table}', jsonb_build_array(NULL, c)));
                END IF;
              END IF;
            END $$""",
        # Move the sequence forward past existing numbers, never backwards.
        f"""SELECT setval('{seq}', m) FROM (SELECT MAX(no) AS m FROM {table}) x, {seq} s
            WHERE x.m IS NOT NULL AND x.m > CASE WHEN s.is_called THEN s.last_value ELSE s.last_value - 1 END""",
        # Only when not done yet: these lock the table, and SET NOT NULL reads every row.
        f"""DO $$ BEGIN
              IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = '{table}' AND column_name = 'no'
                         AND (is_nullable = 'YES' OR column_default IS NULL)) THEN
                ALTER TABLE {table} ALTER COLUMN no SET DEFAULT nextval('{seq}');
                ALTER TABLE {table} ALTER COLUMN no SET NOT NULL;
              END IF;
            END $$""",
        f"CREATE UNIQUE INDEX IF NOT EXISTS {table}_no ON {table} (no)",
      )],
    "ALTER TABLE products ADD COLUMN IF NOT EXISTS piece_name VARCHAR(12) NOT NULL DEFAULT 'حبة'",
    "ALTER TABLE products ADD COLUMN IF NOT EXISTS code VARCHAR(20)",
    "ALTER TABLE products ADD COLUMN IF NOT EXISTS supplier_id INTEGER REFERENCES suppliers(id)",
    "CREATE INDEX IF NOT EXISTS ix_products_supplier_id ON products (supplier_id)",
    "ALTER TABLE suppliers ADD COLUMN IF NOT EXISTS no INTEGER",
    "CREATE UNIQUE INDEX IF NOT EXISTS suppliers_no_key ON suppliers (no)",
    "CREATE UNIQUE INDEX IF NOT EXISTS products_code_key ON products (code)",
    "ALTER TABLE sales ADD COLUMN IF NOT EXISTS ministry_invoice_no VARCHAR(30)",
    "ALTER TABLE sales ADD COLUMN IF NOT EXISTS ministry_total NUMERIC(12, 3)",
    "CREATE INDEX IF NOT EXISTS ix_sales_ministry_invoice_no ON sales (ministry_invoice_no)",
    "ALTER TABLE receipts ADD COLUMN IF NOT EXISTS supplier_invoice_no VARCHAR(60)",
    "ALTER TABLE receipts ADD COLUMN IF NOT EXISTS supplier_invoice_total NUMERIC(12, 3)",
    "ALTER TABLE receipt_lines ADD COLUMN IF NOT EXISTS unit_cost NUMERIC(12, 3)",
    # The same supplier invoice cannot be recorded twice (a cancelled or rejected voucher frees its number).
    """CREATE UNIQUE INDEX IF NOT EXISTS receipts_supplier_invoice ON receipts (supplier_id, lower(supplier_invoice_no))
       WHERE supplier_invoice_no IS NOT NULL AND status NOT IN ('cancelled', 'rejected')""",
    "UPDATE count_sessions SET count_date = (finished_at AT TIME ZONE 'Asia/Kuwait')::date WHERE count_date IS NULL",
]


# Sales, vouchers, counts and stock moves are never deleted, whatever the code or a user tries.
# Enforced inside PostgreSQL so a bug, a new page or a manual DELETE cannot remove them.
# Only lines of a voucher that is still "open" (not received yet) may be replaced while editing it.
PROTECTED_TABLES = ["sales", "sale_lines", "receipts", "count_sessions", "count_lines", "stock_moves",
                    "receipt_files", "sale_files", "supplier_payments"]
# Every table with business data, and what is logged. Lines are logged when changed or removed; a new line
# is part of its parent's creation. stock_moves is itself a permanent log, so it is not copied.
AUDITED_TABLES = {
    "sales": "INSERT OR UPDATE OR DELETE", "sale_lines": "UPDATE OR DELETE",
    "receipts": "INSERT OR UPDATE OR DELETE", "receipt_lines": "UPDATE OR DELETE",
    "count_sessions": "INSERT OR UPDATE OR DELETE", "count_lines": "UPDATE OR DELETE",
    "products": "INSERT OR UPDATE OR DELETE", "product_barcodes": "INSERT OR UPDATE OR DELETE",
    "suppliers": "INSERT OR UPDATE OR DELETE", "employees": "INSERT OR UPDATE OR DELETE",
    "roles": "INSERT OR UPDATE OR DELETE", "devices": "INSERT OR UPDATE OR DELETE",
    "receipt_files": "INSERT OR UPDATE OR DELETE", "sale_files": "INSERT OR UPDATE OR DELETE",
    "supplier_payments": "INSERT OR UPDATE OR DELETE",
}
# Columns that change all the time on their own (stock has its own log in stock_moves; last_seen is the heartbeat).
AUDIT_NOISE = ["version", "stock", "last_seen", "updated_at"]
AUDIT_SECRET = ["pin_salt", "pin_hash", "password_hash", "token_hash", "pairing_code"]
KEEP_FOREVER = [
    """CREATE OR REPLACE FUNCTION tamween_no_delete() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'tamween: rows in % are never deleted', TG_TABLE_NAME USING ERRCODE = 'restrict_violation';
    END $$""",
    """CREATE OR REPLACE FUNCTION tamween_receipt_line_delete() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM receipts WHERE id = OLD.receipt_id AND status = 'open') THEN
        RETURN OLD;
      END IF;
      RAISE EXCEPTION 'tamween: lines of a closed voucher are never deleted' USING ERRCODE = 'restrict_violation';
    END $$""",
    """CREATE OR REPLACE FUNCTION tamween_read_only() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'tamween: rows in % are never changed or deleted', TG_TABLE_NAME USING ERRCODE = 'restrict_violation';
    END $$""",
    # Who changed what: one row per added, changed or removed record, with each column as [old, new].
    # Secrets are never copied into the log, only the fact that they changed.
    f"""CREATE OR REPLACE FUNCTION tamween_audit() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE o jsonb; n jsonb; ch jsonb;
      noise text[] := ARRAY{AUDIT_NOISE!r}::text[];
      secret text[] := ARRAY{AUDIT_SECRET!r}::text[];
    BEGIN
      IF TG_OP <> 'INSERT' THEN o := to_jsonb(OLD); END IF;
      IF TG_OP <> 'DELETE' THEN n := to_jsonb(NEW); END IF;
      SELECT jsonb_object_agg(key, CASE WHEN key = ANY(secret)
               THEN jsonb_build_array(CASE WHEN o ? key AND o -> key <> 'null' THEN '***' END,
                                      CASE WHEN n ? key AND n -> key <> 'null' THEN '***' END)
               ELSE jsonb_build_array(o -> key, n -> key) END) INTO ch
        FROM jsonb_object_keys(COALESCE(n, o)) AS key
       WHERE NOT key = ANY(noise) AND (o -> key) IS DISTINCT FROM (n -> key)
         AND NOT (TG_OP = 'INSERT' AND n -> key = 'null');
      IF ch IS NULL THEN RETURN NULL; END IF;
      INSERT INTO audit_log (at, actor, reason, table_name, row_id, action, changes)
      VALUES (clock_timestamp(), NULLIF(current_setting('tamween.actor', true), ''),
              NULLIF(current_setting('tamween.reason', true), ''), TG_TABLE_NAME,
              COALESCE(COALESCE(n, o) ->> 'id', COALESCE(n, o) ->> 'key'), TG_OP, ch);
      RETURN NULL;
    END $$""",
    # Line tables and their parents: changes and removals; a new line is part of its parent's creation.
    *[f"CREATE OR REPLACE TRIGGER {t}_audit AFTER {ops} ON {t} FOR EACH ROW EXECUTE FUNCTION tamween_audit()"
      for t, ops in AUDITED_TABLES.items()],
    "CREATE OR REPLACE TRIGGER audit_log_read_only BEFORE UPDATE OR DELETE ON audit_log FOR EACH ROW "
    "EXECUTE FUNCTION tamween_read_only()",
    "CREATE OR REPLACE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON audit_log FOR EACH STATEMENT "
    "EXECUTE FUNCTION tamween_read_only()",
    *[f"CREATE OR REPLACE TRIGGER {t}_no_delete BEFORE DELETE ON {t} FOR EACH ROW EXECUTE FUNCTION tamween_no_delete()"
      for t in PROTECTED_TABLES],
    *[f"CREATE OR REPLACE TRIGGER {t}_no_truncate BEFORE TRUNCATE ON {t} FOR EACH STATEMENT EXECUTE FUNCTION tamween_no_delete()"
      for t in PROTECTED_TABLES + ["receipt_lines"]],
    "CREATE OR REPLACE TRIGGER receipt_lines_no_delete BEFORE DELETE ON receipt_lines FOR EACH ROW "
    "EXECUTE FUNCTION tamween_receipt_line_delete()",
]
