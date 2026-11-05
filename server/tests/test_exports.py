import io
import uuid

from openpyxl import Workbook, load_workbook

from app.models import Product


def sheet_text(content):
    ws = load_workbook(io.BytesIO(content)).active
    assert ws.sheet_view.rightToLeft
    return " ".join(str(c) for row in ws.iter_rows(values_only=True) for c in row if c is not None)


def test_every_page_exports_excel_and_pdf(admin_client, device_client, seed, db):
    sid = str(uuid.uuid4())
    device_client.post("/api/v1/sync/push", json={"sales": [{"id": sid, "employee_id": seed["cashier"].id, "ministry_invoice_no": "4455",
        "lines": [{"product_id": seed["rice"].id, "mode": "piece", "qty": 2, "unit_price": "2.450"}]}]})
    cid = str(uuid.uuid4())
    device_client.post("/api/v1/sync/push", json={"counts": [{"id": cid, "employee_id": seed["admin"].id, "count_date": "2026-11-03",
        "committee": "1", "finished_at": "2026-11-03T08:00:00Z", "lines": [{"product_id": seed["rice"].id, "counted": 40}]}]})
    rid, sup, rice = seed["receipt"].id, seed["supplier"].id, seed["rice"].id
    pages = {
        "/products": "أرز", f"/products/{rice}": "كارت صنف", "/sales": "4455", f"/sales/{sid}": "فاتورة رقم",
        "/reports": "تقرير المبيعات", "/receipts?status=all": "سندات الاستلام", f"/receipts/{rid}": "سند استلام رقم",
        "/counts?status=all": "الجرد", f"/counts/{cid}": "جرد رقم", "/counts/day/2026-11-03": "جرد يوم",
        "/suppliers": "الموردين", f"/suppliers/{sup}/statement?view=detail": "تفصيلي", "/prices": "سجل الأسعار",
        "/log": "السجل", "/employees": "الموظفين", "/roles": "الأدوار", "/devices": "الأجهزة",
    }
    for url, title in pages.items():
        page = admin_client.get(url).text
        assert "تنزيل Excel" in page and "تنزيل PDF" in page, url
        sep = "&" if "?" in url else "?"
        x = admin_client.get(f"{url}{sep}format=xlsx")
        assert x.status_code == 200 and x.headers["content-type"].startswith("application/vnd.openxmlformats"), url
        assert title in sheet_text(x.content), url
        p = admin_client.get(f"{url}{sep}format=pdf")
        assert p.status_code == 200 and p.content[:4] == b"%PDF" and len(p.content) > 3000, url
        assert "attachment" in p.headers["content-disposition"], url


def test_products_export_has_all_rows_not_one_page(admin_client, seed, db):
    for i in range(130):
        db.add(Product(barcode=f"99{i:06d}", name=f"صنف {i}", unit="piece", price=1, cost=0, carton=0, stock=0))
    db.commit()
    text = sheet_text(admin_client.get("/products?format=xlsx").content)
    assert "صنف 129" in text and "صنف 0" in text


def test_viewer_can_export(db, seed):
    from tests.test_accounting import login_as
    c, _ = login_as(db, "supervisor", "sup")
    assert c.get("/products?format=pdf").content[:4] == b"%PDF"


def xlsx(rows):
    wb = Workbook()
    for r in rows:
        wb.active.append(r)
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def test_import_from_excel_with_arabic_titles(admin_client, seed, db):
    data = xlsx([["الباركود", "اسم الصنف", "الوحدة", "سعر البيع", "سعر الشراء", "حبات الكرتون", "حد الطلب", "باركود الكرتون", "باركودات تانية"],
                 [6281000777001, "عدس أحمر", "كيلو", 0.27, 0.2, None, 5, None, None],       # barcode typed as a number
                 ["0012345", "شاي", "حبة", 1.1, 0.9, 12.0, None, "10012345", "55 66"],      # leading zeros kept as text
                 [6281000123456, "أرز (اسم جديد)", "حبة", 2.6, 2.1, 6, 10, None, None]])   # existing: updated
    r = admin_client.post("/products-import", files={"file": ("p.xlsx", data, "application/octet-stream")}, follow_redirects=False)
    assert r.status_code == 303, r.text
    lentil = db.query(Product).filter_by(barcode="6281000777001").one()
    assert (lentil.unit, str(lentil.price), lentil.stock) == ("kg", "0.270", 0)
    tea = db.query(Product).filter_by(barcode="0012345").one()
    assert tea.carton == 12 and sorted((b.code, b.mode) for b in tea.extra_barcodes) == [("10012345", "carton"), ("55", "piece"), ("66", "piece")]
    db.expire_all()
    assert db.query(Product).filter_by(barcode="6281000123456").one().name == "أرز (اسم جديد)"


