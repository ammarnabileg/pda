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
    Base.metadata.create_all(engine)
    # Columns added after the first release. create_all does not alter existing tables.
    with engine.begin() as conn:
        for sql in UPGRADES:
            conn.execute(text(sql))
        for sql in KEEP_FOREVER:
            conn.execute(text(sql))
    seed_roles()


def seed_roles():
    """The four starting roles, once. Afterwards roles are managed in the dashboard."""
    from .models import ADMIN_ROLE, DEFAULT_ROLES, Role

    with SessionLocal() as db:
        if db.get(Role, ADMIN_ROLE) is None and not db.query(Role).count():
            for key, name, perms in DEFAULT_ROLES:
                db.add(Role(key=key, name=name, permissions=",".join(sorted(perms))))
        elif db.get(Role, ADMIN_ROLE) is None:
            db.add(Role(key=ADMIN_ROLE, name="مدير", permissions=""))
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
    *[f"CREATE OR REPLACE TRIGGER {t}_no_delete BEFORE DELETE ON {t} FOR EACH ROW EXECUTE FUNCTION tamween_no_delete()"
      for t in PROTECTED_TABLES],
    *[f"CREATE OR REPLACE TRIGGER {t}_no_truncate BEFORE TRUNCATE ON {t} FOR EACH STATEMENT EXECUTE FUNCTION tamween_no_delete()"
      for t in PROTECTED_TABLES + ["receipt_lines"]],
    "CREATE OR REPLACE TRIGGER receipt_lines_no_delete BEFORE DELETE ON receipt_lines FOR EACH ROW "
    "EXECUTE FUNCTION tamween_receipt_line_delete()",
]
