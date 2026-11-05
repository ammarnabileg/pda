"""Kuwaiti dinar: 3 decimals (fils). Inputs with more are refused, never rounded silently; totals round half up."""
import io
import uuid
from decimal import Decimal

from openpyxl import Workbook

from app.models import Product, Sale, SupplierPayment


def xlsx(rows):
    wb = Workbook()
    for r in rows:
        wb.active.append(r)
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def test_prices_with_more_than_three_decimals_are_refused(admin_client, seed, db):
    r = admin_client.post("/products/new", data={"barcode": "7001", "name": "صنف", "unit": "piece", "price": "0.0675", "carton": "0"})
    assert r.status_code == 400 and "3 أرقام عشرية" in r.text
    assert db.query(Product).filter_by(barcode="7001").count() == 0
    r = admin_client.post("/products-import", files={"file": ("p.xlsx", xlsx([["الباركود", "اسم الصنف", "سعر البيع"], ["7002", "صنف", 0.0675]]), "x")})
    assert r.status_code == 400 and "3 أرقام عشرية" in r.text
    # Float noise from an Excel formula (2.4499999999) is the real 2.450, not an error.
    r = admin_client.post("/products-import", files={"file": ("p.xlsx", xlsx([["الباركود", "اسم الصنف", "سعر البيع"], ["7003", "صنف", 2.4499999999999]]), "x")},
                          follow_redirects=False)
    assert r.status_code == 303
    assert db.query(Product).filter_by(barcode="7003").one().price == Decimal("2.450")


def test_payment_and_invoice_total_in_fils(admin_client, seed, db):
    sid = seed["supplier"].id
    admin_client.post(f"/suppliers/{sid}/payments", data={"amount": "10.1234", "paid_on": "2026-11-05", "method": "cash"})
    assert db.query(SupplierPayment).count() == 0
    r = admin_client.post("/receipts/new", data={"supplier_id": str(sid), "supplier_invoice_no": "K1", "supplier_invoice_total": "12.3456",
                                                 "product": [seed["rice"].barcode], "mode": ["carton"], "qty": ["1"]})
    assert r.status_code == 400 and "3 أرقام عشرية" in r.text


def test_line_totals_round_half_up_to_the_fils(device_client, seed, db):
    sid = str(uuid.uuid4())
    device_client.post("/api/v1/sync/push", json={"sales": [{"id": sid, "employee_id": seed["cashier"].id, "ministry_invoice_no": "91",
        "lines": [{"product_id": seed["sugar"].id, "mode": "kg", "qty": "1.250", "unit_price": "0.350"}]}]})
    assert db.get(Sale, sid).total == Decimal("0.438")   # 0.4375 -> 0.438, the same as the device (lineTotal)