def test_import_errors_save_nothing(admin_client, seed, db):
    data = xlsx([["الباركود", "اسم الصنف", "الوحدة", "سعر البيع"], ["111", "صنف", "دستة", 1], ["222", "", "حبة", 1]])
    r = admin_client.post("/products-import", files={"file": ("p.xlsx", data, "application/octet-stream")})
    assert r.status_code == 400 and "سطر 2" in r.text and "سطر 3" in r.text and "دستة" in r.text
    assert db.query(Product).filter_by(barcode="111").count() == 0
    r = admin_client.post("/products-import", files={"file": ("p.xlsx", xlsx([["أي حاجة"], ["1"]]), "application/octet-stream")})
    assert r.status_code == 400 and "الباركود" in r.text


def test_template_and_current_products_round_trip(admin_client, seed, db):
    t = admin_client.get("/products-import/template.xlsx")
    wb = load_workbook(io.BytesIO(t.content))
    assert wb.sheetnames == ["الأصناف", "تعليمات"] and wb.active["A1"].value == "رقم الصنف" and wb.active["B1"].value == "الباركود"
    assert wb.active["A2"].number_format == "@" and wb.active["B2"].number_format == "@"
    cur = admin_client.get("/products-import/template.xlsx?current=1").content
    ws = load_workbook(io.BytesIO(cur)).active
    rows = list(ws.iter_rows(values_only=True))
    assert any(r[1] == "6281000123456" for r in rows)
    # Change a price in the downloaded file and import it back.
    wb = load_workbook(io.BytesIO(cur))
    for row in wb.active.iter_rows(min_row=2):
        if row[1].value == "6281000123456":
            row[4].value = 2.75
    buf = io.BytesIO()
    wb.save(buf)
    r = admin_client.post("/products-import", files={"file": ("p.xlsx", buf.getvalue(), "application/octet-stream")}, follow_redirects=False)
    assert r.status_code == 303
    db.expire_all()
    assert str(db.query(Product).filter_by(barcode="6281000123456").one().price) == "2.750"


def test_product_number_imported_searched_and_matched(admin_client, device_client, seed, db):
    data = xlsx([["رقم الصنف", "الباركود", "اسم الصنف", "الوحدة", "سعر البيع"],
                 ["00010005", 1000000300055, "حليب نان 1", "علبة", 0.73]])
    assert admin_client.post("/products-import", files={"file": ("p.xlsx", data, "x")}, follow_redirects=False).status_code == 303
    p = db.query(Product).filter_by(code="00010005").one()
    assert (p.barcode, p.piece_name) == ("1000000300055", "علبة")
    # Same product number with a new barcode: the product is updated, not duplicated.
    data = xlsx([["رقم الصنف", "الباركود", "اسم الصنف", "الوحدة", "سعر البيع"], ["00010005", "1000000399999", "حليب نان 1", "علبة", 0.75]])
    admin_client.post("/products-import", files={"file": ("p.xlsx", data, "x")})
    db.expire_all()
    assert db.query(Product).filter_by(code="00010005").count() == 1 and db.query(Product).filter_by(code="00010005").one().barcode == "1000000399999"
    # Searched by number in the dashboard, with or without leading zeros; devices receive it.
    assert "حليب نان 1" in admin_client.get("/products?q=10005").text
    assert any(x["code"] == "00010005" for x in device_client.get("/api/v1/sync/pull?since=0").json()["products"])
    # The same number twice is refused.
    r = admin_client.post(f"/products/{seed['rice'].id}", data={"code": "00010005", "name": "أرز", "barcode": seed["rice"].barcode,
                                                                 "unit": "piece", "price": "2.45", "carton": "6"})
    assert r.status_code == 400 and "رقم الصنف ده مستخدم" in r.text
