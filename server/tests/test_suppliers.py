import io
import uuid
from decimal import Decimal

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from app.models import Product, Receipt, ReceiptFile, SupplierPayment, Supplier
from tests.test_accounting import login_as

JPEG = b"\xff\xd8\xff\xe0" + b"0" * 200


def voucher(admin_client, seed, no, total=None, files=None):
    data = {"supplier_id": str(seed["supplier"].id), "supplier_invoice_no": no, "note": "",
            "product": [seed["rice"].barcode], "mode": ["carton"], "qty": ["2"]}
    if total is not None:
        data["supplier_invoice_total"] = total
    return admin_client.post("/receipts/new", data=data, files=files or {"files": ("", b"", "application/octet-stream")},
                             follow_redirects=False)


def receive(device_client, seed, rid, cartons):
    device_client.post("/api/v1/sync/push", json={"receipts": [{"receipt_id": rid, "employee_id": seed["admin"].id,
        "lines": [{"product_id": seed["rice"].id, "mode": "carton", "qty": cartons}]}]})


def test_supplier_invoice_number_first_and_never_twice(admin_client, seed, db):
    r = admin_client.post("/receipts/new", data={"supplier_id": str(seed["supplier"].id), "product": [seed["rice"].barcode],
                                                 "mode": ["carton"], "qty": ["1"]})
    assert r.status_code == 400 and "رقم فاتورة الشركة" in r.text
    assert voucher(admin_client, seed, "INV-1", "12.300").status_code == 303
    again = voucher(admin_client, seed, "inv-1")
    assert again.status_code == 400 and "متسجلة قبل كده" in again.text
    # Another supplier may use the same number; a cancelled voucher frees it.
    other = Supplier(name="شركة تانية")
    db.add(other)
    db.commit()
    first = db.query(Receipt).filter_by(supplier_invoice_no="INV-1").one()
    admin_client.post(f"/receipts/{first.id}/cancel")
    assert voucher(admin_client, seed, "INV-1").status_code == 303


def test_invoice_photo_from_dashboard(admin_client, seed, db):
    r = voucher(admin_client, seed, "P-1", files={"files": ("inv.jpg", JPEG, "image/jpeg")})
    assert r.status_code == 303
    rec = db.query(Receipt).filter_by(supplier_invoice_no="P-1").one()
    f = rec.files[0]
    got = admin_client.get(f"/receipts/{rec.id}/files/{f.id}")
    assert got.status_code == 200 and got.content == JPEG and got.headers["content-type"] == "image/jpeg"
    assert f"/receipts/{rec.id}/files/{f.id}" in admin_client.get(f"/receipts/{rec.id}").text
    bad = admin_client.post(f"/receipts/{rec.id}/files", files={"files": ("x.exe", b"MZ", "application/x-msdownload")})
    assert bad.status_code in (200, 303)
    db.expire_all()
    assert len(db.get(Receipt, rec.id).files) == 1  # refused: not an image or PDF
    with pytest.raises(DBAPIError, match="never deleted"):
        db.execute(text("DELETE FROM receipt_files"))
    db.rollback()


def test_device_voucher_with_invoice_and_photo(device_client, seed, db):
    cid = str(uuid.uuid4())
    body = {"id": cid, "employee_id": seed["admin"].id, "supplier_id": seed["supplier"].id, "supplier_invoice_no": "D-55",
            "supplier_invoice_total": "4.100", "lines": [{"product_id": seed["rice"].id, "mode": "piece", "qty": 2}]}
    photo = {"receipt_client_id": cid, "file_id": "f1"}
    # The photo can arrive before the voucher: the device keeps it and tries again.
    assert device_client.post("/api/v1/receipt-file", data=photo, files={"file": ("a.jpg", JPEG, "image/jpeg")}).status_code == 404
    assert device_client.post("/api/v1/sync/push", json={"new_receipts": [body]}).json()["accepted"]["new_receipts"] == [cid]
    rec = db.query(Receipt).filter_by(client_id=cid).one()
    assert (rec.supplier_invoice_no, rec.supplier_invoice_total) == ("D-55", Decimal("4.100"))
    for _ in range(2):  # retried upload: still one file
        assert device_client.post("/api/v1/receipt-file", data=photo, files={"file": ("a.jpg", JPEG, "image/jpeg")}).status_code == 200
    db.expire_all()
    assert len(db.get(Receipt, rec.id).files) == 1
    # The same supplier invoice from another delivery is refused.
    dup = {**body, "id": str(uuid.uuid4())}
    r = device_client.post("/api/v1/sync/push", json={"new_receipts": [dup]}).json()
    assert r["rejected"][0]["reason"] == "duplicate_invoice"


def test_statement_summary_detail_payments_and_clearance(admin_client, device_client, seed, db):
    rid = seed["receipt"].id  # 10 cartons ordered, no invoice number (older voucher)
    receive(device_client, seed, rid, 9)  # 54 pieces at 2.050 = 110.700
    db.expire_all()
    assert db.get(Receipt, rid).lines[0].unit_cost == Decimal("2.050")
    # A later purchase price does not change what that voucher was worth.
    rice = db.get(Product, seed["rice"].id)
    rice.cost = Decimal("3.000")
    db.commit()
    sid = seed["supplier"].id
    page = admin_client.get(f"/suppliers/{sid}/statement").text
    assert "110.700" in page and "المتبقي لـ«مورد»" in page
    voucher(admin_client, seed, "INV-9", "25.000")
    rid2 = db.query(Receipt).filter_by(supplier_invoice_no="INV-9").one().id
    receive(device_client, seed, rid2, 2)
    # The supplier's invoice total is what is billed, not our own calculation.
    page = admin_client.get(f"/suppliers/{sid}/statement").text
    assert "135.700" in page
    sup = login_as(db, "supervisor", "sup")[0]
    assert sup.post(f"/suppliers/{sid}/payments", data={"amount": "135.700", "paid_on": "2026-11-04", "method": "cash"}).status_code == 403
    assert admin_client.post(f"/suppliers/{sid}/payments", data={"amount": "-5", "paid_on": "2026-11-04", "method": "cash"}, follow_redirects=False).status_code == 303
    assert db.query(SupplierPayment).count() == 0  # a correction needs a reason
    admin_client.post(f"/suppliers/{sid}/payments", data={"amount": "135.700", "paid_on": "2026-11-04", "method": "cheque",
                                                       "reference": "778899"})
    page = admin_client.get(f"/suppliers/{sid}/statement?d_from=2026-01-01&d_to=2026-12-31").text
    assert "براءة ذمة" in page and "لا توجد أي مستحقات" in page and "778899" in page
    detail = admin_client.get(f"/suppliers/{sid}/statement?view=detail&d_from=2026-01-01&d_to=2026-12-31").text
    assert "أرز" in detail and "INV-9" in detail and "الفرق بين الفاتورة والمستلم" in detail
    # Before the payment's date the balance is still open; the opening balance carries earlier vouchers.
    later = admin_client.get(f"/suppliers/{sid}/statement?d_from=2026-11-05&d_to=2026-12-31").text
    assert "رصيد أول المدة" in later and "براءة ذمة" in later
    csv = admin_client.get(f"/suppliers/{sid}/statement?format=csv&d_from=2026-01-01&d_to=2026-12-31")
    assert csv.headers["content-type"].startswith("text/csv") and "778899" in csv.text
    assert "0.000" in admin_client.get("/suppliers").text
