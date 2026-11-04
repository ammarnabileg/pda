import os

os.environ["DATABASE_URL"] = os.environ.get(
    "TEST_DATABASE_URL", "postgresql+psycopg://postgres:postgres@localhost:5432/pda_test")
os.environ["SECRET_KEY"] = "test-secret"
import tempfile  # noqa: E402
os.environ["FILES_DIR"] = tempfile.mkdtemp(prefix="tamween-files-")

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app import services  # noqa: E402
from app.db import Base, SessionLocal, engine, init_db, seed_roles  # noqa: E402
from app.main import app  # noqa: E402
from app.models import Device, Employee, Product, Receipt, ReceiptLine, Supplier  # noqa: E402
from app.security import hash_password, hash_pin, hash_token  # noqa: E402


@pytest.fixture(scope="session", autouse=True)
def schema():
    Base.metadata.drop_all(engine)
    init_db()
    yield


@pytest.fixture(autouse=True)
def clean():
    yield
    with engine.begin() as c:
        names = ", ".join(t.name for t in Base.metadata.sorted_tables)
        # Tests only: the keep-forever triggers would (rightly) refuse this.
        c.execute(text("SET LOCAL session_replication_role = replica"))
        c.execute(text(f"TRUNCATE {names} RESTART IDENTITY CASCADE"))
    seed_roles()


@pytest.fixture
def db():
    s = SessionLocal()
    yield s
    s.close()


@pytest.fixture
def seed(db):
    def emp(name, role, pin, username=None, password=None):
        salt, h = hash_pin(pin)
        e = Employee(name=name, role=role, pin_salt=salt, pin_hash=h, username=username,
                     password_hash=hash_password(password) if password else None)
        services.bump(db, e)
        db.add(e)
        return e

    admin = emp("المدير", "admin", "1111", "admin", "password123")
    cashier = emp("أحمد", "cashier", "2222")
    rice = Product(barcode="6281000123456", name="أرز", unit="piece", price=2.45, cost=2.05, carton=6, stock=48)
    sugar = Product(barcode="2100000012345", name="سكر", unit="kg", price=0.35, cost=0.28, carton=0, stock=125)
    for p in (rice, sugar):
        services.bump(db, p)
        db.add(p)
    dev = Device(name="كاشير 1", token_hash=hash_token("tok-1"))
    sup = Supplier(name="مورد")
    db.add_all([dev, sup])
    db.flush()
    r = Receipt(supplier_id=sup.id)
    r.lines.append(ReceiptLine(product_id=rice.id, mode="carton", ordered=10))
    services.bump(db, r)
    db.add(r)
    db.commit()
    return {"admin": admin, "cashier": cashier, "rice": rice, "sugar": sugar, "device": dev, "receipt": r, "supplier": sup}


@pytest.fixture
def client():
    return TestClient(app)


@pytest.fixture
def device_client(client):
    client.headers["Authorization"] = "Bearer tok-1"
    return client


@pytest.fixture
def admin_client(client, seed):
    r = client.post("/login", data={"username": "admin", "password": "password123"}, follow_redirects=False)
    assert r.status_code == 303
    return client
