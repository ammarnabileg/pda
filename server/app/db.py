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
        first_audit = conn.execute(text("SELECT to_regclass('audit_log') IS NULL")).scalar_one()
    Base.metadata.create_all(engine)
    # Columns added after the first release. create_all does not alter existing tables.
    with engine.begin() as conn:
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
]


# Sales, vouchers, counts and stock moves are never deleted, whatever the code or a user tries.
# Enforced inside PostgreSQL so a bug, a new page or a manual DELETE cannot remove them.
# Only lines of a voucher that is still "open" (not received yet) may be replaced while editing it.
PROTECTED_TABLES = ["sales", "sale_lines", "receipts", "count_sessions", "count_lines", "stock_moves"]
AUDITED_TABLES = ["sales", "sale_lines", "receipts", "receipt_lines", "count_sessions", "count_lines"]
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
    # Who changed what: one row per changed record, only the columns that changed, as [old, new].
    """CREATE OR REPLACE FUNCTION tamween_audit() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE o jsonb := to_jsonb(OLD); n jsonb; ch jsonb;
    BEGIN
      IF TG_OP = 'DELETE' THEN
        SELECT jsonb_object_agg(key, jsonb_build_array(value, NULL)) INTO ch FROM jsonb_each(o);
      ELSE
        n := to_jsonb(NEW);
        SELECT jsonb_object_agg(key, jsonb_build_array(o -> key, value)) INTO ch
          FROM jsonb_each(n) WHERE key <> 'version' AND (o -> key) IS DISTINCT FROM value;
        IF ch IS NULL THEN RETURN NULL; END IF;
      END IF;
      INSERT INTO audit_log (at, actor, reason, table_name, row_id, action, changes)
      VALUES (clock_timestamp(), NULLIF(current_setting('tamween.actor', true), ''),
              NULLIF(current_setting('tamween.reason', true), ''), TG_TABLE_NAME,
              COALESCE(n, o) ->> 'id', TG_OP, ch);
      RETURN NULL;
    END $$""",
    *[f"CREATE OR REPLACE TRIGGER {t}_audit AFTER UPDATE ON {t} FOR EACH ROW EXECUTE FUNCTION tamween_audit()"
      for t in AUDITED_TABLES if t != "receipt_lines"],
    "CREATE OR REPLACE TRIGGER receipt_lines_audit AFTER UPDATE OR DELETE ON receipt_lines FOR EACH ROW "
    "EXECUTE FUNCTION tamween_audit()",
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
