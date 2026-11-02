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


UPGRADES = [
    "ALTER TABLE receipt_lines ADD COLUMN IF NOT EXISTS note VARCHAR(200)",
]
