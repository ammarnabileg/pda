from fastapi.testclient import TestClient

from app.main import app
from app.models import AuditLog, Device, Employee
from tests.test_accounting import login_as


def entries(db, **kw):
    return db.query(AuditLog).filter_by(**kw).order_by(AuditLog.id).all()


def test_price_change_is_logged_on_the_product(admin_client, db, seed):
    rice = seed["rice"]
    r = admin_client.post(f"/products/{rice.id}", data={"name": "أرز", "barcode": rice.barcode, "unit": "piece", "carton": "6",
                                                       "price": "2.600", "cost": "2.050", "min_stock": "0", "active": "1"},
                          follow_redirects=False)
    assert r.status_code == 303
    log = entries(db, table_name="products", row_id=str(rice.id), action="UPDATE")[-1]
    assert log.actor == f"emp:{seed['admin'].id}"
    assert log.changes["price"] == [2.45, 2.6]
    page = admin_client.get(f"/products/{rice.id}").text
    assert "سعر البيع" in page and "2.600" in page


def test_secrets_never_reach_the_log(admin_client, db, seed):
    cashier = seed["cashier"]
    old_hash = cashier.pin_hash
    admin_client.post(f"/employees/{cashier.id}", data={"name": "أحمد", "role": "cashier", "pin": "4321", "active": "1"})
    log = entries(db, table_name="employees", row_id=str(cashier.id), action="UPDATE")[-1]
    assert log.changes["pin_hash"] == ["***", "***"]
    dump = str([e.changes for e in db.query(AuditLog)])
    db.expire_all()
    assert old_hash not in dump and db.get(Employee, cashier.id).pin_hash not in dump


def test_logins_roles_and_devices_are_logged(client, db, seed):
    client.post("/login", data={"username": "admin", "password": "wrong-password"})
    client.post("/login", data={"username": "admin", "password": "password123"})
    client.post("/roles/cashier", data={"name": "كاشير", "perm": ["sale"]})
    client.post("/devices", data={"name": "جهاز المخزن"})
    client.post("/logout")
    acts = [e.action for e in entries(db, table_name="app")]
    assert acts == ["login_failed", "login", "logout"]
    assert entries(db, table_name="roles", row_id="cashier", action="UPDATE")[-1].changes["permissions"][1] == "sale"
    assert entries(db, table_name="devices", action="INSERT")[-1].changes["name"] == [None, "جهاز المخزن"]


def test_device_heartbeat_and_stock_are_not_noise(device_client, db, seed):
    n = db.query(AuditLog).count()
    dev = db.get(Device, seed["device"].id)
    dev.last_seen = None
    db.commit()
    device_client.get("/api/v1/sync/pull?since=0")  # updates last_seen
    assert db.query(AuditLog).count() == n


def test_full_log_needs_audit_permission(db, seed, admin_client):
    acc, _ = login_as(db, "accountant", "acc")
    page = acc.get("/log").text
    assert "الفواتير" in page and "الدخول والنسخ الاحتياطي" not in page
    assert acc.get("/log?what=app").status_code == 200
    assert "دخول اللوحة" not in acc.get("/log?what=app").text  # falls back to the groups it may see
    full = admin_client.get("/log?what=app").text
    assert "دخول اللوحة" in full
    cashier = TestClient(app)
    assert cashier.get("/log", follow_redirects=False).status_code == 303  # not logged in
