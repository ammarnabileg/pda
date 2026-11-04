from decimal import Decimal

from app.models import Employee, Product, Receipt


def test_setup_creates_first_admin_once(client):
    assert client.get("/", follow_redirects=False).headers["location"] == "/login"
    assert client.get("/login", follow_redirects=False).headers["location"] == "/setup"
    r = client.post("/setup", data={"name": "مدير", "username": "boss", "password": "short", "pin": "1234"})
    assert r.status_code == 400
    r = client.post("/setup", data={"name": "مدير", "username": "boss", "password": "longenough", "pin": "1234"}, follow_redirects=False)
    assert r.status_code == 303
    assert client.get("/").status_code == 200
    assert client.get("/setup", follow_redirects=False).headers["location"] == "/login"


def test_login_required_and_wrong_password(client, seed):
    assert client.get("/products", follow_redirects=False).status_code == 303
    r = client.post("/login", data={"username": "admin", "password": "nope"})
    assert r.status_code == 400


def test_all_pages_render(admin_client, seed):
    rid, pid = seed["receipt"].id, seed["rice"].id
    for url in ["/", "/products", "/products?q=أرز&low=1&inactive=1", "/products/new", f"/products/{pid}",
                "/products-import", "/products-import/template.csv", "/suppliers", "/receipts",
                "/receipts?status=all", "/receipts/new", f"/receipts/{rid}", f"/receipts/{rid}/edit", "/sales",
                "/reports", "/reports?csv=1", "/counts", "/counts?status=all", "/employees", "/employees/new",
                f"/employees/{seed['cashier'].id}", "/devices", "/backup"]:
        r = admin_client.get(url)
        assert r.status_code == 200, url


def test_product_create_edit_and_duplicate_barcode(admin_client, seed, db):
    r = admin_client.post("/products/new", data={"barcode": "123456", "name": "شاي", "unit": "piece", "price": "0.950",
                                                  "cost": "0.7", "carton": "12", "min_stock": "5", "stock": "24", "active": "1"},
                          follow_redirects=False)
    assert r.status_code == 303
    p = db.query(Product).filter_by(barcode="123456").one()
    assert p.stock == 0 and p.version > 0  # an opening stock sent anyway is ignored: stock comes from vouchers and counts
    r = admin_client.post("/products/new", data={"barcode": "123456", "name": "x", "unit": "piece", "price": "1"})
    assert r.status_code == 400 and "مستخدم" in r.text
    # Stock cannot be typed in, not even by the admin.
    assert admin_client.post(f"/products/{p.id}/stock", data={"stock": "20", "note": "تالف"}).status_code in (404, 405)
    assert "تعديل الرصيد يدوياً" not in admin_client.get(f"/products/{p.id}").text
    db.expire_all()
    assert db.get(Product, p.id).stock == 0


def test_csv_import_all_or_nothing(admin_client, seed, db):
    bad = "barcode,name,unit,price,cost,carton,stock\n111,صنف,piece,1,0.5,6,10\n222,,piece,1,0.5,0,1\n"
    r = admin_client.post("/products-import", files={"file": ("p.csv", bad.encode(), "text/csv")})
    assert r.status_code == 400 and "سطر 3" in r.text
    assert db.query(Product).filter_by(barcode="111").count() == 0
    good = "﻿barcode,name,unit,price,cost,carton,stock\n111,صنف,piece,1,0.5,6,10\n6281000123456,أرز جديد,piece,2.6,2.1,6,\n"
    r = admin_client.post("/products-import", files={"file": ("p.csv", good.encode(), "text/csv")}, follow_redirects=False)
    assert r.status_code == 303
    db.expire_all()
    assert db.query(Product).filter_by(barcode="111").one().stock == 0  # the file's stock column is ignored
    rice = db.query(Product).filter_by(barcode="6281000123456").one()
    assert rice.name == "أرز جديد" and rice.stock == Decimal("48")


def test_receipt_create_and_edit(admin_client, seed, db):
    data = {"supplier_id": str(seed["supplier"].id), "note": "", "supplier_invoice_no": "INV-100",
            "product": ["6281000123456 — أرز", "2100000012345 — سكر", ""], "mode": ["carton", "kg", "piece"], "qty": ["5", "20.5", ""]}
    r = admin_client.post("/receipts/new", data=data, follow_redirects=False)
    assert r.status_code == 303
    rec = db.query(Receipt).order_by(Receipt.id.desc()).first()
    assert len(rec.lines) == 2
    bad = dict(data, mode=["kg", "kg", "piece"])
    assert admin_client.post("/receipts/new", data=bad).status_code == 400
    v = rec.version
    admin_client.post(f"/receipts/{rec.id}/edit", data=dict(data, qty=["6", "20", ""]))
    db.expire_all()
    rec = db.get(Receipt, rec.id)
    assert rec.version > v and rec.lines[0].ordered == Decimal("6")


def test_employee_pin_must_be_unique(admin_client, seed, db):
    r = admin_client.post("/employees/new", data={"name": "سعيد", "role": "cashier", "pin": "2222", "active": "1"})
    assert r.status_code == 400 and "مستخدم" in r.text
    r = admin_client.post("/employees/new", data={"name": "سعيد", "role": "cashier", "pin": "3333", "active": "1"}, follow_redirects=False)
    assert r.status_code == 303
    assert db.query(Employee).filter_by(name="سعيد").one().role == "cashier"


def test_admin_cannot_demote_self(admin_client, seed):
    r = admin_client.post(f"/employees/{seed['admin'].id}", data={"name": "المدير", "role": "cashier", "pin": "", "active": "1"})
    assert r.status_code == 400


