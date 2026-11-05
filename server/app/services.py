"""Business rules shared by the device API and the dashboard."""
import os
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from decimal import ROUND_HALF_UP, Decimal

from sqlalchemy import func, or_, select, text, update
from sqlalchemy.orm import Session

from .db import next_version
from .models import (
    PIECE_NAMES, AuditLog, CountLine, CountSession, Device, Employee, Product, ReceiptFile, SupplierPayment, ProductBarcode, Receipt, ReceiptLine, Sale, SaleLine, Supplier,
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
    return {"id": p.id, "barcode": p.barcode, "name": p.name, "unit": p.unit, "piece_name": p.piece_name or "حبة",
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


LOCAL_TZ = ZoneInfo(os.environ.get("TZ_NAME", "Asia/Kuwait"))


def _small_int(value):
    try:
        v = int(value)
    except (TypeError, ValueError):
        return None
    return v if 0 < v < 2_000_000_000 else None


def _parse_date(value):
    try:
        return date.fromisoformat(str(value)[:10]) if value else None
    except ValueError:
        return None


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
    mtotal = data.get("ministry_total")
    try:
        mtotal = d3(mtotal) if mtotal not in (None, "") else None
    except Exception:
        mtotal = None
    sale = Sale(id=data["id"], device_id=device.id, employee_id=emp, device_no=_small_int(data.get("device_no")),
                ministry_invoice_no="".join(str(data.get("ministry_invoice_no") or "").split())[:30] or None,
                ministry_total=mtotal if mtotal is None or mtotal >= 0 else None,
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
    finished = _parse_time(data.get("finished_at"))
    committee = str(data.get("committee") or "").strip()[:20] or None
    s = CountSession(id=data["id"], device_id=device.id,
                     employee_id=_employee_id(db, data.get("employee_id")),
                     started_at=_parse_time(data.get("started_at")),
                     finished_at=finished, device_no=_small_int(data.get("device_no")),
                     count_date=_parse_date(data.get("count_date")) or finished.astimezone(LOCAL_TZ).date(),
                     committee=committee)
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
        line.unit_cost = line.product.cost
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
    inv_no = str(data.get("supplier_invoice_no") or "").strip()[:60] or None
    if inv_no and invoice_taken(db, sup.id, inv_no):
        raise SyncError("duplicate_invoice")
    total = data.get("supplier_invoice_total")
    try:
        total = d3(total) if total not in (None, "") else None
    except Exception:
        total = None
    if total is not None and total < 0:
        total = None
    r = Receipt(supplier_id=sup.id, status="pending", client_id=cid, device_id=device.id, received_by=emp,
                supplier_invoice_no=inv_no, supplier_invoice_total=total,
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
        line.unit_cost = line.product.cost
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
        if line.unit_cost is None:
            line.unit_cost = line.product.cost
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


# ---------- Stocktake by date: several committees (devices) counting on the same day ----------

def count_day(db: Session, day, statuses=("submitted", "approved")):
    """Per product, every committee's line for that date. Counts of the same product on the same day add up."""
    sessions = db.scalars(select(CountSession).where(CountSession.count_date == day, CountSession.status.in_(statuses))
                          .order_by(CountSession.committee, CountSession.no)).all()
    products = {}
    for s in sessions:
        for line in s.lines:
            products.setdefault(line.product_id, []).append((s, line))
    return sessions, products


def overlaps(db: Session, session: CountSession):
    """Other committees of the same day that counted any of this session's products."""
    if session.count_date is None:
        return []
    mine = {l.product_id for l in session.lines}
    others = db.scalars(select(CountSession).where(CountSession.count_date == session.count_date,
                                                   CountSession.id != session.id,
                                                   CountSession.status.in_(("submitted", "approved")))).all()
    return [o for o in others if mine & {l.product_id for l in o.lines}]


def approve_count_day(db: Session, day, reviewer_id: int) -> int:
    """Approve every waiting committee of a day at once. For each product the counted quantities are added up,
    and stock moves by (total counted - stock when the last of those counts reached the server)."""
    sessions, products = count_day(db, day, ("submitted",))
    if not sessions:
        raise EditError("مفيش لجان مستنية الاعتماد في اليوم ده")
    approved = db.scalars(select(CountSession).where(CountSession.count_date == day,
                                                     CountSession.status == "approved")).all()
    done = {l.product_id: s for s in approved for l in s.lines}
    clash = [pid for pid in products if pid in done]
    if clash:
        p = db.get(Product, clash[0])
        raise EditError(f"{p.name} اتعتمد قبل كده في جرد رقم {done[clash[0]].no}. صلّحه من «تعديل (المحاسبة)» بدل ما يتعد مرتين")
    for pid, items in products.items():
        total = sum((line.counted for _, line in items), Decimal(0))
        last = max(items, key=lambda x: x[0].synced_at)[1]
        move_stock(db, last.product, total - last.stock_at_sync, "count", ref=f"D-{day.isoformat()}",
                   employee_id=reviewer_id)
    t = now()
    for s in sessions:
        s.status, s.reviewed_by, s.reviewed_at = "approved", reviewer_id, t
    return len(sessions)


# ---------- Price history, from the audit log ----------

def price_history(db: Session, product_id: int | None = None, start=None, end=None, limit: int = 500):
    """Every sale-price or purchase-price change (and the first price when a product was added), newest first."""
    q = select(AuditLog).where(AuditLog.table_name == "products", AuditLog.action.in_(("INSERT", "UPDATE")),
                               or_(AuditLog.changes.has_key("price"), AuditLog.changes.has_key("cost")))
    if product_id is not None:
        q = q.where(AuditLog.row_id == str(product_id))
    if start is not None:
        q = q.where(AuditLog.at >= start, AuditLog.at < end)
    out = []
    for e in db.scalars(q.order_by(AuditLog.at.desc(), AuditLog.id.desc()).limit(limit)):
        def pair(k):
            v = e.changes.get(k)
            return (None, None) if v is None else (None if v[0] is None else Decimal(str(v[0])),
                                                   None if v[1] is None else Decimal(str(v[1])))
        out.append({"e": e, "product_id": int(e.row_id), "price": pair("price"), "cost": pair("cost")})
    return out


def sales_during_count(db: Session, sessions, product_ids) -> list:
    """Sales of counted products made while the stocktake was running (first count started .. last count reached
    the server). Selling is supposed to stop during a count: each of these can make the approved stock wrong
    by its quantity, so the day page lists them before approval. Times are the devices' clocks."""
    if not sessions or not product_ids:
        return []
    start = min(s.started_at or s.finished_at for s in sessions)
    end = max(s.synced_at for s in sessions)
    q = (select(Sale).join(SaleLine).where(Sale.created_at >= start, Sale.created_at <= end,
                                           SaleLine.product_id.in_(product_ids))
         .distinct().order_by(Sale.created_at))
    out = []
    for sale in db.scalars(q):
        names = sorted({l.product.name for l in sale.lines if l.product_id in product_ids})
        out.append((sale, names))
    return out


# ---------- Supplier invoices, their photos, payments and the supplier statement ----------

def invoice_taken(db: Session, supplier_id: int, invoice_no: str, except_id: int | None = None) -> Receipt | None:
    q = select(Receipt).where(Receipt.supplier_id == supplier_id, Receipt.supplier_invoice_no.is_not(None),
                              func.lower(Receipt.supplier_invoice_no) == invoice_no.strip().lower(),
                              Receipt.status.not_in(("cancelled", "rejected")))
    if except_id:
        q = q.where(Receipt.id != except_id)
    return db.scalar(q.limit(1))


ALLOWED_FILES = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp", "application/pdf": ".pdf"}


def save_receipt_file(db: Session, r: Receipt, data: bytes, content_type: str, employee_id=None, device_id=None,
                      client_id=None) -> ReceiptFile:
    """Store an invoice photo/scan under FILES_DIR/invoices/<voucher id>/. Same client_id twice = one file."""
    import secrets
    from pathlib import Path

    from . import config

    if client_id:
        old = db.scalar(select(ReceiptFile).where(ReceiptFile.client_id == client_id))
        if old:
            return old
    ext = ALLOWED_FILES.get((content_type or "").split(";")[0].strip().lower())
    if not ext:
        raise EditError("الملف لازم يكون صورة (JPG أو PNG) أو PDF")
    if not data:
        raise EditError("الملف فاضي")
    if len(data) > config.MAX_UPLOAD_MB * 1024 * 1024:
        raise EditError(f"الملف أكبر من {config.MAX_UPLOAD_MB} ميجا")
    rel = f"invoices/{r.id}/{secrets.token_hex(8)}{ext}"
    path = Path(config.FILES_DIR) / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    f = ReceiptFile(receipt_id=r.id, filename=rel, content_type=content_type.split(";")[0].strip().lower(), size=len(data),
                    uploaded_by=employee_id, device_id=device_id, client_id=client_id)
    db.add(f)
    return f


def receipt_value(r: Receipt):
    """(value at purchase price, estimated?) of what was received. Lines from before purchase prices were kept
    on vouchers use the product's current purchase price and make the value an estimate."""
    total, estimated = Decimal(0), False
    for line in r.lines:
        base = line.received_base or Decimal(0)
        cost = line.unit_cost
        if cost is None:
            cost, estimated = line.product.cost, estimated or base != 0
        total += base * cost
    return d3(total), estimated


def supplier_statement(db: Session, supplier, start: date, end: date):
    """Supplier statement for [start, end] (local dates): what was received and billed, what was paid,
    and the balance carried in from before and left at the end. Balance > 0 = the co-op owes the supplier."""
    from datetime import time as dtime

    begin = datetime.combine(start, dtime.min, LOCAL_TZ)
    stop = datetime.combine(end + timedelta(days=1), dtime.min, LOCAL_TZ)

    def billed(r):
        value, est = receipt_value(r)
        return (r.supplier_invoice_total if r.supplier_invoice_total is not None else value), value, est

    received = db.scalars(select(Receipt).where(Receipt.supplier_id == supplier.id, Receipt.status == "received")
                          .order_by(Receipt.received_at, Receipt.id)).all()
    when = lambda r: r.received_at or r.approved_at or r.created_at  # noqa: E731
    before = [r for r in received if when(r) < begin]
    inside = [r for r in received if begin <= when(r) < stop]
    pays = db.scalars(select(SupplierPayment).where(SupplierPayment.supplier_id == supplier.id)
                      .order_by(SupplierPayment.paid_on, SupplierPayment.id)).all()
    pay_before = sum((p.amount for p in pays if p.paid_on < start), Decimal(0))
    pay_inside = [p for p in pays if start <= p.paid_on <= end]
    opening = sum((billed(r)[0] for r in before), Decimal(0)) - pay_before
    rows = []
    for r in inside:
        amount, value, est = billed(r)
        rows.append({"r": r, "at": when(r), "amount": amount, "value": value, "estimated": est,
                     "diff": (r.supplier_invoice_total - value) if r.supplier_invoice_total is not None else None})
    total_billed = sum((x["amount"] for x in rows), Decimal(0))
    total_paid = sum((p.amount for p in pay_inside), Decimal(0))
    pending = db.scalar(select(func.count()).select_from(Receipt).where(
        Receipt.supplier_id == supplier.id, Receipt.status.in_(("open", "pending"))))
    return {"opening": d3(opening), "rows": rows, "payments": pay_inside, "billed": d3(total_billed),
            "paid": d3(total_paid), "closing": d3(opening + total_billed - total_paid), "pending": pending,
            "estimated": any(x["estimated"] and x["r"].supplier_invoice_total is None for x in rows)}


# ---------- Ministry ration invoices ----------

def ministry_flags(db: Session, sales) -> dict:
    """Per sale id: problems with its ministry invoice. "duplicate" = the same ministry invoice was sold more
    than once (any day, any device); "total" = the total on the ministry invoice differs from the sale;
    "missing" = no ministry invoice number."""
    nos = {s.ministry_invoice_no for s in sales if s.ministry_invoice_no}
    counts = dict(db.execute(select(Sale.ministry_invoice_no, func.count()).where(Sale.ministry_invoice_no.in_(nos))
                             .group_by(Sale.ministry_invoice_no)).all()) if nos else {}
    out = {}
    for s in sales:
        f = []
        if not s.ministry_invoice_no:
            f.append("missing")
        elif counts.get(s.ministry_invoice_no, 0) > 1:
            f.append("duplicate")
        if s.ministry_total is not None and s.ministry_total != s.total:
            f.append("total")
        out[s.id] = f
    return out

def barcode_action(db: Session, p: Product, data: dict) -> str:
    """One barcode change from the dashboard or the admin's device. Returns a short message; EditError if refused.
    {action: add, code, mode} | {action: remove, code} | {action: main, code} | {action: unit, piece_name, carton}"""
    action = data.get("action")
    code = "".join(str(data.get("code") or "").split())
    msg = ""
    if action == "add":
        mode = data.get("mode")
        allowed = ("kg",) if p.unit == "kg" else (("piece", "carton") if p.carton else ("piece",))
        if mode not in allowed:
            raise EditError("الصنف ده مالوش كرتون. اكتب عدد الحبات في الكرتون الأول" if mode == "carton"
                                 else "الوحدة دي ماتنفعش للصنف ده")
        if not code or not code.isalnum() or len(code) > 40:
            raise EditError("الباركود لازم يكون أرقام أو حروف من غير مسافات")
        if code == p.barcode or any(b.code == code for b in p.extra_barcodes):
            raise EditError(f"الباركود {code} متسجل على الصنف ده خلاص")
        other = code_taken(db, code, p.id)
        if other:
            raise EditError(f"الباركود {code} متسجل على «{other}»")
        p.extra_barcodes.append(ProductBarcode(code=code, mode=mode))
        msg = f"اتضاف {code} ({p.mode_name(mode)})"
    elif action == "remove":
        if code == p.barcode:
            spare = next((b for b in p.extra_barcodes if b.mode == ("kg" if p.unit == "kg" else "piece")), None)
            if not spare:
                raise EditError("ده الباركود الأساسي. ضيف باركود تاني للوحدة الأول، وبعدين امسح ده")
            p.barcode = spare.code
            p.extra_barcodes.remove(spare)
        else:
            b = next((b for b in p.extra_barcodes if b.code == code), None)
            if not b:
                raise EditError("الباركود ده مش على الصنف")
            p.extra_barcodes.remove(b)
        msg = f"اتشال {code}"
    elif action == "main":
        b = next((b for b in p.extra_barcodes if b.code == code and b.mode == ("kg" if p.unit == "kg" else "piece")), None)
        if not b:
            raise EditError("الأساسي لازم يكون باركود الحبة (أو الكيلو)")
        old = p.barcode
        p.extra_barcodes.remove(b)
        db.flush()
        p.barcode = code
        p.extra_barcodes.append(ProductBarcode(code=old, mode=b.mode))
        msg = f"{code} بقى الأساسي"
    elif action == "unit":
        pn = str(data.get("piece_name") or "")
        if p.unit != "kg":
            if pn not in PIECE_NAMES:
                raise EditError("اختار اسم الوحدة")
            p.piece_name = pn
            try:
                carton = int(str(data.get("carton", p.carton) or 0))
            except ValueError:
                raise EditError("عدد الحبات في الكرتون لازم يكون رقم صحيح")
            if carton < 0 or carton > 10000:
                raise EditError("عدد الحبات في الكرتون مش منطقي")
            if carton == 0 and any(b.mode == "carton" for b in p.extra_barcodes):
                raise EditError("الصنف عليه باركود كرتون. امسحه الأول أو سيب عدد الحبات")
            p.carton = carton
        msg = "اتحفظ"
    else:
        raise EditError("طلب مش مفهوم")
    bump(db, p)
    return msg

