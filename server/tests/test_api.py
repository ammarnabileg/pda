import uuid
from decimal import Decimal

from app.models import CountSession, Device, Product, Receipt, Sale, StockMove
from app.security import verify_pin


def test_unpaired_device_is_rejected(client, seed):
    assert client.get("/api/v1/sync/pull").status_code == 401
    client.headers["Authorization"] = "Bearer wrong"
    assert client.get("/api/v1/sync/pull").status_code == 401


def test_pairing_flow(client, admin_client, db):
    admin_client.post("/devices", data={"name": "مخزن"})
    dev = db.query(Device).filter_by(name="مخزن").one()
    assert client.post("/api/v1/pair", json={"code": "000000x"}).status_code == 400
    r = client.post("/api/v1/pair", json={"code": dev.pairing_code, "app_version": "1.0"})
    assert r.status_code == 200
    token = r.json()["token"]
    # The code works once only.
    assert client.post("/api/v1/pair", json={"code": dev.pairing_code}).status_code == 400
    client.headers["Authorization"] = f"Bearer {token}"
    assert client.get("/api/v1/sync/pull").status_code == 200


def test_pull_full_then_incremental(device_client, seed, db):
    r = device_client.get("/api/v1/sync/pull?since=0").json()
    assert {p["barcode"] for p in r["products"]} == {"6281000123456", "2100000012345"}
    assert len(r["employees"]) == 2 and len(r["receipts"]) == 1
    assert r["products"][0]["cost"] in ("2.050", "0.280")  # purchase price is shown on devices
    emp = next(e for e in r["employees"] if e["name"] == "أحمد")
    assert verify_pin("2222", emp["pin_salt"], emp["pin_hash"])
    v = r["version"]
    assert device_client.get(f"/api/v1/sync/pull?since={v}").json()["products"] == []
    rice = db.get(Product, seed["rice"].id)
    rice.price = Decimal("2.500")
    from app import services
    services.bump(db, rice)
    db.commit()
    r2 = device_client.get(f"/api/v1/sync/pull?since={v}").json()
    assert [p["price"] for p in r2["products"]] == ["2.500"]


def sale_payload(seed, sid=None):
    return {"sales": [{"id": sid or str(uuid.uuid4()), "employee_id": seed["cashier"].id,
                       "created_at": "2026-11-01T10:00:00+03:00",
                       "lines": [{"product_id": seed["rice"].id, "mode": "piece", "qty": 2, "unit_price": "2.450"},
                                 {"product_id": seed["rice"].id, "mode": "carton", "qty": 1, "unit_price": "14.700"},
                                 {"product_id": seed["sugar"].id, "mode": "kg", "qty": "1.25", "unit_price": "0.350"}]}]}


def test_sale_push_updates_stock_and_is_idempotent(device_client, seed, db):
    payload = sale_payload(seed)
    r = device_client.post("/api/v1/sync/push", json=payload).json()
    assert r["accepted"]["sales"] == [payload["sales"][0]["id"]] and r["rejected"] == []
    # Retry after a lost reply must not double the sale.
    r = device_client.post("/api/v1/sync/push", json=payload).json()
    assert r["accepted"]["sales"] == [payload["sales"][0]["id"]]
    db.expire_all()
    assert db.query(Sale).count() == 1
    sale = db.query(Sale).one()
    assert sale.total == Decimal("20.038")  # 4.900 + 14.700 + 0.4375 rounded
    assert db.get(Product, seed["rice"].id).stock == Decimal("40")  # 48 - 2 - 6
    assert db.get(Product, seed["sugar"].id).stock == Decimal("123.750")
    assert db.query(StockMove).filter_by(reason="sale").count() == 3


def test_bad_record_does_not_block_others(device_client, seed, db):
    good = sale_payload(seed)["sales"][0]
    bad = {"id": str(uuid.uuid4()), "lines": [{"product_id": 9999, "mode": "piece", "qty": 1, "unit_price": "1"}]}
    wrong_mode = {"id": str(uuid.uuid4()), "lines": [{"product_id": seed["sugar"].id, "mode": "carton", "qty": 1, "unit_price": "1"}]}
    r = device_client.post("/api/v1/sync/push", json={"sales": [bad, good, wrong_mode]}).json()
    assert r["accepted"]["sales"] == [good["id"]]
    assert {x["reason"] for x in r["rejected"]} == {"unknown_product", "bad_line"}
    db.expire_all()
    assert db.query(Sale).count() == 1
    assert db.get(Product, seed["rice"].id).stock == Decimal("40")