def test_cashier_cannot_open_dashboard(client, seed):
    r = client.post("/login", data={"username": "", "password": ""})
    assert r.status_code == 400


def test_reports_with_data(admin_client, device_client, seed):
    import uuid
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).isoformat()
    device_client.post("/api/v1/sync/push", json={"sales": [{"id": str(uuid.uuid4()), "employee_id": seed["cashier"].id, "created_at": now,
        "lines": [{"product_id": seed["rice"].id, "mode": "carton", "qty": 1, "unit_price": "14.700"}]}]})
    r = admin_client.get("/reports")
    assert "14.700" in r.text and "أرز" in r.text
    assert "2.400" in r.text  # profit: 14.700 - 6 * 2.050


def product_form(**over):
    data = {"barcode": "777001", "name": "شاي", "unit": "piece", "price": "0.950", "cost": "0.700",
            "carton": "12", "min_stock": "0", "stock": "24", "active": "1", "xb_code": [], "xb_mode": []}
    data.update(over)
    return data


def test_product_extra_barcodes_and_sync(admin_client, device_client, seed, db):
    r = admin_client.post("/products/new", data=product_form(xb_code=["777009", "777002"], xb_mode=["carton", "piece"]), follow_redirects=False)
    assert r.status_code == 303
    from app.models import ProductBarcode
    p = db.query(Product).filter_by(barcode="777001").one()
    assert {(b.code, b.mode) for b in p.extra_barcodes} == {("777009", "carton"), ("777002", "piece")}
    # Devices receive the extra barcodes with their unit.
    pulled = next(x for x in device_client.get("/api/v1/sync/pull?since=0").json()["products"] if x["barcode"] == "777001")
    assert {(b["code"], b["mode"]) for b in pulled["barcodes"]} == {("777009", "carton"), ("777002", "piece")}
    # Edit: drop one, keep one (same code kept in place, no unique clash), change its unit.
    v = db.get(Product, p.id).version
    r = admin_client.post(f"/products/{p.id}", data=product_form(xb_code=["777009"], xb_mode=["piece"]), follow_redirects=False)
    assert r.status_code == 303
    db.expire_all()
    p = db.get(Product, p.id)
    assert [(b.code, b.mode) for b in p.extra_barcodes] == [("777009", "piece")]
    assert p.version > v
    assert db.query(ProductBarcode).count() == 1
    # Search finds a product by an extra barcode.
    assert "شاي" in admin_client.get("/products?q=777009").text


def test_barcode_rules(admin_client, seed):
    # Already the main barcode of another product.
    r = admin_client.post("/products/new", data=product_form(xb_code=["6281000123456"], xb_mode=["carton"]))
    assert r.status_code == 400 and "أرز" in r.text
    # Carton barcode without a carton size.
    r = admin_client.post("/products/new", data=product_form(carton="0", xb_code=["777010"], xb_mode=["carton"]))
    assert r.status_code == 400 and "عدد الحبات في الكرتون" in r.text
    # Repeated inside the same product.
    r = admin_client.post("/products/new", data=product_form(xb_code=["777001"], xb_mode=["piece"]))
    assert r.status_code == 400 and "متكرر" in r.text
    # Errors are shown next to their field.
    r = admin_client.post("/products/new", data=product_form(price="abc"))
    assert 'id="err-price"' in r.text


def test_receipt_accepts_carton_barcode(admin_client, seed, db):
    from app.models import ProductBarcode
    db.add(ProductBarcode(product_id=seed["rice"].id, code="16281000123453", mode="carton"))
    db.commit()
    r = admin_client.post("/receipts/new", data={"supplier_id": str(seed["supplier"].id), "note": "", "supplier_invoice_no": "C-7",
                                                 "product": ["16281000123453 — أرز"], "mode": ["carton"], "qty": ["3"]}, follow_redirects=False)
    assert r.status_code == 303


def test_import_with_carton_barcode(admin_client, seed, db):
    csv_text = "barcode,name,unit,price,cost,carton,stock,carton_barcode,extra_barcodes\n888001,عدس,piece,0.5,0.4,10,20,1888001,888002 888003\n"
    r = admin_client.post("/products-import", files={"file": ("p.csv", csv_text.encode(), "text/csv")}, follow_redirects=False)
    assert r.status_code == 303
    p = db.query(Product).filter_by(barcode="888001").one()
    assert sorted((b.code, b.mode) for b in p.extra_barcodes) == [("1888001", "carton"), ("888002", "piece"), ("888003", "piece")]


def test_new_pages_render(admin_client, seed, device_client):
    import uuid
    device_client.post("/api/v1/sync/push", json={"counts": [{"id": str(uuid.uuid4()), "finished_at": "2026-11-01T09:00:00Z",
        "lines": [{"product_id": seed["rice"].id, "counted": 45}, {"product_id": seed["sugar"].id, "counted": "125"}]}]})
    for url in ["/", "/products?status=all&unit=kg&low=1&page=3", "/counts", "/backup", "/reports", "/sales", "/devices", "/employees",
                f"/receipts/{seed['receipt'].id}?only=diff"]:
        r = admin_client.get(url)
        assert r.status_code == 200, url
    from app.models import CountSession
    import re
    cid = re.search(r'/counts/([0-9a-f-]{36})"', admin_client.get("/counts").text).group(1)
    r = admin_client.get(f"/counts/{cid}?only=diff")
    assert "ناقص 3 حبة" in r.text and "سكر" not in r.text.split("الفروق بس")[1]
