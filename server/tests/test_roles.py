from fastapi.testclient import TestClient

from app.main import app
from app.models import Employee, Role
from app.security import hash_password, hash_pin


def make_role(admin_client, name, perms):
    r = admin_client.post("/roles/new", data={"name": name, "perm": perms}, follow_redirects=False)
    assert r.status_code == 303, r.text
    return admin_client


def test_default_roles_seeded(db):
    keys = {r.key for r in db.query(Role)}
    assert {"cashier", "storekeeper", "supervisor", "admin"} <= keys
    assert db.get(Role, "admin").perms >= {"employees", "devices", "backup", "sale"}


def test_custom_role_limits_dashboard_pages(admin_client, db, seed):
    make_role(admin_client, "محاسب", ["dashboard", "sales"])
    role = db.query(Role).filter_by(name="محاسب").one()
    salt, h = hash_pin("5555")
    db.add(Employee(name="سامي", role=role.key, pin_salt=salt, pin_hash=h, username="sami",
                    password_hash=hash_password("password123")))
    db.commit()
    c = TestClient(app)
    assert c.post("/login", data={"username": "sami", "password": "password123"}, follow_redirects=False).status_code == 303
    home = c.get("/")
    assert home.status_code == 200
    assert 'href="/sales"' in home.text and 'href="/employees"' not in home.text and 'href="/products"' not in home.text and 'aria-current="page"' in home.text
    assert c.get("/sales").status_code == 200
    assert c.get("/reports").status_code == 200
    for page in ("/products", "/receipts", "/counts", "/employees", "/roles", "/devices", "/backup"):
        assert c.get(page).status_code == 403, page


def test_role_without_dashboard_cannot_log_in(admin_client, db, seed):
    make_role(admin_client, "بيع بس", ["sale", "price"])
    role = db.query(Role).filter_by(name="بيع بس").one()
    salt, h = hash_pin("5556")
    db.add(Employee(name="x", role=role.key, pin_salt=salt, pin_hash=h, username="x1", password_hash=hash_password("password123")))
    db.commit()
    r = TestClient(app).post("/login", data={"username": "x1", "password": "password123"}, follow_redirects=False)
    assert r.status_code == 400


def test_editing_role_reaches_devices(admin_client, device_client, db, seed):
    full = device_client.get("/api/v1/sync/pull?since=0").json()
    since = full["version"]
    cashier = next(e for e in full["employees"] if e["role"] == "cashier")
    assert set(cashier["permissions"]) == {"sale", "price", "see_cost"}
    assert cashier["role_name"] == "كاشير"
    r = admin_client.post("/roles/cashier", data={"name": "كاشير", "perm": ["sale", "price", "count"]}, follow_redirects=False)
    assert r.status_code == 303
    changed = device_client.get(f"/api/v1/sync/pull?since={since}").json()["employees"]
    assert [e["id"] for e in changed] == [seed["cashier"].id]
    assert set(changed[0]["permissions"]) == {"sale", "price", "count"}


def test_admin_role_is_fixed_and_roles_in_use_stay(admin_client, db, seed):
    admin_client.post("/roles/admin", data={"name": "x", "perm": ["sale"]})
    db.expire_all()
    assert db.get(Role, "admin").name == "مدير" and "backup" in db.get(Role, "admin").perms
    admin_client.post("/roles/cashier/delete")
    db.expire_all()
    assert db.get(Role, "cashier") is not None  # seed["cashier"] uses it
    admin_client.post("/roles/storekeeper/delete")
    db.expire_all()
    assert db.get(Role, "storekeeper") is None


def test_role_form_validation(admin_client, db, seed):
    assert admin_client.post("/roles/new", data={"name": "فاضي"}).status_code == 400  # no permissions
    assert admin_client.post("/roles/new", data={"name": "كاشير", "perm": ["sale"]}).status_code == 400  # duplicate name


def test_cannot_lock_yourself_out(db, seed):
    # A non-admin role that manages employees; its holder cannot strip that from their own role or account.
    db.add(Role(key="hr", name="شؤون", permissions="dashboard,employees"))
    salt, h = hash_pin("7777")
    hr = Employee(name="هبة", role="hr", pin_salt=salt, pin_hash=h, username="hr", password_hash=hash_password("password123"))
    db.add(hr)
    db.commit()
    c = TestClient(app)
    c.post("/login", data={"username": "hr", "password": "password123"})
    assert c.post("/roles/hr", data={"name": "شؤون", "perm": ["dashboard"]}).status_code == 400
    r = c.post(f"/employees/{hr.id}", data={"name": "هبة", "role": "cashier", "active": "1"})
    assert r.status_code == 400
    db.expire_all()
    assert db.get(Employee, hr.id).role == "hr"


def test_employee_form_lists_roles(admin_client, seed):
    page = admin_client.get("/employees/new").text
    assert 'value="storekeeper"' in page and 'data-dash="1"' in page
    assert admin_client.get("/roles").status_code == 200
    assert admin_client.get("/roles/cashier").status_code == 200
