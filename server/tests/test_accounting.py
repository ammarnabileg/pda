import uuid
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from app.db import seed_roles
from app.main import app
from app.models import AuditLog, CountSession, Employee, Product, Receipt, Role, Sale
from app.security import hash_password, hash_pin


def push_sale(device_client, seed, qty=2):
    sid = str(uuid.uuid4())
    device_client.post("/api/v1/sync/push", json={"sales": [{"id": sid, "employee_id": seed["cashier"].id,
        "lines": [{"product_id": seed["rice"].id, "mode": "piece", "qty": qty, "unit_price": "2.450"}]}]})
    return sid


def login_as(db, role, username):
    salt, h = hash_pin(str(abs(hash(username)) % 9000 + 1000))
    e = Employee(name=username, role=role, pin_salt=salt, pin_hash=h, username=username, password_hash=hash_password("password123"))
    db.add(e)
    db.commit()
    c = TestClient(app)
    assert c.post("/login", data={"username": username, "password": "password123"}, follow_redirects=False).status_code == 303
    return c, e


def test_only_accounting_can_edit(db, seed, device_client):
    assert "accounting" in db.get(Role, "accountant").perms
    assert "accounting" not in db.get(Role, "supervisor").perms
    sid = push_sale(device_client, seed)
    sup, _ = login_as(db, "supervisor", "sup")
    assert sup.get(f"/sales/{sid}").status_code == 200
    assert "تعديل (المحاسبة)" not in sup.get(f"/sales/{sid}").text
    assert sup.get(f"/accounting/sales/{sid}").status_code == 403
    assert sup.post(f"/accounting/sales/{sid}", data={"reason": "x"}).status_code == 403
    assert sup.get("/accounting/log").status_code == 403
    acc, _ = login_as(db, "accountant", "acc")
    assert "تعديل (المحاسبة)" in acc.get(f"/sales/{sid}").text
    assert acc.get(f"/accounting/sales/{sid}").status_code == 200


def test_sale_edit_moves_stock_and_is_logged(db, seed, device_client):
    sid = push_sale(device_client, seed)
    db.expire_all()
    assert db.get(Product, seed["rice"].id).stock == Decimal("46")
    acc, accountant = login_as(db, "accountant", "acc")
    line_id = db.get(Sale, sid).lines[0].id
    # No reason: refused, nothing changes.
    r = acc.post(f"/accounting/sales/{sid}", data={f"q_{line_id}": "1", f"p_{line_id}": "2.000", "reason": ""})
    assert r.status_code == 400
    db.expire_all()
    assert db.get(Sale, sid).total == Decimal("4.900")
    r = acc.post(f"/accounting/sales/{sid}", data={f"q_{line_id}": "1", f"p_{line_id}": "2.000", "reason": "فاتورة ورقية"},
                 follow_redirects=False)
    assert r.status_code == 303
    db.expire_all()
    s = db.get(Sale, sid)
    assert (s.lines[0].qty, s.lines[0].unit_price, s.total) == (Decimal("1"), Decimal("2.000"), Decimal("2.000"))
    assert db.get(Product, seed["rice"].id).stock == Decimal("47")  # one piece back on the shelf
    logs = db.query(AuditLog).filter(AuditLog.table_name.in_(["sales", "sale_lines"])).all()
    assert {l.table_name for l in logs} == {"sales", "sale_lines"}
    line_log = next(l for l in logs if l.table_name == "sale_lines")
    assert line_log.actor == f"emp:{accountant.id}" and line_log.reason == "فاتورة ورقية"
    assert line_log.changes["qty"] == [2, 1]
    page = acc.get(f"/sales/{sid}").text
    assert "فاتورة ورقية" in page and "acc" in page
    log = acc.get("/accounting/log?manual=1").text
    assert "فاتورة ورقية" in log and f"/sales/{sid}" in log


def test_receipt_and_count_corrections(db, seed, device_client):
    rid = seed["receipt"].id
    device_client.post("/api/v1/sync/push", json={"receipts": [{"receipt_id": rid, "employee_id": seed["admin"].id,
        "lines": [{"product_id": seed["rice"].id, "mode": "carton", "qty": 9}]}]})
    db.expire_all()
    assert db.get(Product, seed["rice"].id).stock == Decimal("102")
    # The device's receiving was logged too, under the device.
    assert db.query(AuditLog).filter_by(table_name="receipts", row_id=str(rid)).first().actor == f"dev:{seed['device'].id}"
    acc, _ = login_as(db, "accountant", "acc")
    lid = db.get(Receipt, rid).lines[0].id
    r = acc.post(f"/accounting/receipts/{rid}", data={f"q_{lid}": "10", "reason": "كرتون اتلقى بعدين"}, follow_redirects=False)
    assert r.status_code == 303
    db.expire_all()
    assert db.get(Product, seed["rice"].id).stock == Decimal("108")
    assert db.get(Receipt, rid).lines[0].received == Decimal("10")

    cid = str(uuid.uuid4())
    device_client.post("/api/v1/sync/push", json={"counts": [{"id": cid, "employee_id": seed["admin"].id,
        "finished_at": "2026-11-01T09:00:00Z", "lines": [{"product_id": seed["rice"].id, "counted": 100}]}]})
    admin = TestClient(app)
    admin.post("/login", data={"username": "admin", "password": "password123"})
    admin.post(f"/counts/{cid}/approve")
    db.expire_all()
    assert db.get(Product, seed["rice"].id).stock == Decimal("100")
    clid = db.get(CountSession, cid).lines[0].id
    acc.post(f"/accounting/counts/{cid}", data={f"q_{clid}": "103", "reason": "رف تاني ماتعدش"})
    db.expire_all()
    assert db.get(Product, seed["rice"].id).stock == Decimal("103")
    assert db.get(CountSession, cid).lines[0].counted == Decimal("103")
    # A whole-piece product cannot get half a piece.
    r = acc.post(f"/accounting/counts/{cid}", data={f"q_{clid}": "2.5", "reason": "غلط"})
    assert r.status_code == 400


def test_audit_log_cannot_be_changed(db, seed, device_client, admin_client):
    sid = push_sale(device_client, seed)
    line_id = db.get(Sale, sid).lines[0].id
    admin_client.post(f"/accounting/sales/{sid}", data={f"q_{line_id}": "3", f"p_{line_id}": "2.450", "reason": "تصحيح"})
    assert db.query(AuditLog).count() > 0
    for sql in ("UPDATE audit_log SET reason = 'x'", "DELETE FROM audit_log", "TRUNCATE audit_log"):
        with pytest.raises(DBAPIError, match="never changed or deleted"):
            db.execute(text(sql))
        db.rollback()


def test_change_outside_the_app_is_logged_without_a_name(db, seed, device_client, admin_client):
    sid = push_sale(device_client, seed)
    db.execute(text("UPDATE sales SET total = 1 WHERE id = :id"), {"id": sid})
    db.commit()
    log = db.query(AuditLog).filter_by(table_name="sales", row_id=sid).one()
    assert log.actor is None
    assert "من خارج البرنامج" in admin_client.get(f"/sales/{sid}").text


def test_existing_database_gets_the_accountant_role_once(db):
    db.delete(db.get(Role, "accountant"))
    db.commit()
    seed_roles()
    assert db.get(Role, "accountant") is None  # an admin who deleted it on purpose keeps it deleted
    seed_roles(add_accountant=True)
    db.expire_all()
    assert db.get(Role, "accountant").name == "محاسب"
