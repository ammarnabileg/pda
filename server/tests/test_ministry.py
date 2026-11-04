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
