"""Business rules shared by the device API and the dashboard."""
from datetime import datetime, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal

from sqlalchemy import or_, select, text, update
from sqlalchemy.orm import Session

from .db import next_version
from .models import (
    AuditLog, CountLine, CountSession, Device, Employee, Product, ProductBarcode, Receipt, ReceiptLine, Sale, SaleLine, Supplier,
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
    return {"id": e.id, "name": e.name, "role": e.role, "role_name": e.role_name, "pin_salt": e.pin_salt,
            "pin_hash": e.pin_hash, "active": e.active, "permissions": sorted(e.perms)}


def receipt_dict(r: Receipt):
    return {"id": r.id, "supplier": r.supplier.name, "status": r.status,
            "created_at": r.created_at.isoformat(), "note": r.note or "",
            "lines": [{"product_id": l.product_id, "mode": l.mode, "ordered": str(l.ordered)}
                      for l in r.lines if not l.extra]}


def decisions(db: Session, device: Device):
    """The supervisor's answer on vouchers this device made in the last 60 days."""
    since = now() - timedelta(days=60)
    rows = db.scalars(select(Receipt).where(Receipt.device_id == device.id, Receipt.client_id.is_not(None),
                                             Receipt.created_at >= since)).all()
    return [{
        "id": r.client_id,
        "status": r.status,  # pending | received (approved) | rejected
        "by": r.approver.name if r.approver else None,
        "at": r.approved_at.isoformat() if r.approved_at else None,
        "lines": [{"product_id": l.product_id, "qty": str(l.received), "mode": l.received_mode or l.mode} for l in r.lines],
    } for r in rows]


def pull(db: Session, since: int, device: Device | None = None):
    products = db.scalars(select(Product).where(Product.version > since)).all()
    employees = db.scalars(select(Employee).where(Employee.version > since)).all()
    stmt = select(Receipt).where(Receipt.version > since)
    if since == 0:
        stmt = stmt.where(Receipt.status == "open")  # a fresh device only needs work still to do
    stmt = stmt.where(Receipt.client_id.is_(None))  # device-made ones come back as "decisions" below
    receipts = db.scalars(stmt).all()
    versions = [since] + [x.version for x in (*products, *employees, *receipts)]
    return {
        "version": max(versions),
        "full": since == 0,
        "server_time": now().isoformat(),
        "products": [product_dict(p) for p in products],
        "employees": [employee_dict(e) for e in employees],
        "receipts": [receipt_dict(r) for r in receipts],
        "decisions": decisions(db, device) if device else [],
        # Small list, sent whole every time, for vouchers made on the device.
        "suppliers": [{"id": x.id, "name": x.name} for x in db.scalars(
            select(Supplier).where(Supplier.active.is_(True)).order_by(Supplier.name))],
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
    stock = []
    for ln in lines:
        p = _product(db, ln["product_id"])
        mode, qty = ln["mode"], d3(ln["qty"])
        if not _mode_ok(p, mode) or qty <= 0:
            raise SyncError("bad_line")
        price = d3(ln["unit_price"])
        cost = d3(p.cost * p.carton if mode == "carton" else p.cost)
        sale.lines.append(SaleLine(product_id=p.id, mode=mode, qty=qty, unit_price=price,
                                   unit_cost=cost, total=d3(price * qty)))
        stock.append((p, -p.to_base(qty, mode)))
    # The total is set before the first write, so the audit log never shows a sale "changing" while it is stored.
    sale.total = d3(sum(line.total for line in sale.lines))
    db.add(sale)
    for p, delta in stock:
        move_stock(db, p, delta, "sale", ref=str(sale.id), employee_id=emp)


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


def push_new_receipt(db: Session, device: Device, data: dict):
    """A delivery that arrived without a voucher: made and received on the device."""
    cid = str(data["id"])
    if db.scalar(select(Receipt.id).where(Receipt.client_id == cid)):
        return  # retry of an upload that already worked
    lines = data.get("lines") or []
    if not lines:
        raise SyncError("empty_receipt")
    sup = db.get(Supplier, data.get("supplier_id") or 0)
    if sup is None:
        name = str(data.get("supplier_name") or "").strip()[:200]
        if not name:
            raise SyncError("no_supplier")
        sup = db.scalar(select(Supplier).where(Supplier.name == name))
        if sup is None:
            sup = Supplier(name=name)
            db.add(sup)
            db.flush()
    emp = _employee_id(db, data.get("employee_id"))
    r = Receipt(supplier_id=sup.id, status="pending", client_id=cid, device_id=device.id, received_by=emp,
                received_at=_parse_time(data.get("received_at")), note="سند من الجهاز (من غير سند مسبق)",
                device_notes=(data.get("notes") or "").strip()[:500] or None)
    db.add(r)
    seen = set()
    for ln in lines:
        p = _product(db, ln["product_id"])
        mode, qty = ln["mode"], d3(ln["qty"])
        if not _mode_ok(p, mode) or qty <= 0 or p.id in seen:
            raise SyncError("bad_line")
        seen.add(p.id)
        r.lines.append(ReceiptLine(product_id=p.id, mode=mode, ordered=qty, received=qty, received_mode=mode,
                                   note=(str(ln.get("note") or "").strip()[:200]) or None))
    # No stock change yet: a supervisor approves it in the dashboard first.
    bump(db, r)


def approve_receipt(db: Session, r: Receipt, user_id: int, quantities: dict | None = None):
    """Supervisor approves a device-made voucher, optionally correcting quantities; stock goes up now."""
    if r.status != "pending":
        return
    for line in r.lines:
        q = (quantities or {}).get(line.id)
        if q is not None:
            line.received = line.ordered = d3(q)
    db.flush()
    for line in r.lines:
        move_stock(db, line.product, line.received_base, "receipt", ref=f"R-{r.id}", employee_id=user_id)
    r.status = "received"
    r.approved_by, r.approved_at = user_id, now()
    bump(db, r)


PUSHERS = {"sales": push_sale, "counts": push_count, "receipts": push_receipt, "new_receipts": push_new_receipt}
ID_FIELD = {"sales": "id", "counts": "id", "receipts": "receipt_id", "new_receipts": "id"}


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


# ---------- Accounting corrections and the audit log ----------

class EditError(ValueError):
    pass


def log_event(db: Session, action: str, actor: str | None = None, **details):
    """Things that are not a data change (logins, backups). Same append-only log as the triggers."""
    db.add(AuditLog(at=now(), actor=actor, table_name="app", row_id=action, action=action,
                    changes={k: [None, v] for k, v in details.items()}))


def set_actor(db: Session, actor: str, reason: str | None = None):
    """Who the audit triggers record for the rest of this transaction."""
    db.execute(text("SELECT set_config('tamween.actor', :a, true), set_config('tamween.reason', :r, true)"),
               {"a": actor, "r": reason or ""})


def _whole_ok(p: Product, mode: str, q: Decimal):
    if q < 0:
        raise EditError("الكمية مينفعش تكون بالسالب")
    if (p.unit != "kg" or mode == "carton") and q != q.to_integral_value():
        raise EditError(f"{p.name}: الكمية لازم تكون رقم صحيح")


def edit_sale(db: Session, sale: Sale, changes: dict, user_id: int, reason: str) -> int:
    """changes: {line_id: (qty, unit_price)} in each line's own unit. Stock follows the quantity change."""
    n = 0
    for line in sale.lines:
        if line.id not in changes:
            continue
        q, price = (d3(v) for v in changes[line.id])
        _whole_ok(line.product, line.mode, q)
        if price < 0:
            raise EditError("السعر مينفعش يكون بالسالب")
        if q == line.qty and price == line.unit_price:
            continue
        delta = line.product.to_base(q, line.mode) - line.product.to_base(line.qty, line.mode)
        move_stock(db, line.product, -delta, "edit", ref=str(sale.id), employee_id=user_id, note=reason)
        line.qty, line.unit_price, line.total = q, price, d3(q * price)
        n += 1
    sale.total = d3(sum(line.total for line in sale.lines))
    return n


def correct_receipt(db: Session, r: Receipt, changes: dict, user_id: int, reason: str) -> int:
    """changes: {line_id: received qty} in the unit it was received in. Only received vouchers."""
    if r.status != "received":
        raise EditError("التعديل للسند المستلم بس")
    n = 0
    for line in r.lines:
        if line.id not in changes:
            continue
        mode = line.received_mode or line.mode
        q = d3(changes[line.id])
        _whole_ok(line.product, mode, q)
        old = line.received or Decimal(0)
        if q == old and line.received is not None:
            continue
        delta = line.product.to_base(q, mode) - line.product.to_base(old, mode)
        move_stock(db, line.product, delta, "edit", ref=f"R-{r.id}", employee_id=user_id, note=reason)
        line.received, line.received_mode = q, mode
        n += 1
    if n:
        bump(db, r)
    return n


def correct_count(db: Session, c: CountSession, changes: dict, user_id: int, reason: str) -> int:
    """changes: {line_id: counted}. An approved count moves stock by the correction; a submitted one does not yet."""
    if c.status == "rejected":
        raise EditError("الجرد ده مرفوض. مفيش حاجة تتعدل فيه")
    n = 0
    for line in c.lines:
        if line.id not in changes:
            continue
        q = d3(changes[line.id])
        _whole_ok(line.product, "piece", q)
        if q == line.counted:
            continue
        if c.status == "approved":
            move_stock(db, line.product, q - line.counted, "edit", ref=f"C-{str(c.id)[:8]}", employee_id=user_id, note=reason)
        line.counted = q
        n += 1
    return n


def audit_for(db: Session, table: str, row_id, lines_table: str, line_ids) -> list[AuditLog]:
    ids = [str(i) for i in line_ids]
    cond = (AuditLog.table_name == table) & (AuditLog.row_id == str(row_id))
    if ids:
        cond = or_(cond, (AuditLog.table_name == lines_table) & AuditLog.row_id.in_(ids))
    return db.scalars(select(AuditLog).where(cond).order_by(AuditLog.at.desc(), AuditLog.id.desc())).all()


def actor_names(db: Session, entries) -> dict:
    emp = {int(a[4:]) for a in {e.actor for e in entries} if a and a.startswith("emp:")}
    dev = {int(a[4:]) for a in {e.actor for e in entries} if a and a.startswith("dev:")}
    names = {f"emp:{e.id}": e.name for e in db.scalars(select(Employee).where(Employee.id.in_(emp)))} if emp else {}
    if dev:
        names.update({f"dev:{d.id}": f"جهاز {d.name}" for d in db.scalars(select(Device).where(Device.id.in_(dev)))})
    return names