def test_receipt_push(device_client, seed, db):
    rid = seed["receipt"].id
    payload = {"receipts": [{"receipt_id": rid, "employee_id": seed["admin"].id, "notes": "كرتون تالف",
                             "lines": [{"product_id": seed["rice"].id, "mode": "carton", "qty": 9, "note": "كرتون مفتوح"},
                                       {"product_id": seed["sugar"].id, "mode": "kg", "qty": "5"}]}]}
    r = device_client.post("/api/v1/sync/push", json=payload).json()
    assert r["accepted"]["receipts"] == [rid]
    db.expire_all()
    rec = db.get(Receipt, rid)
    assert rec.status == "received" and rec.device_notes == "كرتون تالف"
    rice_line = next(l for l in rec.lines if l.product_id == seed["rice"].id)
    assert rice_line.diff_base == Decimal("-6")
    assert rice_line.note == "كرتون مفتوح"
    assert any(l.extra for l in rec.lines)
    assert db.get(Product, seed["rice"].id).stock == Decimal("102")  # 48 + 54
    assert db.get(Product, seed["sugar"].id).stock == Decimal("130")
    # Same device retrying is fine; stock is not added twice.
    assert device_client.post("/api/v1/sync/push", json=payload).json()["accepted"]["receipts"] == [rid]
    db.expire_all()
    assert db.get(Product, seed["rice"].id).stock == Decimal("102")
    # Devices learn the new status on an incremental pull; a fresh device never sees it.
    pulled = device_client.get("/api/v1/sync/pull?since=1").json()["receipts"]
    assert pulled[0]["status"] == "received"
    assert device_client.get("/api/v1/sync/pull?since=0").json()["receipts"] == []


def test_cancelled_receipt_is_rejected(device_client, seed, db, admin_client):
    rid = seed["receipt"].id
    admin_client.post(f"/receipts/{rid}/cancel")
    r = device_client.post("/api/v1/sync/push", json={"receipts": [{"receipt_id": rid, "lines": []}]}).json()
    assert r["rejected"][0]["reason"] == "receipt_not_open"


def test_count_push_and_approval_keeps_later_sales(device_client, admin_client, seed, db):
    cid = str(uuid.uuid4())
    device_client.post("/api/v1/sync/push", json={"counts": [{"id": cid, "employee_id": seed["admin"].id,
        "finished_at": "2026-11-01T09:00:00Z", "lines": [{"product_id": seed["rice"].id, "counted": 45}]}]})
    db.expire_all()
    assert db.get(Product, seed["rice"].id).stock == Decimal("48")  # nothing changes before approval
    # A sale of 2 arrives after the count was received but before approval.
    s = {"id": str(uuid.uuid4()), "lines": [{"product_id": seed["rice"].id, "mode": "piece", "qty": 2, "unit_price": "2.45"}]}
    device_client.post("/api/v1/sync/push", json={"sales": [s]})
    r = admin_client.post(f"/counts/{cid}/approve", follow_redirects=False)
    assert r.status_code == 303
    db.expire_all()
    assert db.get(CountSession, cid).status == "approved"
    assert db.get(Product, seed["rice"].id).stock == Decimal("43")  # 46 after sale, then -3 from count
    # Approving twice does nothing.
    admin_client.post(f"/counts/{cid}/approve")
    db.expire_all()
    assert db.get(Product, seed["rice"].id).stock == Decimal("43")


