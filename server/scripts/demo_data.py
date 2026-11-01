#!/usr/bin/env python3
"""Fill an EMPTY database with sample data to try the system.

    python scripts/demo_data.py

Creates: admin (user "admin" / password "admin12345", PIN 1111), a cashier (PIN 2222),
a storekeeper (PIN 3333), 6 products, 2 suppliers, 2 receiving vouchers, and a device
"جهاز تجربة" with a pairing code printed at the end.
Do not run it on the real database: it refuses if products already exist.
"""
import argparse
import sys
from datetime import timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from sqlalchemy import func, select  # noqa: E402

from app import services  # noqa: E402
from app.db import SessionLocal, init_db  # noqa: E402
from app.models import Device, Employee, Product, Receipt, ReceiptLine, Supplier, now  # noqa: E402
from app.security import hash_password, hash_pin, new_pairing_code  # noqa: E402

PRODUCTS = [
    ("6281000123456", "أرز بسمتي ٥ كجم", "piece", "2.450", "2.050", 6, 48, 12),
    ("6281000654321", "زيت دوار الشمس ١٫٨ لتر", "piece", "1.125", "0.950", 12, 72, 24),
    ("2100000012345", "سكر أبيض (بالكيلو)", "kg", "0.350", "0.280", 0, 125, 30),
    ("6281000987654", "حليب طويل الأجل ١ لتر", "piece", "0.250", "0.200", 24, 96, 48),
    ("6281000111222", "شاي أحمر ١٠٠ كيس", "piece", "0.950", "0.780", 12, 40, 12),
    ("6281000333444", "معكرونة ٤٠٠ جرام", "piece", "0.180", "0.140", 20, 200, 40),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairing-code", help="fixed pairing code (tests)")
    args = ap.parse_args()
    init_db()
    db = SessionLocal()
    if db.scalar(select(func.count()).select_from(Product)):
        sys.exit("The database already has products. Demo data is only for an empty database.")

    def emp(name, role, pin, username=None, password=None):
        salt, h = hash_pin(pin)
        e = Employee(name=name, role=role, pin_salt=salt, pin_hash=h, username=username,
                     password_hash=hash_password(password) if password else None)
        services.bump(db, e)
        db.add(e)

    emp("المدير", "admin", "1111", "admin", "admin12345")
    emp("أحمد", "cashier", "2222")
    emp("محمود", "storekeeper", "3333")
    prods = {}
    for barcode, name, unit, price, cost, carton, stock, min_stock in PRODUCTS:
        p = Product(barcode=barcode, name=name, unit=unit, price=price, cost=cost, carton=carton, stock=0, min_stock=min_stock)
        services.bump(db, p)
        db.add(p)
        db.flush()
        services.move_stock(db, p, stock, "manual", note="رصيد افتتاحي")
        prods[barcode] = p
    s1, s2 = Supplier(name="شركة المواد الغذائية المتحدة"), Supplier(name="شركة الألبان الوطنية")
    db.add_all([s1, s2])
    db.flush()
    for sup, lines in ((s1, [("6281000123456", 10), ("6281000654321", 5), ("6281000111222", 3)]),
                       (s2, [("6281000987654", 8), ("6281000333444", 4)])):
        r = Receipt(supplier_id=sup.id)
        for code, n in lines:
            r.lines.append(ReceiptLine(product_id=prods[code].id, mode="carton", ordered=n))
        services.bump(db, r)
        db.add(r)
    code = args.pairing_code or new_pairing_code()
    db.add(Device(name="جهاز تجربة", pairing_code=code, pairing_expires=now() + timedelta(days=1)))
    db.commit()
    print("Demo data created.")
    print("  Dashboard login: admin / admin12345")
    print("  Device PINs: المدير 1111, أحمد (cashier) 2222, محمود (storekeeper) 3333")
    print(f"  Device pairing code (valid 24h): {code}")


if __name__ == "__main__":
    main()
