import uuid
from datetime import date
from decimal import Decimal

from sqlalchemy import text

from app.db import init_db
from app.models import AuditLog, CountSession, Product, Sale


def sale(device_client, seed, device_no=None, created="2026-11-01T10:00:00+03:00"):
    sid = str(uuid.uuid4())
    body = {"id": sid, "employee_id": seed["cashier"].id, "created_at": created,
            "lines": [{"product_id": seed["rice"].id, "mode": "piece", "qty": 1, "unit_price": "2.450"}]}
    if device_no:
        body["device_no"] = device_no
    device_client.post("/api/v1/sync/push", json={"sales": [body]})
    return sid


def count(device_client, seed, committee, counted, day="2026-11-03", product="rice"):
    cid = str(uuid.uuid4())
    device_client.post("/api/v1/sync/push", json={"counts": [{"id": cid, "employee_id": seed["admin"].id,
        "finished_at": "2026-11-03T09:00:00Z", "count_date": day, "committee": committee, "device_no": 4,
        "lines": [{"product_id": seed[product].id, "counted": counted}]}]})
    return cid


def test_invoices_get_serial_numbers(device_client, seed, db, admin_client):
    a, b = sale(device_client, seed, device_no=57), sale(device_client, seed)
    sa, sb = db.get(Sale, a), db.get(Sale, b)
    assert sb.no == sa.no + 1 and sa.device_no == 57 and sb.device_no is None
    page = admin_client.get(f"/sales/{a}").text
    assert f"فاتورة رقم {sa.no}" in page and "#57" in page
    assert f"فاتورة {sa.no}" in admin_client.get("/sales?d_from=2026-11-01&d_to=2026-11-01").text
    assert f"فاتورة {sa.no}" in admin_client.get(f"/products/{seed['rice'].id}").text  # stock moves


def test_old_records_are_numbered_once_on_upgrade(device_client, seed, db):
    late, early = sale(device_client, seed, created="2026-11-02T10:00:00+03:00"), sale(device_client, seed)
    with db.begin_nested():
        db.execute(text("ALTER TABLE sales ALTER COLUMN no DROP NOT NULL"))
        db.execute(text("ALTER TABLE sales DISABLE TRIGGER USER"))
        db.execute(text("UPDATE sales SET no = NULL"))
        db.execute(text("ALTER TABLE sales ENABLE TRIGGER USER"))
    db.commit()
    before = db.query(AuditLog).count()
    db.commit()  # release our read locks: the upgrade alters the table
    init_db()
    db.expire_all()
    assert (db.get(Sale, early).no, db.get(Sale, late).no) == (1, 2)  # oldest first
    assert db.query(AuditLog).count() == before + 1  # one "numbered" entry, not one per invoice
    assert db.get(Sale, sale(device_client, seed)).no > 2  # the sequence carries on, never back to used numbers


def test_count_date_and_committee(device_client, seed, db, admin_client):
    cid = count(device_client, seed, "3", 45)
    c = db.get(CountSession, cid)
    assert (c.count_date, c.committee, c.device_no) == (date(2026, 11, 3), "3", 4)
    page = admin_client.get("/counts").text
    assert "جرد يوم 2026-11-03" in page and f"جرد {c.no}" in page
    # Old app without the fields: the date comes from when the count finished (Kuwait time).
    old = str(uuid.uuid4())
    device_client.post("/api/v1/sync/push", json={"counts": [{"id": old, "finished_at": "2026-11-03T22:30:00Z",
        "lines": [{"product_id": seed["sugar"].id, "counted": 1}]}]})
    assert db.get(CountSession, old).count_date == date(2026, 11, 4)


def test_two_committees_on_one_product_add_up(device_client, seed, db, admin_client):
    c1, c2 = count(device_client, seed, "1", 30), count(device_client, seed, "2", 20)
    # Approving one alone would set stock to 30 and then to 20: refused.
    r = admin_client.post(f"/counts/{c1}/approve", follow_redirects=False)
    assert r.headers["location"] == "/counts/day/2026-11-03"
    db.expire_all()
    assert db.get(CountSession, c1).status == "submitted"
    page = admin_client.get("/counts/day/2026-11-03").text
    assert "لجنة 1: 30" in page and "لجنة 2: 20" in page
    admin_client.post("/counts/day/2026-11-03/approve")
    db.expire_all()
    assert db.get(Product, seed["rice"].id).stock == Decimal("50")
    assert {db.get(CountSession, c).status for c in (c1, c2)} == {"approved"}
    # A third committee that recounts an already approved product is not added silently.
    count(device_client, seed, "4", 5)
    admin_client.post("/counts/day/2026-11-03/approve")
    db.expire_all()
    assert db.get(Product, seed["rice"].id).stock == Decimal("50")


def test_separate_products_can_still_be_approved_alone(device_client, seed, db, admin_client):
    c1, c2 = count(device_client, seed, "1", 40), count(device_client, seed, "2", 100, product="sugar")
    admin_client.post(f"/counts/{c1}/approve")
    db.expire_all()
    assert db.get(CountSession, c1).status == "approved"
    assert db.get(Product, seed["rice"].id).stock == Decimal("40")


def test_price_log(admin_client, db, seed):
    rice = seed["rice"]
    form = {"name": "أرز", "barcode": rice.barcode, "unit": "piece", "carton": "6", "cost": "2.050", "min_stock": "0", "active": "1"}
    admin_client.post(f"/products/{rice.id}", data={**form, "price": "2.600"})
    admin_client.post(f"/products/{rice.id}", data={**form, "price": "2.500", "cost": "2.100"})
    page = admin_client.get("/prices").text
    assert "2.450 → <b>2.600</b>" in page and "2.600 → <b>2.500</b>" in page and "2.050 → <b>2.100</b>" in page
    assert "+6.1%" in page
    assert "2.600 → <b>2.500</b>" in admin_client.get(f"/products/{rice.id}").text
    assert "2.600" not in admin_client.get("/prices?q=سكر").text
    csv = admin_client.get("/prices?format=csv")
    assert csv.headers["content-type"].startswith("text/csv") and "2.500" in csv.text
