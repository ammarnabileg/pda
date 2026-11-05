from app.models import Product, ProductBarcode
from tests.test_accounting import login_as


def post(c, pid, **body):
    return c.post(f"/barcodes/{pid}", json=body)


def test_barcodes_page_add_remove_main_and_unit(admin_client, device_client, seed, db):
    rice, sugar = seed["rice"].id, seed["sugar"].id
    page = admin_client.get("/barcodes").text
    assert "أرز" in page and "سكر" in page and "امسح هنا" in page
    v0 = device_client.get("/api/v1/sync/pull?since=0").json()["version"]
    # Add a carton barcode by "scanning" it.
    r = post(admin_client, rice, action="add", code="16281000999", mode="carton")
    assert r.status_code == 200 and r.json()["ok"] and any(c["code"] == "16281000999" and c["mode"] == "carton" for c in r.json()["row"]["codes"])
    # Devices get it on the next sync.
    changed = device_client.get(f"/api/v1/sync/pull?since={v0}").json()["products"]
    assert [p["id"] for p in changed] == [rice] and {"code": "16281000999", "mode": "carton"} in changed[0]["barcodes"]
    # Refused: same code twice, a code of another product, carton on a kg product, spaces.
    assert "متسجل على الصنف ده" in post(admin_client, rice, action="add", code="16281000999", mode="carton").json()["error"]
    assert "سكر" in post(admin_client, rice, action="add", code="2100000012345", mode="piece").json()["error"]
    assert post(admin_client, sugar, action="add", code="777", mode="carton").status_code == 400
    assert post(admin_client, rice, action="add", code="12 34", mode="piece").json()["ok"]  # spaces from a scanner are dropped
    # Unit name علبة and carton size.
    r = post(admin_client, rice, action="unit", piece_name="علبة", carton="12")
    assert r.json()["row"]["piece_name"] == "علبة" and r.json()["row"]["carton"] == 12
    db.expire_all()
    p = db.get(Product, rice)
    assert p.piece_name == "علبة" and p.mode_name("piece") == "علبة"
    assert device_client.get(f"/api/v1/sync/pull?since={v0}").json()["products"][0]["piece_name"] == "علبة"
    # Make an extra piece barcode the main one; the old main stays as an extra.
    old_main = p.barcode
    r = post(admin_client, rice, action="main", code="1234")
    db.expire_all()
    p = db.get(Product, rice)
    assert p.barcode == "1234" and any(b.code == old_main and b.mode == "piece" for b in p.extra_barcodes)
    # Removing the main barcode promotes the other piece barcode; the last one cannot go.
    post(admin_client, rice, action="remove", code="1234")
    db.expire_all()
    assert db.get(Product, rice).barcode == old_main
    assert "الأساسي" in post(admin_client, rice, action="remove", code=old_main).json()["error"]
    # Carton size 0 while a carton barcode exists is refused.
    assert post(admin_client, rice, action="unit", piece_name="علبة", carton="0").status_code == 400


def test_barcodes_page_view_only_and_filters(db, seed, admin_client):
    c, _ = login_as(db, "supervisor", "sup")
    page = c.get("/barcodes").text
    assert "أرز" in page and "امسح هنا" not in page
    assert post(c, seed["rice"].id, action="add", code="555", mode="piece").status_code == 403
    assert db.query(ProductBarcode).filter_by(code="555").count() == 0
    missing = admin_client.get("/barcodes?show=missing").text  # rice has cartons and a carton barcode in seed? check flag
    assert "باركودات الأصناف" in missing
    assert admin_client.get("/barcodes?format=pdf").content[:4] == b"%PDF"


def test_device_barcodes_admin_only(device_client, seed, db):
    rice = seed["rice"].id
    url = f"/api/v1/products/{rice}/barcodes"
    # A cashier cannot change barcodes, even from a paired device.
    assert device_client.post(url, json={"employee_id": seed["cashier"].id, "action": "add", "code": "4242", "mode": "piece"}).status_code == 403
    r = device_client.post(url, json={"employee_id": seed["admin"].id, "action": "add", "code": "4242", "mode": "piece"}).json()
    assert r["ok"] and {"code": "4242", "mode": "piece"} in r["product"]["barcodes"]
    r = device_client.post(url, json={"employee_id": seed["admin"].id, "action": "add", "code": "4242", "mode": "piece"}).json()
    assert not r["ok"] and "متسجل" in r["error"]
    r = device_client.post(url, json={"employee_id": seed["admin"].id, "action": "unit", "piece_name": "علبة", "carton": 6}).json()
    assert r["product"]["piece_name"] == "علبة"
    from app.models import AuditLog
    assert db.query(AuditLog).filter_by(table_name="product_barcodes", action="INSERT").first().actor == f"emp:{seed['admin'].id}"
