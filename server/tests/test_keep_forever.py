import uuid

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from app.models import CountSession, Receipt, Sale


def push_sale(device_client, seed):
    sid = str(uuid.uuid4())
    r = device_client.post("/api/v1/sync/push", json={"sales": [{"id": sid, "employee_id": seed["cashier"].id,
        "lines": [{"product_id": seed["rice"].id, "mode": "piece", "qty": 1, "unit_price": "2.45"}]}]})
    assert r.json()["accepted"]["sales"] == [sid]
    return sid


def refused(db, sql, **params):
    with pytest.raises(DBAPIError, match="never deleted"):
        db.execute(text(sql), params)
        db.flush()
    db.rollback()


def test_sales_counts_receipts_and_moves_cannot_be_deleted(device_client, seed, db):
    sid = push_sale(device_client, seed)
    cid = str(uuid.uuid4())
    device_client.post("/api/v1/sync/push", json={"counts": [{"id": cid, "employee_id": seed["admin"].id,
        "finished_at": "2026-11-01T09:00:00Z", "lines": [{"product_id": seed["rice"].id, "counted": 45}]}]})
    for sql in ("DELETE FROM sales", "DELETE FROM sale_lines", "DELETE FROM count_sessions", "DELETE FROM count_lines",
                "DELETE FROM receipts", "DELETE FROM stock_moves", "TRUNCATE sales CASCADE", "TRUNCATE receipt_lines"):
        refused(db, sql)
    # Through the ORM too (cascades would otherwise remove the lines).
    db.delete(db.get(Sale, sid))
    with pytest.raises(DBAPIError, match="never deleted"):
        db.flush()
    db.rollback()
    assert db.get(Sale, sid) is not None and db.get(CountSession, cid) is not None


def test_open_voucher_lines_can_be_edited_but_closed_ones_cannot(admin_client, device_client, seed, db):
    rid = seed["receipt"].id
    # Editing an open voucher replaces its lines: allowed.
    r = admin_client.post(f"/receipts/{rid}/edit", data={"supplier_id": seed["supplier"].id, "supplier_invoice_no": "K-1", "product": [seed["rice"].barcode],
                                                         "mode": ["piece"], "qty": ["5"]}, follow_redirects=False)
    assert r.status_code == 303
    db.expire_all()
    assert [(l.product_id, l.mode) for l in db.get(Receipt, rid).lines] == [(seed["rice"].id, "piece")]  # was a carton line
    admin_client.post(f"/receipts/{rid}/cancel")
    refused(db, "DELETE FROM receipt_lines WHERE receipt_id = :rid", rid=rid)
    refused(db, "DELETE FROM receipts WHERE id = :rid", rid=rid)
