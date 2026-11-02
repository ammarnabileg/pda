"""Business rules shared by the device API and the dashboard."""
from datetime import datetime, timezone
from decimal import ROUND_HALF_UP, Decimal

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from .db import next_version
from .models import (
    CountLine, CountSession, Device, Employee, Product, ProductBarcode, Receipt, ReceiptLine, Sale, SaleLine,
    StockMove, now,
)

Q3 = Decimal("0.001")


def d3(value) -> Decimal:
    return Decimal(str(value)).quantize(Q3, rounding=ROUND_HALF_UP)


def bump(db: Session, obj):
    obj.version = next_version(db)


def move_stock(db: Session, product: Product, delta, reason: str, ref=None, employee_id=None, note=None):
    delta = d3(delta)
    if delta == 0:
        return
    db.flush()
    # Atomic in the database: two devices selling the same item at once must not lose a sale.
    db.execute(update(Product).where(Product.id == product.id)
               .values(stock=Product.stock + delta, version=next_version(db)))
    db.expire(product, ["stock", "version"])
    db.add(StockMove(product_id=product.id, delta=delta, reason=reason, ref=ref,
                     employee_id=employee_id, note=note))


class SyncError(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


# ---------- Pull (server -> device) ----------

def find_by_code(db: Session, code: str):
    """(product, mode) for any barcode: the main one (piece / kg) or an extra one."""
    code = (code or "").strip()
    if not code:
        return None, None
    p = db.scalar(select(Product).where(Product.barcode == code))
    if p:
        return p, ("kg" if p.unit == "kg" else "piece")
    b = db.scalar(select(ProductBarcode).where(ProductBarcode.code == code))
    return (b.product, b.mode) if b else (None, None)


def code_taken(db: Session, code: str, product_id: int | None) -> str | None:
    """Name of another product already using this barcode, or None."""
    p = db.scalar(select(Product).where(Product.barcode == code, Product.id != (product_id or 0)))
    if p:
        return p.name
    b = db.scalar(select(ProductBarcode).where(ProductBarcode.code == code, ProductBarcode.product_id != (product_id or 0)))
    return b.product.name if b else None


def product_dict(p: Product):
    return {"id": p.id, "barcode": p.barcode, "name": p.name, "unit": p.unit,
            "barcodes": [{"code": b.code, "mode": b.mode} for b in p.extra_barcodes],
            "price": str(p.price), "cost": str(p.cost), "carton": p.carton, "stock": str(p.stock), "active": p.active}


def employee_dict(e: Employee):
    return {"id": e.id, "name": e.name, "role": e.role, "pin_salt": e.pin_salt,
            "pin_hash": e.pin_hash, "active": e.active}


def receipt_dict(r: Receipt):
    return {"id": r.id, "supplier": r.supplier.name, "status": r.status,
            "created_at": r.created_at.isoformat(), "note": r.note or "",
            "lines": [{"product_id": l.product_id, "mode": l.mode, "ordered": str(l.ordered)}
                      for l in r.lines if not l.extra]}


def pull(db: Session, since: int):
    products = db.scalars(select(Product).where(Product.version > since)).all()
    employees = db.scalars(select(Employee).where(Employee.version > since)).all()
    stmt = select(Receipt).where(Receipt.version > since)
    if since == 0:
        stmt = stmt.where(Receipt.status == "open")  # a fresh device only needs work still to do
    receipts = db.scalars(stmt).all()
    versions = [since] + [x.version for x in (*products, *employees, *receipts)]
    return {
        "version": max(versions),
        "full": since == 0,
        "server_time": now().isoformat(),
        "products": [product_dict(p) for p in products],
        "employees": [employee_dict(e) for e in employees],
        "receipts": [receipt_dict(r) for r in receipts],
    }


# ---------- Push (device -> server) ----------

def _parse_time(value):
    if not value:
        return now()
    t = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def _employee_id(db, value):
    if value is None:
        return None
    return value if db.get(Employee, value) else None


def _product(db, pid) -> Product:
    p = db.get(Product, pid)
    if not p:
        raise SyncError("unknown_product")
    return p


def _mode_ok(p: Product, mode: str):
    if p.unit == "kg":
        return mode == "kg"
    return mode == "piece" or (mode == "carton" and p.carton > 0)


def push_sale(db: Session, device: Device, data: dict):
    if db.get(Sale, data["id"]):
        return  # already stored: the device retried after a lost reply
    lines = data.get("lines") or []
    if not lines:
        raise SyncError("empty_sale")
    emp = _employee_id(db, data.get("employee_id"))
    sale = Sale(id=data["id"], device_id=device.id, employee_id=emp,
                created_at=_parse_time(data.get("created_at")), total=0)
    db.add(sale)
    total = Decimal(0)
    for ln in lines:
        p = _product(db, ln["product_id"])
        mode, qty = ln["mode"], d3(ln["qty"])
        if not _mode_ok(p, mode) or qty <= 0:
            raise SyncError("bad_line")
        price = d3(ln["unit_price"])
        cost = d3(p.cost * p.carton if mode == "carton" else p.cost)
        line_total = d3(price * qty)
        total += line_total
        sale.lines.append(SaleLine(product_id=p.id, mode=mode, qty=qty, unit_price=price,
                                   unit_cost=cost, total=line_total))
        move_stock(db, p, -p.to_base(qty, mode), "sale", ref=str(sale.id), employee_id=emp)
    sale.total = d3(total)


def push_count(db: Session, device: Device, data: dict):
    if db.get(CountSession, data["id"]):
        return
    lines = data.get("lines") or []
    if not lines:
        raise SyncError("empty_count")
    s = CountSession(id=data["id"], device_id=device.id,
                     employee_id=_employee_id(db, data.get("employee_id")),
                     started_at=_parse_time(data.get("started_at")),
                     finished_at=_parse_time(data.get("finished_at")))
    db.add(s)
    for ln in lines:
        p = _product(db, ln["product_id"])
        counted = d3(ln["counted"])
        if counted < 0:
            raise SyncError("bad_line")
        s.lines.append(CountLine(product_id=p.id, counted=counted, stock_at_sync=p.stock))


def push_receipt(db: Session, device: Device, data: dict):
    r = db.get(Receipt, data["receipt_id"])
    if not r:
        raise SyncError("unknown_receipt")
    if r.status == "received" and r.device_id == device.id:
        return  # duplicate of what this device already sent
    if r.status != "open":
        raise SyncError("receipt_not_open")
    emp = _employee_id(db, data.get("employee_id"))
    by_product = {l.product_id: l for l in r.lines if not l.extra}
    for ln in data.get("lines") or []:
        p = _product(db, ln["product_id"])
        mode, qty = ln["mode"], d3(ln["qty"])
        if not _mode_ok(p, mode) or qty < 0:
            raise SyncError("bad_line")
        line = by_product.get(p.id)
        if line is None:
            line = ReceiptLine(product_id=p.id, mode=mode, ordered=0, extra=True)
            r.lines.append(line)
            by_product[p.id] = line
        line.received, line.received_mode = qty, mode
        line.note = (str(ln.get("note") or "").strip()[:200]) or None
    db.flush()
    for line in r.lines:
        if line.received is None:
            line.received, line.received_mode = Decimal(0), line.mode
        move_stock(db, line.product, line.received_base, "receipt", ref=f"R-{r.id}", employee_id=emp)
    r.status = "received"
    r.received_at = _parse_time(data.get("received_at"))
    r.received_by = emp
    r.device_id = device.id
    r.device_notes = (data.get("notes") or "").strip()[:500] or None
    bump(db, r)


PUSHERS = {"sales": push_sale, "counts": push_count, "receipts": push_receipt}
ID_FIELD = {"sales": "id", "counts": "id", "receipts": "receipt_id"}


def push(db: Session, device: Device, payload: dict):
    """Each record is saved in its own savepoint, so one bad record never blocks the rest."""
    accepted = {k: [] for k in PUSHERS}
    rejected = []
    for kind, fn in PUSHERS.items():
        for item in payload.get(kind) or []:
            key = item.get(ID_FIELD[kind])
            try:
                with db.begin_nested():
                    fn(db, device, item)
                accepted[kind].append(key)
            except SyncError as e:
                rejected.append({"type": kind, "id": key, "reason": e.reason})
            except (KeyError, ValueError, ArithmeticError, TypeError):
                rejected.append({"type": kind, "id": key, "reason": "invalid"})
    db.commit()
    return {"accepted": accepted, "rejected": rejected}


# ---------- Dashboard actions ----------

def approve_count(db: Session, session: CountSession, reviewer_id: int):
    if session.status != "submitted":
        return
    for line in session.lines:
        move_stock(db, line.product, line.diff, "count", ref=f"C-{str(session.id)[:8]}",
                   employee_id=reviewer_id)
    session.status = "approved"
    session.reviewed_by = reviewer_id
    session.reviewed_at = now()