def test_concurrent_sales_do_not_lose_stock(seed):
    """Two devices push at the same moment; both deductions must land."""
    import threading

    from app.db import SessionLocal
    from app.models import Device
    from app import services

    def push(n):
        s = SessionLocal()
        dev = s.get(Device, seed["device"].id)
        services.push(s, dev, {"sales": [{"id": str(uuid.uuid4()), "lines": [
            {"product_id": seed["rice"].id, "mode": "piece", "qty": 1, "unit_price": "2.45"}]} for _ in range(n)]})
        s.close()

    threads = [threading.Thread(target=push, args=(10,)) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    s = SessionLocal()
    assert s.get(Product, seed["rice"].id).stock == Decimal("8")  # 48 - 40
    s.close()


def test_same_product_on_two_sale_lines(device_client, seed, db):
    sid = str(uuid.uuid4())
    r = device_client.post("/api/v1/sync/push", json={"sales": [{"id": sid, "lines": [
        {"product_id": seed["rice"].id, "mode": "piece", "qty": 1, "unit_price": "2.450"},
        {"product_id": seed["rice"].id, "mode": "piece", "qty": 1, "unit_price": "2.450"},
        {"product_id": seed["rice"].id, "mode": "carton", "qty": 1, "unit_price": "14.700"}]}]}).json()
    assert r["accepted"]["sales"] == [sid]
    db.expire_all()
    assert len(db.get(Sale, sid).lines) == 3
    assert db.get(Product, seed["rice"].id).stock == Decimal("40")  # 48 - 1 - 1 - 6


def test_new_receipt_made_on_device(device_client, seed, db):
    cid = str(uuid.uuid4())
    body = {"new_receipts": [{"id": cid, "supplier_id": seed["supplier"].id, "notes": "جه من غير سند",
            "lines": [{"product_id": seed["rice"].id, "mode": "carton", "qty": 2, "note": "كرتون مفتوح"},
                      {"product_id": seed["sugar"].id, "mode": "kg", "qty": "3.5"}]}]}
    r = device_client.post("/api/v1/sync/push", json=body).json()
    assert r["accepted"]["new_receipts"] == [cid] and r["rejected"] == []
    assert device_client.post("/api/v1/sync/push", json=body).json()["accepted"]["new_receipts"] == [cid]  # retry
    db.expire_all()
    rec = db.query(Receipt).filter_by(client_id=cid).one()
    assert rec.status == "pending" and len(rec.lines) == 2 and rec.device_notes == "جه من غير سند"
    assert db.get(Product, seed["rice"].id).stock == Decimal("48"), "no stock change before approval"
    # Unknown supplier by name is created.
    r = device_client.post("/api/v1/sync/push", json={"new_receipts": [{"id": str(uuid.uuid4()), "supplier_name": "مورد جديد",
        "lines": [{"product_id": seed["rice"].id, "mode": "piece", "qty": 1}]}]}).json()
    assert r["rejected"] == []
    from app.models import Supplier
    assert db.query(Supplier).filter_by(name="مورد جديد").count() == 1
    # Devices get the supplier list.
    assert {s["name"] for s in device_client.get("/api/v1/sync/pull?since=0").json()["suppliers"]} >= {"مورد", "مورد جديد"}


def test_supervisor_approves_device_receipt(device_client, admin_client, seed, db):
    cid = str(uuid.uuid4())
    device_client.post("/api/v1/sync/push", json={"new_receipts": [{"id": cid, "supplier_id": seed["supplier"].id,
        "lines": [{"product_id": seed["rice"].id, "mode": "carton", "qty": 2}, {"product_id": seed["sugar"].id, "mode": "kg", "qty": "3.5"}]}]})
    rec = db.query(Receipt).filter_by(client_id=cid).one()
    assert "مستني موافقتك" in admin_client.get("/").text
    page = admin_client.get(f"/receipts/{rec.id}").text
    assert "موافقة وزيادة الأرصدة" in page
    rice_line = next(l for l in rec.lines if l.product_id == seed["rice"].id)
    sugar_line = next(l for l in rec.lines if l.product_id == seed["sugar"].id)
    # A wrong quantity is refused and nothing changes.
    admin_client.post(f"/receipts/{rec.id}/approve", data={f"q_{rice_line.id}": "1.5"})
    db.expire_all()
    assert db.get(Receipt, rec.id).status == "pending"
    # Supervisor corrects rice to 3 cartons and approves.
    admin_client.post(f"/receipts/{rec.id}/approve", data={f"q_{rice_line.id}": "3", f"q_{sugar_line.id}": "3.5"})
    db.expire_all()
    rec = db.get(Receipt, rec.id)
    assert rec.status == "received" and rec.approved_by == seed["admin"].id
    assert db.get(Product, seed["rice"].id).stock == Decimal("66")  # 48 + 3 x 6
    assert db.get(Product, seed["sugar"].id).stock == Decimal("128.500")
    # Approving again does nothing.
    admin_client.post(f"/receipts/{rec.id}/approve", data={})
    db.expire_all()
    assert db.get(Product, seed["rice"].id).stock == Decimal("66")


def test_supervisor_rejects_device_receipt(device_client, admin_client, seed, db):
    cid = str(uuid.uuid4())
    device_client.post("/api/v1/sync/push", json={"new_receipts": [{"id": cid, "supplier_id": seed["supplier"].id,
        "lines": [{"product_id": seed["rice"].id, "mode": "piece", "qty": 5}]}]})
    rec = db.query(Receipt).filter_by(client_id=cid).one()
    admin_client.post(f"/receipts/{rec.id}/reject")
    db.expire_all()
    assert db.get(Receipt, rec.id).status == "rejected"
    assert db.get(Product, seed["rice"].id).stock == Decimal("48")
    for st in ("pending", "rejected", "all"):
        assert admin_client.get(f"/receipts?status={st}").status_code == 200


def test_device_sees_supervisor_decision(device_client, admin_client, seed, db):
    cid = str(uuid.uuid4())
    device_client.post("/api/v1/sync/push", json={"new_receipts": [{"id": cid, "supplier_id": seed["supplier"].id,
        "lines": [{"product_id": seed["rice"].id, "mode": "carton", "qty": 2}]}]})
    d = device_client.get("/api/v1/sync/pull?since=0").json()
    assert [x["status"] for x in d["decisions"] if x["id"] == cid] == ["pending"]
    assert all(r.get("id") for r in d["receipts"])  # device-made vouchers are not listed as work to do
    rec = db.query(Receipt).filter_by(client_id=cid).one()
    line = rec.lines[0]
    admin_client.post(f"/receipts/{rec.id}/approve", data={f"q_{line.id}": "3"})
    dec = next(x for x in device_client.get("/api/v1/sync/pull?since=999999").json()["decisions"] if x["id"] == cid)
    assert dec["status"] == "received" and dec["by"] == "المدير" and dec["lines"][0]["qty"] == "3.000"

