import io
import uuid
from decimal import Decimal

from openpyxl import Workbook, load_workbook

from app.models import Product, Supplier


def receive(device_client, seed, cartons=9):
    device_client.post("/api/v1/sync/push", json={"receipts": [{"receipt_id": seed["receipt"].id, "employee_id": seed["admin"].id,
        "lines": [{"product_id": seed["rice"].id, "mode": "carton", "qty": cartons}]}]})


def sell(device_client, seed, qty, when=None):
    body = {"id": str(uuid.uuid4()), "employee_id": seed["cashier"].id, "ministry_invoice_no": str(uuid.uuid4().int)[:10],
            "lines": [{"product_id": seed["rice"].id, "mode": "piece", "qty": qty, "unit_price": "2.450"}]}
    if when:
        body["created_at"] = when
    device_client.post("/api/v1/sync/push", json={"sales": [body]})


def test_clearance_detail_and_summary_agree(admin_client, device_client, seed, db):
    sup = db.get(Supplier, seed["supplier"].id)
    sup.no = 879
    db.commit()
    receive(device_client, seed)                       # 54 pieces x 2.050 = 110.700, and rice becomes this supplier's
    db.expire_all()
    assert db.get(Product, seed["rice"].id).supplier_id == sup.id
    sell(device_client, seed, 2)                       # 2 x 2.050 = 4.100 at purchase price
    detail = admin_client.get(f"/suppliers/{sup.id}/clearance?view=detail").text
    assert "براءة الذمة تفصيلي أصناف" in detail and "879" in detail
    assert "110.700" in detail and "4.100" in detail and "106.600" in detail
    summary = admin_client.get(f"/suppliers/{sup.id}/clearance").text
    assert "براءة الذمة لمورد حتى" in summary and "106.600" in summary
    # Excel of both says the same.
    for view in ("detail", "summary"):
        x = admin_client.get(f"/suppliers/{sup.id}/clearance?view={view}&format=xlsx").content
        cells = [c for r in load_workbook(io.BytesIO(x)).active.iter_rows(values_only=True) for c in r]
        assert 106.6 in cells and 110.7 in cells
    assert admin_client.get(f"/suppliers/{sup.id}/clearance?view=detail&format=pdf").content[:4] == b"%PDF"


def test_clearance_opening_balance(admin_client, device_client, seed, db):
    sid = seed["supplier"].id
    receive(device_client, seed)
    sell(device_client, seed, 4, "2026-01-10T10:00:00+03:00")   # before the period
    sell(device_client, seed, 2)                                 # inside it
    page = admin_client.get(f"/suppliers/{sid}/clearance?view=detail&d_from=2026-06-01").text
    # Opening = 110.700 received (the voucher was received now, so it is inside the period) ... received now: in moves.
    # Sales before the period come off the opening: 4 x 2.050 = 8.200.
    assert "-8.200" in page and "110.700" in page and "4.100" in page and "98.400" in page


def test_import_sets_supplier(admin_client, seed, db):
    wb = Workbook()
    wb.active.append(["رقم الصنف", "الباركود", "اسم الصنف", "الوحدة", "سعر البيع", "رقم المورد", "اسم المورد"])
    wb.active.append(["08790019", "6281234567890", "ونستون ديو مكس", "حبة", 1.0, 879, "شركة البستان الوطنية التجارية - سجاير"])
    buf = io.BytesIO()
    wb.save(buf)
    r = admin_client.post("/products-import", files={"file": ("p.xlsx", buf.getvalue(), "x")}, follow_redirects=False)
    assert r.status_code == 303, r.text
    sup = db.query(Supplier).filter_by(no=879).one()
    assert sup.name == "شركة البستان الوطنية التجارية - سجاير"
    assert db.query(Product).filter_by(code="08790019").one().supplier_id == sup.id
    assert "ونستون ديو مكس" in admin_client.get(f"/suppliers/{sup.id}/clearance?view=detail").text
