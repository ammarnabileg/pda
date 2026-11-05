import uuid


def sale(device_client, seed, mi=None, mt=None, qty=1, device_no=None):
    sid = str(uuid.uuid4())
    body = {"id": sid, "employee_id": seed["cashier"].id,
            "lines": [{"product_id": seed["rice"].id, "mode": "piece", "qty": qty, "unit_price": "2.450"}]}
    if mi:
        body["ministry_invoice_no"] = mi
    if mt:
        body["ministry_total"] = mt
    assert device_client.post("/api/v1/sync/push", json={"sales": [body]}).json()["accepted"]["sales"] == [sid]
    return sid


def test_ministry_invoice_stored_searched_and_flagged(device_client, seed, db, admin_client):
    ok = sale(device_client, seed, " 168126 059405 ", "2.450")
    from app.models import Sale
    s = db.get(Sale, ok)
    assert (s.ministry_invoice_no, str(s.ministry_total)) == ("168126059405", "2.450")
    page = admin_client.get(f"/sales/{ok}").text
    assert "168126059405" in page and "اتصرفت أكتر من مرة" not in page and "مختلف" not in page
    # Found by its number whatever the date filter says.
    found = admin_client.get("/sales?mi=168126059405&d_from=2000-01-01&d_to=2000-01-02").text
    assert f"/sales/{ok}" in found
    # A second device delivering the same ministry invoice offline is accepted (the goods left) but flagged.
    dup = sale(device_client, seed, "168126059405", "2.450")
    page = admin_client.get(f"/sales/{dup}").text
    assert "اتصرفت أكتر من مرة" in page and f"/sales/{ok}" in page
    # Totals that do not match the ministry invoice are flagged too.
    off = sale(device_client, seed, "777", "2.000")
    assert "مختلف عن الفاتورة دي" in admin_client.get(f"/sales/{off}").text
    listing = admin_client.get("/sales?problems=1").text
    assert "مكررة" in listing and "الإجمالي مختلف" in listing and f"/sales/{off}" in listing
    # An older app without the field still syncs; the sale shows as missing a ministry number.
    old = sale(device_client, seed)
    assert "من غير رقم فاتورة وزارة" in admin_client.get(f"/sales/{old}").text


JPEG = b"\xff\xd8\xff\xe0" + b"0" * 200


def test_ministry_invoice_photo(device_client, seed, db, admin_client):
    import pytest
    from fastapi.testclient import TestClient
    from sqlalchemy import text
    from sqlalchemy.exc import DBAPIError

    from app.main import app
    from app.models import Employee, Sale
    from app.security import hash_password, hash_pin

    sid = str(uuid.uuid4())
    photo = {"sale_id": sid, "file_id": "m1"}
    # The photo can arrive before the sale: the device keeps it and tries again.
    assert device_client.post("/api/v1/sale-file", data=photo, files={"file": ("a.jpg", JPEG, "image/jpeg")}).status_code == 404
    assert device_client.post("/api/v1/sale-file", data={"sale_id": "not-a-uuid", "file_id": "x"},
                              files={"file": ("a.jpg", JPEG, "image/jpeg")}).status_code == 404
    body = {"id": sid, "employee_id": seed["cashier"].id, "ministry_invoice_no": "168126059405",
            "lines": [{"product_id": seed["rice"].id, "mode": "piece", "qty": 1, "unit_price": "2.450"}]}
    assert device_client.post("/api/v1/sync/push", json={"sales": [body]}).json()["accepted"]["sales"] == [sid]
    page = admin_client.get(f"/sales/{sid}").text
    assert "مفيش صورة لسه" in page
    assert "من غير صورة" in admin_client.get("/sales?problems=1").text
    # Only an image is taken, and a retried upload is still one photo.
    assert device_client.post("/api/v1/sale-file", data=photo, files={"file": ("a.pdf", b"%PDF-1", "application/pdf")}).status_code == 422
    for _ in range(2):
        assert device_client.post("/api/v1/sale-file", data=photo, files={"file": ("a.jpg", JPEG, "image/jpeg")}).status_code == 200
    db.expire_all()
    s = db.get(Sale, sid)
    assert len(s.files) == 1
    fid = s.files[0].id
    page = admin_client.get(f"/sales/{sid}").text
    assert f"/sales/{sid}/files/{fid}" in page and "مفيش صورة لسه" not in page
    r = admin_client.get(f"/sales/{sid}/files/{fid}")
    assert r.status_code == 200 and r.content == JPEG and "no-store" in r.headers["cache-control"]
    # The photo shows the civil ID: a supervisor sees the sale, not the photo.
    salt, h = hash_pin("5555")
    db.add(Employee(name="مشرف", role="supervisor", pin_salt=salt, pin_hash=h, username="sup",
                    password_hash=hash_password("password123")))
    db.commit()
    c = TestClient(app)
    assert c.post("/login", data={"username": "sup", "password": "password123"}, follow_redirects=False).status_code == 303
    page = c.get(f"/sales/{sid}").text
    assert "موجودة" in page and f"/files/{fid}" not in page
    r = c.get(f"/sales/{sid}/files/{fid}", follow_redirects=False)
    assert r.status_code in (302, 303) and r.content != JPEG
    with pytest.raises(DBAPIError, match="never deleted"):
        db.execute(text("DELETE FROM sale_files"))
    db.rollback()
