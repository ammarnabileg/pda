"""Server-rendered Arabic dashboard for supervisors and admins."""
import csv
import io
import os
import shutil
import subprocess
from datetime import date, datetime, time, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path
from urllib.parse import urlencode
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response, StreamingResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy import Date, String, case, cast, func, or_, select
from sqlalchemy.orm import Session

from . import config, services
from .db import get_db
from .models import (
    ADMIN_ROLE, MODES, PERMISSIONS, UNITS, AuditLog, CountLine, CountSession, Device, Employee, Product, ProductBarcode, Receipt, ReceiptLine,
    Role, Sale, SaleLine, StockMove, Supplier, now,
)
from .security import hash_password, hash_pin, new_pairing_code, verify_password, verify_pin

TZ = ZoneInfo(os.environ.get("TZ_NAME", "Asia/Kuwait"))
templates = Jinja2Templates(directory=str(config.BASE_DIR / "app" / "templates"))
router = APIRouter()


# ---------- template helpers ----------

def fmt_money(v):
    return f"{Decimal(v or 0):,.3f}"


def fmt_qty(v, unit="piece"):
    v = Decimal(v or 0)
    if unit == "kg":
        return f"{v:,.3f}"
    return f"{v:,.0f}" if v == v.to_integral_value() else f"{v:,.3f}"


def fmt_dt(v):
    return v.astimezone(TZ).strftime("%Y-%m-%d %H:%M") if v else "—"


def base_text(p: Product, base):
    base = Decimal(base or 0)
    if p.unit == "kg":
        return f"{fmt_qty(base, 'kg')} كجم"
    text = f"{fmt_qty(base)} حبة"
    if p.carton and abs(base) >= p.carton and base == base.to_integral_value():
        c, r = divmod(int(abs(base)), p.carton)
        text += f" ({c} كرتون" + (f" و {r} حبة" if r else "") + ")"
    return text


templates.env.filters.update(money=fmt_money, qty=fmt_qty, dt=fmt_dt)
templates.env.globals.update(PERMISSIONS=PERMISSIONS, UNITS=UNITS, MODES=MODES, base_text=base_text)


def render(request: Request, name: str, ctx: dict | None = None, status: int = 200):
    ctx = dict(ctx or {})
    ctx["user"] = getattr(request.state, "user", None)
    ctx["flash"] = request.session.pop("flash", None)
    ctx["path"] = request.url.path
    return templates.TemplateResponse(request, name, ctx, status_code=status)


def flash(request: Request, msg: str, kind: str = "ok"):
    request.session["flash"] = {"msg": msg, "kind": kind}


def redirect(url: str):
    return RedirectResponse(url, status_code=303)


def client_ip(request: Request) -> str:
    return request.client.host if request.client else ""


class LoginRequired(Exception):
    pass


class Forbidden(Exception):
    pass


def current_user(request: Request, db: Session = Depends(get_db)) -> Employee:
    uid = request.session.get("uid")
    user = db.get(Employee, uid) if uid else None
    if not user or not user.active or not user.can_dashboard:
        raise LoginRequired()
    request.state.user = user
    services.set_actor(db, f"emp:{user.id}")  # recorded by the audit log for anything this request changes
    return user


def _needs(perm: str):
    def dep(user: Employee = Depends(current_user)) -> Employee:
        if not user.can(perm):
            raise Forbidden()
        return user
    dep.__name__ = f"need_{perm}"
    return dep


# One dependency per dashboard permission; every page except home asks for one.
need = {p: _needs(p) for p in PERMISSIONS}


def local_day_range(d_from: date, d_to: date):
    start = datetime.combine(d_from, time.min, TZ)
    end = datetime.combine(d_to + timedelta(days=1), time.min, TZ)
    return start, end


def parse_date(value, default: date) -> date:
    try:
        return date.fromisoformat(value) if value else default
    except ValueError:
        return default


def dec(value, default=None):
    try:
        v = Decimal(str(value).strip().replace(",", ""))
        return v if v.is_finite() else default
    except (InvalidOperation, AttributeError):
        return default


# ---------- auth ----------

def has_admin(db):
    return db.scalar(select(func.count()).select_from(Employee).where(
        Employee.role == ADMIN_ROLE, Employee.active.is_(True), Employee.password_hash.is_not(None))) > 0


@router.get("/login", response_class=HTMLResponse)
def login_form(request: Request, db: Session = Depends(get_db)):
    if not has_admin(db):
        return redirect("/setup")
    return render(request, "login.html")


@router.post("/login")
async def login(request: Request, db: Session = Depends(get_db)):
    form = await request.form()
    user = db.scalar(select(Employee).where(Employee.username == str(form.get("username", "")).strip()))
    if not user or not user.active or not user.can_dashboard or not verify_password(str(form.get("password", "")), user.password_hash):
        services.log_event(db, "login_failed", f"emp:{user.id}" if user else None,
                           username=str(form.get("username", ""))[:60], ip=client_ip(request))
        db.commit()
        return render(request, "login.html", {"error": "اسم المستخدم أو كلمة السر غلط", "username": form.get("username", "")}, 400)
    request.session.clear()
    request.session["uid"] = user.id
    services.log_event(db, "login", f"emp:{user.id}", ip=client_ip(request))
    db.commit()
    return redirect("/")


@router.post("/logout")
def logout(request: Request, db: Session = Depends(get_db)):
    if request.session.get("uid"):
        services.log_event(db, "logout", f"emp:{request.session['uid']}", ip=client_ip(request))
        db.commit()
    request.session.clear()
    return redirect("/login")


@router.get("/setup", response_class=HTMLResponse)
def setup_form(request: Request, db: Session = Depends(get_db)):
    if has_admin(db):
        return redirect("/login")
    return render(request, "setup.html")


@router.post("/setup")
async def setup(request: Request, db: Session = Depends(get_db)):
    if has_admin(db):
        return redirect("/login")
    f = await request.form()
    name, username = str(f.get("name", "")).strip(), str(f.get("username", "")).strip()
    password, pin = str(f.get("password", "")), str(f.get("pin", "")).strip()
    errors = validate_employee_fields(db, None, name, ADMIN_ROLE, pin, username, password, True)
    if errors:
        return render(request, "setup.html", {"errors": errors, "form": f}, 400)
    salt, h = hash_pin(pin)
    services.set_actor(db, "setup")
    emp = Employee(name=name, role=ADMIN_ROLE, pin_salt=salt, pin_hash=h, username=username,
                   password_hash=hash_password(password))
    services.bump(db, emp)
    db.add(emp)
    db.commit()
    request.session.clear()
    request.session["uid"] = emp.id
    flash(request, "تم إنشاء حساب المدير. ابدأ بإضافة الأصناف والأجهزة.")
    return redirect("/")


# ---------- home ----------

@router.get("/", response_class=HTMLResponse)
def home(request: Request, user=Depends(current_user), db: Session = Depends(get_db)):
    today = datetime.now(TZ).date()
    start, end = local_day_range(today, today)
    sales_today = db.execute(select(func.count(Sale.id), func.coalesce(func.sum(Sale.total), 0))
                             .where(Sale.created_at >= start, Sale.created_at < end)).one()
    low_q = select(Product).where(Product.active.is_(True), Product.stock <= Product.min_stock, Product.min_stock > 0)
    devices = db.scalars(select(Device).where(Device.active.is_(True)).order_by(Device.name)).all()
    t = now()
    stale = [d for d in devices if d.token_hash and (not d.last_seen or t - d.last_seen > timedelta(hours=1))]
    ctx = {
        "sales_count": sales_today[0], "sales_total": sales_today[1],
        "open_receipts": db.scalar(select(func.count()).select_from(Receipt).where(Receipt.status == "open")),
        "pending_receipts": db.scalar(select(func.count()).select_from(Receipt).where(Receipt.status == "pending")),
        "pending_counts": db.scalar(select(func.count()).select_from(CountSession).where(CountSession.status == "submitted")),
        "low_count": db.scalar(select(func.count()).select_from(low_q.subquery())),
        "low": db.scalars(low_q.order_by(Product.name).limit(10)).all(),
        "products": db.scalar(select(func.count()).select_from(Product).where(Product.active.is_(True))),
        "devices": devices, "stale": stale, "now": t,
        "recent": db.scalars(select(Sale).order_by(Sale.created_at.desc()).limit(8)).all(),
    }
    return render(request, "home.html", ctx)


# ---------- products ----------

PAGE_SIZE = 100


@router.get("/products", response_class=HTMLResponse)
def products(request: Request, q: str = "", status: str = "active", low: int = 0, unit: str = "", page: int = 1,
             user=Depends(need["products"]), db: Session = Depends(get_db)):
    stmt = select(Product)
    if status == "active":
        stmt = stmt.where(Product.active.is_(True))
    elif status == "inactive":
        stmt = stmt.where(Product.active.is_(False))
    if q.strip():
        like = f"%{q.strip()}%"
        extra = select(ProductBarcode.product_id).where(ProductBarcode.code.ilike(like))
        stmt = stmt.where(or_(Product.name.ilike(like), Product.barcode.ilike(like), Product.id.in_(extra)))
    if low:
        stmt = stmt.where(Product.stock <= Product.min_stock, Product.min_stock > 0)
    if unit in UNITS:
        stmt = stmt.where(Product.unit == unit)
    total = db.scalar(select(func.count()).select_from(stmt.subquery()))
    pages = max(1, -(-total // PAGE_SIZE))
    page = min(max(1, page), pages)
    items = db.scalars(stmt.order_by(Product.name).offset((page - 1) * PAGE_SIZE).limit(PAGE_SIZE)).all()
    params = {"q": q, "status": status, "low": low or "", "unit": unit}
    return render(request, "products.html", {
        "items": items, "total": total, "page": page, "pages": pages, **params, "offset": (page - 1) * PAGE_SIZE,
        "page_url": lambda n: "/products?" + urlencode({**{k: v for k, v in params.items() if v}, "page": n}),
        "filtered": bool(q.strip() or low or unit or status != "active"),
    })


def form_barcodes(f):
    """Extra barcode rows posted by the form: [(code, mode)], blanks skipped."""
    rows = []
    for code, mode in zip(f.getlist("xb_code"), f.getlist("xb_mode")):
        code = str(code).strip()
        if code:
            rows.append((code, str(mode)))
    return rows


def product_errors(db, p_id, f, extra=()):
    """Errors keyed by field, so the form can show each one next to its input."""
    errors = {}
    barcode, name = str(f.get("barcode", "")).strip(), str(f.get("name", "")).strip()
    if not barcode or not barcode.isalnum():
        errors["barcode"] = "الباركود مطلوب (أرقام أو حروف بدون مسافات)"
    else:
        other = services.code_taken(db, barcode, p_id)
        if other:
            errors["barcode"] = f"الباركود ده مستخدم للصنف: {other}"
    if not name:
        errors["name"] = "اسم الصنف مطلوب"
    unit = f.get("unit")
    if unit not in UNITS:
        errors["unit"] = "اختار الوحدة"
    price, cost = dec(f.get("price")), dec(f.get("cost") or 0)
    if price is None or price < 0:
        errors["price"] = "سعر البيع لازم يكون رقم، مثال 1.250"
    if cost is None or cost < 0:
        errors["cost"] = "سعر الشراء لازم يكون رقم، مثال 0.950"
    carton = str(f.get("carton") or "0").strip()
    if unit != "kg" and not carton.isdigit():
        errors["carton"] = "عدد الحبات في الكرتون لازم يكون رقم صحيح (أو 0)"
    if dec(f.get("min_stock") or 0) is None:
        errors["min_stock"] = "حد الطلب لازم يكون رقم"
    seen = {barcode}
    for code, mode in extra:
        if not code.isalnum():
            errors["barcodes"] = f"الباركود {code}: أرقام أو حروف بدون مسافات"
        elif code in seen:
            errors["barcodes"] = f"الباركود {code} متكرر في نفس الصنف"
        elif (other := services.code_taken(db, code, p_id)):
            errors["barcodes"] = f"الباركود {code} مستخدم للصنف: {other}"
        elif unit == "kg" and mode != "kg":
            errors["barcodes"] = "الصنف بالكيلو: كل الباركودات بتاعته بالكيلو"
        elif unit != "kg" and mode not in ("piece", "carton"):
            errors["barcodes"] = f"الباركود {code}: اختار حبة أو كرتون"
        elif mode == "carton" and not (carton.isdigit() and int(carton) > 0):
            errors["barcodes"] = "عشان تضيف باركود كرتون، اكتب عدد الحبات في الكرتون الأول"
        seen.add(code)
    return errors


def apply_product_form(db, p: Product, f, extra):
    p.barcode = str(f.get("barcode")).strip()
    p.name = str(f.get("name")).strip()
    p.unit = f.get("unit")
    p.price = services.d3(dec(f.get("price")))
    p.cost = services.d3(dec(f.get("cost") or 0))
    p.carton = 0 if p.unit == "kg" else int(str(f.get("carton") or "0").strip())
    p.min_stock = services.d3(dec(f.get("min_stock") or 0))
    p.active = f.get("active") == "1"
    # Update in place: removing and re-adding the same code in one save would hit the unique index.
    wanted = dict(extra)
    for b in list(p.extra_barcodes):
        if b.code in wanted:
            b.mode = wanted.pop(b.code)
        else:
            p.extra_barcodes.remove(b)
    db.flush()
    for code, mode in wanted.items():
        p.extra_barcodes.append(ProductBarcode(code=code, mode=mode))


def form_ctx(p, form, errors=None, moves=None, **extra):
    if form is not None:
        barcodes = form_barcodes(form) if hasattr(form, "getlist") else []
    else:
        barcodes = [(b.code, b.mode) for b in p.extra_barcodes] if p else []
    return {"p": p, "form": form, "errors": errors or {}, "moves": moves or [], "barcodes": barcodes, **extra}


@router.get("/products/new", response_class=HTMLResponse)
def product_new(request: Request, user=Depends(need["products"])):
    return render(request, "product_form.html", form_ctx(None, {"unit": "piece", "active": "1", "carton": "0", "cost": "0", "min_stock": "0", "stock": "0"}))


@router.post("/products/new")
async def product_create(request: Request, user=Depends(need["products"]), db: Session = Depends(get_db)):
    f = await request.form()
    extra = form_barcodes(f)
    errors = product_errors(db, None, f, extra)
    opening = dec(f.get("stock") or 0)
    if opening is None or opening < 0:
        errors["stock"] = "الرصيد الافتتاحي لازم يكون رقم"
    if errors:
        return render(request, "product_form.html", form_ctx(None, f, errors), 400)
    p = Product(stock=0)
    db.add(p)
    apply_product_form(db, p, f, extra)
    services.bump(db, p)
    db.flush()
    services.move_stock(db, p, opening, "manual", note="رصيد افتتاحي", employee_id=user.id)
    db.commit()
    flash(request, f"تمت إضافة {p.name}")
    return redirect("/products/new" if f.get("next") == "new" else f"/products/{p.id}")


@router.get("/products/{pid}", response_class=HTMLResponse)
def product_detail(pid: int, request: Request, user=Depends(need["products"]), db: Session = Depends(get_db)):
    p = db.get(Product, pid)
    if not p:
        return redirect("/products")
    moves = db.scalars(select(StockMove).where(StockMove.product_id == pid).order_by(StockMove.created_at.desc()).limit(50)).all()
    sale_refs = {m.ref for m in moves if m.ref and len(m.ref) == 36}
    sale_nos = dict(db.execute(select(cast(Sale.id, String), Sale.no).where(cast(Sale.id, String).in_(sale_refs))).all()) if sale_refs else {}
    return render(request, "product_form.html", form_ctx(p, None, moves=moves, sale_nos=sale_nos,
                  prices=_price_rows(db, services.price_history(db, p.id, limit=50)),
                  **history(db, "products", p.id, "product_barcodes", [b.id for b in p.extra_barcodes])))


@router.post("/products/{pid}")
async def product_update(pid: int, request: Request, user=Depends(need["products"]), db: Session = Depends(get_db)):
    p = db.get(Product, pid)
    if not p:
        return redirect("/products")
    f = await request.form()
    extra = form_barcodes(f)
    errors = product_errors(db, pid, f, extra)
    if errors:
        return render(request, "product_form.html", form_ctx(p, f, errors), 400)
    apply_product_form(db, p, f, extra)
    services.bump(db, p)
    db.commit()
    flash(request, f"تم حفظ {p.name}")
    return redirect(f"/products/{pid}")


@router.post("/products/{pid}/stock")
async def product_stock(pid: int, request: Request, user=Depends(need["stock_adjust"]), db: Session = Depends(get_db)):
    p = db.get(Product, pid)
    f = await request.form()
    new = dec(f.get("stock"))
    note = str(f.get("note", "")).strip()
    if not p or new is None or new < 0 or not note:
        flash(request, "اكتب الرصيد الجديد وسبب التعديل", "error")
        return redirect(f"/products/{pid}")
    services.move_stock(db, p, new - p.stock, "manual", note=note[:200], employee_id=user.id)
    db.commit()
    flash(request, "تم تعديل الرصيد")
    return redirect(f"/products/{pid}")


IMPORT_COLUMNS = ["barcode", "name", "unit", "price", "cost", "carton", "stock", "min_stock", "carton_barcode", "extra_barcodes"]


@router.get("/products-import", response_class=HTMLResponse)
def import_form(request: Request, user=Depends(need["products"])):
    return render(request, "product_import.html", {"columns": IMPORT_COLUMNS})


@router.get("/products-import/template.csv")
def import_template(user=Depends(need["products"])):
    body = (",".join(IMPORT_COLUMNS) + "\n"
            "6281000123456,أرز بسمتي ٥ كجم,piece,2.450,2.050,6,48,10,16281000123453,6281000123999\n"
            "2100000012345,سكر أبيض,kg,0.350,0.280,0,125,20,,\n")
    return Response("﻿" + body, media_type="text/csv; charset=utf-8",
                    headers={"Content-Disposition": "attachment; filename=products-template.csv"})


@router.post("/products-import", response_class=HTMLResponse)
async def import_products(request: Request, user=Depends(need["products"]), db: Session = Depends(get_db)):
    f = await request.form()
    upload = f.get("file")
    if not upload or not hasattr(upload, "read"):
        return render(request, "product_import.html", {"columns": IMPORT_COLUMNS, "errors": ["اختار ملف CSV"]}, 400)
    raw = await upload.read()
    text = None
    for enc in ("utf-8-sig", "cp1256"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    if text is None:
        return render(request, "product_import.html", {"columns": IMPORT_COLUMNS, "errors": ["الملف مش مقروء. احفظه من Excel كـ CSV UTF-8"]}, 400)
    rows = list(csv.DictReader(io.StringIO(text)))
    errors, created, updated = [], 0, 0
    for n, row in enumerate(rows, start=2):
        row = {k.strip().lower(): (v or "").strip() for k, v in row.items() if k}
        row.setdefault("unit", "piece")
        row["active"] = "1"
        existing = db.scalar(select(Product).where(Product.barcode == row.get("barcode", "")))
        extra = [(c, "carton") for c in [row.get("carton_barcode", "")] if c]
        extra += [(c.strip(), "kg" if row["unit"] == "kg" else "piece") for c in row.get("extra_barcodes", "").replace("|", " ").split() if c.strip()]
        if existing:  # keep barcodes the file does not mention
            extra = [(b.code, b.mode) for b in existing.extra_barcodes if b.code not in dict(extra)] + extra
        errs = list(product_errors(db, existing.id if existing else None, row, extra).values())
        stock = dec(row.get("stock")) if row.get("stock") else None
        if row.get("stock") and (stock is None or stock < 0):
            errs.append("الرصيد غلط")
        if errs:
            errors.append(f"سطر {n}: " + "، ".join(errs))
            continue
        p = existing or Product(stock=0)
        if not existing:
            db.add(p)
        apply_product_form(db, p, row, extra)
        services.bump(db, p)
        db.flush()
        if stock is not None:
            services.move_stock(db, p, stock - p.stock, "manual", note="استيراد من ملف", employee_id=user.id)
        created, updated = created + (not existing), updated + bool(existing)
    if errors:
        db.rollback()
        return render(request, "product_import.html", {"columns": IMPORT_COLUMNS, "errors": errors[:50] + (["…"] if len(errors) > 50 else []), "note": "لم يتم حفظ أي صنف. صلّح الأخطاء وارفع الملف تاني."}, 400)
    db.commit()
    flash(request, f"تم الاستيراد: {created} صنف جديد، {updated} صنف اتعدل")
    return redirect("/products")


# ---------- suppliers ----------

@router.get("/suppliers", response_class=HTMLResponse)
def suppliers(request: Request, user=Depends(need["products"]), db: Session = Depends(get_db)):
    return render(request, "suppliers.html", {"items": db.scalars(select(Supplier).order_by(Supplier.active.desc(), Supplier.name)).all()})


@router.post("/suppliers")
async def supplier_save(request: Request, user=Depends(need["products"]), db: Session = Depends(get_db)):
    f = await request.form()
    name = str(f.get("name", "")).strip()
    sid = int(f.get("id") or 0)
    if not name:
        flash(request, "اسم المورد مطلوب", "error")
        return redirect("/suppliers")
    dup = db.scalar(select(Supplier).where(Supplier.name == name, Supplier.id != sid))
    if dup:
        flash(request, "فيه مورد بنفس الاسم", "error")
        return redirect("/suppliers")
    s = db.get(Supplier, sid) if sid else Supplier()
    s.name, s.phone = name, str(f.get("phone", "")).strip() or None
    s.active = f.get("active", "1") == "1"
    db.add(s)
    db.commit()
    flash(request, "تم حفظ المورد")
    return redirect("/suppliers")


# ---------- receipts ----------

@router.get("/receipts", response_class=HTMLResponse)
def receipts(request: Request, status: str = "open", user=Depends(need["receipts"]), db: Session = Depends(get_db)):
    stmt = select(Receipt).order_by(Receipt.created_at.desc()).limit(200)
    if status in ("open", "pending", "received", "cancelled", "rejected"):
        stmt = stmt.where(Receipt.status == status)
    pending = db.scalar(select(func.count()).select_from(Receipt).where(Receipt.status == "pending"))
    return render(request, "receipts.html", {"items": db.scalars(stmt).all(), "status": status, "pending": pending})


def receipt_form_ctx(db, r=None, form=None, errors=None):
    return {"r": r, "form": form, "errors": errors or [],
            "suppliers": db.scalars(select(Supplier).where(Supplier.active.is_(True)).order_by(Supplier.name)).all(),
            "products": db.scalars(select(Product).where(Product.active.is_(True)).order_by(Product.name)).all()}


def parse_receipt_lines(db, f):
    errors, lines, seen = [], [], set()
    for i, (prod, mode, qty) in enumerate(zip(f.getlist("product"), f.getlist("mode"), f.getlist("qty")), start=1):
        prod, qty_s = prod.strip(), qty.strip()
        if not prod and not qty_s:
            continue
        p, _ = services.find_by_code(db, prod.split(" ")[0])
        q = dec(qty_s)
        if not p:
            errors.append(f"سطر {i}: الصنف غير موجود")
            continue
        if p.id in seen:
            errors.append(f"سطر {i}: {p.name} متكرر")
            continue
        if mode not in MODES or (p.unit == "kg") != (mode == "kg") or (mode == "carton" and not p.carton):
            errors.append(f"سطر {i}: الوحدة لا تناسب {p.name}")
            continue
        if q is None or q <= 0 or (mode != "kg" and q != q.to_integral_value()):
            errors.append(f"سطر {i}: الكمية غلط")
            continue
        seen.add(p.id)
        lines.append((p, mode, services.d3(q)))
    if not lines and not errors:
        errors.append("أضف صنف واحد على الأقل")
    return errors, lines


async def save_receipt(request, db, r: Receipt | None):
    f = await request.form()
    errors, lines = parse_receipt_lines(db, f)
    sup = db.get(Supplier, int(f.get("supplier_id") or 0))
    if not sup:
        errors.insert(0, "اختار المورد")
    if errors:
        return None, render(request, "receipt_form.html", receipt_form_ctx(db, r, f, errors), 400)
    if r is None:
        r = Receipt()
        db.add(r)
    r.supplier_id = sup.id
    r.note = str(f.get("note", "")).strip() or None
    r.lines.clear()
    db.flush()
    for p, mode, q in lines:
        r.lines.append(ReceiptLine(product_id=p.id, mode=mode, ordered=q))
    services.bump(db, r)
    db.commit()
    return r, None


@router.get("/receipts/new", response_class=HTMLResponse)
def receipt_new(request: Request, user=Depends(need["receipts"]), db: Session = Depends(get_db)):
    return render(request, "receipt_form.html", receipt_form_ctx(db))


@router.post("/receipts/new")
async def receipt_create(request: Request, user=Depends(need["receipts"]), db: Session = Depends(get_db)):
    r, err = await save_receipt(request, db, None)
    if err:
        return err
    flash(request, f"تم إنشاء السند {r.id}. سيظهر على الأجهزة خلال دقيقة.")
    return redirect(f"/receipts/{r.id}")


@router.get("/receipts/{rid}", response_class=HTMLResponse)
def receipt_detail(rid: int, request: Request, user=Depends(need["receipts"]), db: Session = Depends(get_db)):
    r = db.get(Receipt, rid)
    if not r:
        return redirect("/receipts")
    return render(request, "receipt.html", {"r": r, **history(db, "receipts", r.id, "receipt_lines", [l.id for l in r.lines])})


@router.get("/receipts/{rid}/edit", response_class=HTMLResponse)
def receipt_edit(rid: int, request: Request, user=Depends(need["receipts"]), db: Session = Depends(get_db)):
    r = db.get(Receipt, rid)
    if not r or r.status != "open":
        return redirect(f"/receipts/{rid}")
    return render(request, "receipt_form.html", receipt_form_ctx(db, r))


@router.post("/receipts/{rid}/edit")
async def receipt_update(rid: int, request: Request, user=Depends(need["receipts"]), db: Session = Depends(get_db)):
    r = db.get(Receipt, rid)
    if not r or r.status != "open":
        flash(request, "السند ده اتقفل ومينفعش يتعدل", "error")
        return redirect(f"/receipts/{rid}")
    r, err = await save_receipt(request, db, r)
    if err:
        return err
    flash(request, "تم حفظ السند")
    return redirect(f"/receipts/{r.id}")


@router.post("/receipts/{rid}/approve")
async def receipt_approve(rid: int, request: Request, user=Depends(need["receipts"]), db: Session = Depends(get_db)):
    r = db.get(Receipt, rid)
    if not r or r.status != "pending":
        return redirect(f"/receipts/{rid}")
    f = await request.form()
    quantities, bad = {}, []
    for line in r.lines:
        raw = str(f.get(f"q_{line.id}", "")).strip()
        if raw:
            q = dec(raw)
            if q is None or q < 0 or (line.mode != "kg" and q != q.to_integral_value()):
                bad.append(line.product.name)
            else:
                quantities[line.id] = q
    if bad:
        flash(request, "كمية غلط في: " + "، ".join(bad), "error")
        return redirect(f"/receipts/{rid}")
    services.approve_receipt(db, r, user.id, quantities)
    db.commit()
    flash(request, f"تمت الموافقة على السند {r.id} وزيادة الأرصدة")
    return redirect(f"/receipts/{rid}")


@router.post("/receipts/{rid}/reject")
def receipt_reject(rid: int, request: Request, user=Depends(need["receipts"]), db: Session = Depends(get_db)):
    r = db.get(Receipt, rid)
    if r and r.status == "pending":
        r.status, r.approved_by, r.approved_at = "rejected", user.id, now()
        services.bump(db, r)
        db.commit()
        flash(request, "تم رفض السند، والأرصدة ما اتغيرتش")
    return redirect(f"/receipts/{rid}")


@router.post("/receipts/{rid}/cancel")
def receipt_cancel(rid: int, request: Request, user=Depends(need["receipts"]), db: Session = Depends(get_db)):
    r = db.get(Receipt, rid)
    if r and r.status == "open":
        r.status = "cancelled"
        services.bump(db, r)
        db.commit()
        flash(request, "تم إلغاء السند")
    return redirect(f"/receipts/{rid}")


# ---------- sales & reports ----------

@router.get("/sales", response_class=HTMLResponse)
def sales(request: Request, d_from: str = "", d_to: str = "", employee: int = 0, user=Depends(need["sales"]), db: Session = Depends(get_db)):
    today = datetime.now(TZ).date()
    f, t = parse_date(d_from, today), parse_date(d_to, today)
    start, end = local_day_range(f, t)
    stmt = select(Sale).where(Sale.created_at >= start, Sale.created_at < end)
    if employee:
        stmt = stmt.where(Sale.employee_id == employee)
    items = db.scalars(stmt.order_by(Sale.created_at.desc()).limit(1000)).all()
    return render(request, "sales.html", {
        "items": items, "d_from": f, "d_to": t, "employee": employee,
        "total": sum((s.total for s in items), Decimal(0)),
        "employees": db.scalars(select(Employee).order_by(Employee.name)).all()})


@router.get("/sales/{sid}", response_class=HTMLResponse)
def sale_detail(sid: str, request: Request, user=Depends(need["sales"]), db: Session = Depends(get_db)):
    try:
        s = db.get(Sale, sid)
    except Exception:
        s = None
    if not s:
        return redirect("/sales")
    return render(request, "sale.html", {"s": s, **history(db, "sales", s.id, "sale_lines", [l.id for l in s.lines])})


@router.get("/reports", response_class=HTMLResponse)
def reports(request: Request, d_from: str = "", d_to: str = "", user=Depends(need["sales"]), db: Session = Depends(get_db)):
    today = datetime.now(TZ).date()
    f, t = parse_date(d_from, today.replace(day=1)), parse_date(d_to, today)
    start, end = local_day_range(f, t)
    in_range = (Sale.created_at >= start, Sale.created_at < end)
    local_day = cast(func.timezone(str(TZ), Sale.created_at), Date)
    cost = func.sum(SaleLine.unit_cost * SaleLine.qty)
    days = db.execute(
        select(local_day.label("day"), func.count(func.distinct(Sale.id)), func.sum(SaleLine.total), cost)
        .join(SaleLine, SaleLine.sale_id == Sale.id).where(*in_range).group_by("day").order_by("day")
    ).all()
    top = db.execute(
        select(Product, func.sum(SaleLine.qty * case((SaleLine.mode == "carton", Product.carton), else_=1)), func.sum(SaleLine.total))
        .join(SaleLine, SaleLine.product_id == Product.id).join(Sale, Sale.id == SaleLine.sale_id)
        .where(*in_range).group_by(Product.id).order_by(func.sum(SaleLine.total).desc()).limit(20)
    ).all()
    by_emp = db.execute(
        select(Employee.name, func.count(Sale.id), func.sum(Sale.total))
        .select_from(Sale).outerjoin(Employee, Employee.id == Sale.employee_id)
        .where(*in_range).group_by(Employee.name).order_by(func.sum(Sale.total).desc())
    ).all()
    totals = {"count": sum(d[1] for d in days), "sales": sum((d[2] or 0 for d in days), Decimal(0)),
              "cost": sum((d[3] or 0 for d in days), Decimal(0))}
    totals["profit"] = totals["sales"] - totals["cost"]
    if request.query_params.get("csv"):
        out = io.StringIO()
        w = csv.writer(out)
        w.writerow(["اليوم", "عدد الفواتير", "المبيعات", "التكلفة", "الربح"])
        for d in days:
            w.writerow([d[0], d[1], fmt_money(d[2]), fmt_money(d[3]), fmt_money((d[2] or 0) - (d[3] or 0))])
        return Response("﻿" + out.getvalue(), media_type="text/csv; charset=utf-8",
                        headers={"Content-Disposition": f"attachment; filename=sales-{f}-{t}.csv"})
    return render(request, "reports.html", {"days": days, "top": top, "by_emp": by_emp, "totals": totals,
                                            "d_from": f, "d_to": t,
                                            "csv_url": "/reports?" + urlencode({"d_from": f, "d_to": t, "csv": 1})})


# ---------- counts ----------

@router.get("/counts", response_class=HTMLResponse)
def counts(request: Request, status: str = "submitted", user=Depends(need["counts"]), db: Session = Depends(get_db)):
    stmt = select(CountSession).order_by(CountSession.count_date.desc().nulls_last(), CountSession.committee,
                                         CountSession.no.desc()).limit(300)
    if status in ("submitted", "approved", "rejected"):
        stmt = stmt.where(CountSession.status == status)
    items = db.scalars(stmt).all()
    days = {}
    for c in items:
        days.setdefault(c.count_date, []).append(c)
    return render(request, "counts.html", {"days": days, "status": status, "count": len(items)})


@router.get("/counts/day/{day}", response_class=HTMLResponse)
def count_day_page(day: str, request: Request, user=Depends(need["counts"]), db: Session = Depends(get_db)):
    d = parse_date(day, None)
    if d is None:
        return redirect("/counts")
    sessions, products = services.count_day(db, d)
    rows = []
    for pid, items in products.items():
        p = items[0][1].product
        waiting = [(s, l) for s, l in items if s.status == "submitted"]
        total = sum((l.counted for _, l in items), Decimal(0))
        last = max(items, key=lambda x: x[0].synced_at)[1]
        rows.append({"p": p, "lines": items, "total": total, "stock": last.stock_at_sync, "diff": total - last.stock_at_sync,
                     "waiting": bool(waiting)})
    rows.sort(key=lambda r: (r["diff"] == 0, r["p"].name))
    value = sum((r["diff"] * r["p"].cost for r in rows if r["waiting"]), Decimal(0))
    during = services.sales_during_count(db, sessions, set(products))
    return render(request, "count_day.html", {"day": d, "sessions": sessions, "rows": rows, "value": value, "during": during,
                                              "waiting": [s for s in sessions if s.status == "submitted"]})


@router.post("/counts/day/{day}/approve")
def count_day_approve(day: str, request: Request, user=Depends(need["counts"]), db: Session = Depends(get_db)):
    d = parse_date(day, None)
    if d is None:
        return redirect("/counts")
    try:
        n = services.approve_count_day(db, d, user.id)
    except services.EditError as e:
        db.rollback()
        flash(request, str(e), "error")
        return redirect(f"/counts/day/{d}")
    db.commit()
    flash(request, f"تم اعتماد {n} لجنة مع بعض وتعديل الأرصدة")
    return redirect(f"/counts/day/{d}")


@router.get("/counts/{cid}", response_class=HTMLResponse)
def count_detail(cid: str, request: Request, user=Depends(need["counts"]), db: Session = Depends(get_db)):
    try:
        c = db.get(CountSession, cid)
    except Exception:
        c = None
    if not c:
        return redirect("/counts")
    value = sum((l.diff * l.product.cost for l in c.lines), Decimal(0))
    stats = {"all": len(c.lines), "same": sum(1 for l in c.lines if l.diff == 0),
             "short": sum(1 for l in c.lines if l.diff < 0), "over": sum(1 for l in c.lines if l.diff > 0)}
    only = request.query_params.get("only") == "diff"
    lines = [l for l in c.lines if not only or l.diff != 0]
    return render(request, "count.html", {"c": c, "value": value, "stats": stats, "lines": lines, "only": only,
                                          "others": services.overlaps(db, c) if c.status == "submitted" else [],
                                          **history(db, "count_sessions", c.id, "count_lines", [l.id for l in c.lines])})


@router.post("/counts/{cid}/{action}")
def count_review(cid: str, action: str, request: Request, user=Depends(need["counts"]), db: Session = Depends(get_db)):
    c = db.get(CountSession, cid)
    if not c or c.status != "submitted" or action not in ("approve", "reject"):
        return redirect("/counts")
    if action == "approve" and services.overlaps(db, c):
        flash(request, "فيه لجنة تانية في نفس اليوم عدّت نفس الأصناف. اعتمد الجرد كله مع بعض من صفحة اليوم، "
                       "علشان الكميات تتجمع وماتتحسبش مرتين.", "error")
        return redirect(f"/counts/day/{c.count_date}")
    if action == "approve":
        services.approve_count(db, c, user.id)
        flash(request, "تم اعتماد الجرد وتعديل الأرصدة")
    else:
        c.status, c.reviewed_by, c.reviewed_at = "rejected", user.id, now()
        flash(request, "تم رفض الجرد بدون تعديل الأرصدة")
    db.commit()
    return redirect(f"/counts/{cid}")


# ---------- accounting: corrections after a record is closed, and the audit log ----------

FIELD_NAMES = {
    "qty": "الكمية", "unit_price": "السعر", "total": "الإجمالي", "received": "المستلم", "received_mode": "وحدة الاستلام",
    "counted": "المعدود", "status": "الحالة", "note": "ملاحظة", "ordered": "المطلوب", "mode": "الوحدة",
    "received_at": "وقت الاستلام", "received_by": "استلمه", "approved_by": "وافق عليه", "approved_at": "وقت الموافقة",
    "reviewed_by": "راجعه", "reviewed_at": "وقت المراجعة", "supplier_id": "المورد", "device_notes": "ملاحظات الجهاز",
    "product_id": "الصنف", "extra": "زائد", "stock_at_sync": "الرصيد وقت الوصول",
    "name": "الاسم", "barcode": "الباركود", "price": "سعر البيع", "cost": "سعر الشراء", "carton": "حبات الكرتون",
    "unit": "نوع البيع", "min_stock": "حد الطلب", "active": "فعّال", "role": "الدور", "username": "اسم المستخدم",
    "pin_hash": "الرقم السري", "pin_salt": "الرقم السري (ملح)", "password_hash": "كلمة سر اللوحة",
    "token_hash": "ربط الجهاز", "pairing_code": "كود الربط", "pairing_expires": "صلاحية كود الربط",
    "paired_at": "وقت الربط", "app_version": "نسخة التطبيق", "permissions": "الصلاحيات", "code": "الباركود",
    "key": "المفتاح", "employee_id": "الموظف", "device_id": "الجهاز", "created_at": "اتعمل", "synced_at": "وصل للسيرفر",
    "finished_at": "خلص على الجهاز", "started_at": "بدأ", "client_id": "رقم الجهاز", "receipt_id": "السند",
    "ip": "عنوان الكمبيوتر", "unit_cost": "التكلفة",
}
HIDDEN_ON_CREATE = {"id", "pin_salt", "version"}
TABLE_NAMES = {"sales": "فاتورة", "sale_lines": "سطر فاتورة", "receipts": "سند", "receipt_lines": "سطر سند",
               "count_sessions": "جرد", "count_lines": "سطر جرد", "products": "صنف", "product_barcodes": "باركود إضافي",
               "suppliers": "مورد", "employees": "موظف", "roles": "دور", "devices": "جهاز"}
EVENT_NAMES = {"login": "دخول اللوحة", "login_failed": "محاولة دخول فاشلة", "logout": "خروج من اللوحة",
               "backup_download": "تنزيل نسخة احتياطية"}
ACTION_NAMES = {"INSERT": ("اتضاف", "p-ok"), "DELETE": ("اتشال", "p-red")}
ACTOR_NAMES = {"system": "النظام", "setup": "الإعداد الأول"}
# Log filters: which tables each one shows. "accounting" users see only the first three.
LOG_GROUPS = {"sales": ("الفواتير", ("sales", "sale_lines")), "receipts": ("السندات", ("receipts", "receipt_lines")),
              "counts": ("الجرد", ("count_sessions", "count_lines")),
              "products": ("الأصناف والموردين", ("products", "product_barcodes", "suppliers")),
              "people": ("الموظفين والأدوار", ("employees", "roles")), "devices": ("الأجهزة", ("devices",)),
              "app": ("الدخول والنسخ الاحتياطي", ("app",))}
ACCOUNTING_GROUPS = ("sales", "receipts", "counts")
STATUS_NAMES = {"open": "مفتوح", "received": "مستلم", "cancelled": "ملغي", "pending": "مستني موافقة",
                "rejected": "مرفوض", "submitted": "مستني المراجعة", "approved": "معتمد"}


def _audit_value(key, v):
    if v is None:
        return "—"
    if v == "***":
        return "(مخفي)"
    if key == "status":
        return STATUS_NAMES.get(v, v)
    if key == "unit":
        return UNITS.get(v, v)
    if key == "permissions" and isinstance(v, str):
        return "، ".join(PERMISSIONS[p][0].split(":")[0] for p in v.split(",") if p in PERMISSIONS) or "—"
    if key in ("mode", "received_mode"):
        return MODES.get(v, v)
    if isinstance(v, bool):
        return "نعم" if v else "لا"
    if key in ("unit_price", "total", "unit_cost", "price", "cost"):
        return fmt_money(Decimal(str(v)))
    if key in ("qty", "received", "counted", "ordered", "stock_at_sync", "min_stock"):
        return fmt_qty(Decimal(str(v)))
    if isinstance(v, str) and len(v) > 18 and v[4:5] == "-" and "T" in v:
        try:
            return fmt_dt(datetime.fromisoformat(v))
        except ValueError:
            return v
    return str(v)


REF_FIELDS = {"employee_id": Employee, "received_by": Employee, "approved_by": Employee, "reviewed_by": Employee,
              "device_id": Device, "supplier_id": Supplier, "product_id": Product}


def _ref_names(db, entries):
    """Names for the ids in the log (employee 3 -> its name), looked up once per page."""
    want = {}
    for e in entries:
        for k, pair in e.changes.items():
            if k in REF_FIELDS:
                want.setdefault(REF_FIELDS[k], set()).update(v for v in pair if isinstance(v, int))
    out = {}
    for model, ids in want.items():
        if ids:
            for obj in db.scalars(select(model).where(model.id.in_(ids))):
                out[(model, obj.id)] = obj.name
    return out


def audit_view(db, entries):
    names = services.actor_names(db, entries)
    refs = _ref_names(db, entries)

    def val(k, v):
        if k in REF_FIELDS and isinstance(v, int):
            return refs.get((REF_FIELDS[k], v), f"#{v}")
        return _audit_value(k, v)

    rows = []
    for e in entries:
        items = e.changes.items()
        if e.action == "INSERT":
            items = [(k, v) for k, v in items if k not in HIDDEN_ON_CREATE]
        changes = [(FIELD_NAMES.get(k, k), val(k, old), val(k, new)) for k, (old, new) in items]
        if e.actor:
            who = names.get(e.actor) or ACTOR_NAMES.get(e.actor, e.actor)
        else:
            who = "مجهول" if e.table_name == "app" else "من خارج اللوحة والأجهزة (سكربت أو SQL)"
        what = EVENT_NAMES.get(e.action, e.action) if e.table_name == "app" else TABLE_NAMES.get(e.table_name, e.table_name)
        rows.append({"e": e, "who": who, "what": what, "changes": changes, "is_event": e.table_name == "app",
                     "action": ACTION_NAMES.get(e.action)})
    return rows


def history(db, table, row_id, lines_table, line_ids):
    return {"history": audit_view(db, services.audit_for(db, table, row_id, lines_table, line_ids))}


def _num(f, name):
    v = dec(f.get(name))
    if v is None:
        raise services.EditError("فيه خانة فاضية أو رقم غلط")
    return v


def _correct_page(request, kind, obj, rows, errors=None, reason=""):
    return render(request, "correct.html", {"kind": kind, "obj": obj, "rows": rows, "errors": errors, "reason": reason},
                  400 if errors else 200)


def _sale_rows(s, f=None):
    return [{"id": l.id, "name": l.product.name, "unit": MODES[l.mode],
             "fields": [("q", "الكمية", f.get(f"q_{l.id}") if f else fmt_qty(l.qty, l.product.unit)),
                        ("p", "السعر", f.get(f"p_{l.id}") if f else fmt_money(l.unit_price))]} for l in s.lines]


def _receipt_rows(r, f=None):
    return [{"id": l.id, "name": l.product.name, "unit": MODES[l.received_mode or l.mode],
             "fields": [("q", "المستلم", f.get(f"q_{l.id}") if f else fmt_qty(l.received or 0, l.product.unit))]}
            for l in r.lines]


def _count_rows(c, f=None):
    return [{"id": l.id, "name": l.product.name, "unit": "كجم" if l.product.unit == "kg" else "حبة",
             "fields": [("q", "المعدود", f.get(f"q_{l.id}") if f else fmt_qty(l.counted, l.product.unit))]} for l in c.lines]


async def _correct(request, db, user, kind, obj, rows_fn, apply, back):
    f = await request.form()
    reason = str(f.get("reason", "")).strip()
    try:
        if len(reason) < 3:
            raise services.EditError("اكتب سبب التعديل")
        if kind == "sale":
            changes = {l.id: (_num(f, f"q_{l.id}"), _num(f, f"p_{l.id}")) for l in obj.lines}
        else:
            changes = {l.id: _num(f, f"q_{l.id}") for l in obj.lines}
        services.set_actor(db, f"emp:{user.id}", reason)
        n = apply(db, obj, changes, user.id, reason)
    except services.EditError as e:
        db.rollback()
        return _correct_page(request, kind, obj, rows_fn(obj, f), [str(e)], reason)
    if not n:
        db.rollback()
        return _correct_page(request, kind, obj, rows_fn(obj, f), ["مفيش حاجة اتغيّرت"], reason)
    db.commit()
    flash(request, f"تم تعديل {n} سطر، واتسجل في سجل التعديلات")
    return redirect(back)


@router.get("/accounting/sales/{sid}", response_class=HTMLResponse)
def sale_correct_form(sid: str, request: Request, user=Depends(need["accounting"]), db: Session = Depends(get_db)):
    s = db.get(Sale, sid)
    return _correct_page(request, "sale", s, _sale_rows(s)) if s else redirect("/sales")


@router.post("/accounting/sales/{sid}")
async def sale_correct(sid: str, request: Request, user=Depends(need["accounting"]), db: Session = Depends(get_db)):
    s = db.get(Sale, sid)
    if not s:
        return redirect("/sales")
    return await _correct(request, db, user, "sale", s, _sale_rows, services.edit_sale, f"/sales/{sid}")


@router.get("/accounting/receipts/{rid}", response_class=HTMLResponse)
def receipt_correct_form(rid: int, request: Request, user=Depends(need["accounting"]), db: Session = Depends(get_db)):
    r = db.get(Receipt, rid)
    if not r or r.status != "received":
        return redirect(f"/receipts/{rid}")
    return _correct_page(request, "receipt", r, _receipt_rows(r))


@router.post("/accounting/receipts/{rid}")
async def receipt_correct(rid: int, request: Request, user=Depends(need["accounting"]), db: Session = Depends(get_db)):
    r = db.get(Receipt, rid)
    if not r or r.status != "received":
        return redirect(f"/receipts/{rid}")
    return await _correct(request, db, user, "receipt", r, _receipt_rows, services.correct_receipt, f"/receipts/{rid}")


@router.get("/accounting/counts/{cid}", response_class=HTMLResponse)
def count_correct_form(cid: str, request: Request, user=Depends(need["accounting"]), db: Session = Depends(get_db)):
    c = db.get(CountSession, cid)
    if not c or c.status == "rejected":
        return redirect(f"/counts/{cid}")
    return _correct_page(request, "count", c, _count_rows(c))


@router.post("/accounting/counts/{cid}")
async def count_correct(cid: str, request: Request, user=Depends(need["accounting"]), db: Session = Depends(get_db)):
    c = db.get(CountSession, cid)
    if not c or c.status == "rejected":
        return redirect(f"/counts/{cid}")
    return await _correct(request, db, user, "count", c, _count_rows, services.correct_count, f"/counts/{cid}")


def _price_rows(db, items):
    names = services.actor_names(db, [i["e"] for i in items])
    products = {p.id: p for p in db.scalars(select(Product).where(Product.id.in_({i["product_id"] for i in items})))} if items else {}
    rows = []
    for i in items:
        e = i["e"]
        (po, pn), (co, cn) = i["price"], i["cost"]
        pct = (pn - po) / po * 100 if po and pn is not None else None
        who = names.get(e.actor) or ACTOR_NAMES.get(e.actor, "من خارج اللوحة (سكربت أو SQL)" if not e.actor else e.actor)
        rows.append({"e": e, "p": products.get(i["product_id"]), "pid": i["product_id"], "price": (po, pn), "cost": (co, cn),
                     "pct": pct, "who": who, "new": e.action == "INSERT"})
    return rows


@router.get("/prices", response_class=HTMLResponse)
def price_log(request: Request, d_from: str = "", d_to: str = "", q: str = "", user=Depends(need["products"]),
              db: Session = Depends(get_db)):
    today = datetime.now(TZ).date()
    f_from, f_to = parse_date(d_from, today - timedelta(days=90)), parse_date(d_to, today)
    start, end = local_day_range(f_from, f_to)
    pid = None
    if q.strip():
        p, _ = services.find_by_code(db, q.strip())
        p = p or db.scalar(select(Product).where(Product.name.ilike(f"%{q.strip()}%")).limit(1))
        pid = p.id if p else -1
    rows = _price_rows(db, services.price_history(db, pid, start, end))
    if request.query_params.get("format") == "csv":
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["الوقت", "الصنف", "الباركود", "سعر البيع قبل", "سعر البيع بعد", "التغيير %", "سعر الشراء قبل",
                    "سعر الشراء بعد", "مين", "السبب"])
        for r in rows:
            w.writerow([fmt_dt(r["e"].at), r["p"].name if r["p"] else r["pid"], r["p"].barcode if r["p"] else "",
                        *(("" if v is None else fmt_money(v)) for v in r["price"]),
                        "" if r["pct"] is None else f"{r['pct']:.1f}",
                        *(("" if v is None else fmt_money(v)) for v in r["cost"]), r["who"], r["e"].reason or ""])
        return Response("\ufeff" + buf.getvalue(), media_type="text/csv; charset=utf-8",
                        headers={"Content-Disposition": f'attachment; filename="prices-{f_from}-{f_to}.csv"'})
    return render(request, "prices.html", {"rows": rows, "d_from": f_from, "d_to": f_to, "q": q})


@router.get("/accounting/log")
def old_audit_log():
    return redirect("/log")


@router.get("/log", response_class=HTMLResponse)
def audit_log(request: Request, d_from: str = "", d_to: str = "", what: str = "", page: int = 1,
              user=Depends(current_user), db: Session = Depends(get_db)):
    if user.can("audit"):
        allowed = list(LOG_GROUPS)
    elif user.can("accounting"):
        allowed = list(ACCOUNTING_GROUPS)
    else:
        raise Forbidden()
    today = datetime.now(TZ).date()
    f_from, f_to = parse_date(d_from, today - timedelta(days=30)), parse_date(d_to, today)
    start, end = local_day_range(f_from, f_to)
    q = select(AuditLog).where(AuditLog.at >= start, AuditLog.at < end)
    groups = [what] if what in allowed else allowed
    q = q.where(AuditLog.table_name.in_([t for g in groups for t in LOG_GROUPS[g][1]]))
    manual = request.query_params.get("manual") == "1"
    if manual:
        q = q.where(AuditLog.reason.is_not(None))
    total = db.scalar(select(func.count()).select_from(q.subquery()))
    per = 100
    page = max(1, page)
    entries = db.scalars(q.order_by(AuditLog.at.desc(), AuditLog.id.desc()).offset((page - 1) * per).limit(per)).all()
    return render(request, "audit.html", {"rows": audit_view(db, entries), "links": {e.id: audit_link(db, e) for e in entries},
                                          "offset": (page - 1) * per,
                                          "d_from": f_from, "d_to": f_to, "what": what, "manual": manual,
                                          "groups": [(g, LOG_GROUPS[g][0]) for g in allowed],
                                          "page": page, "pages": max(1, -(-total // per)), "total": total})


def audit_link(db, e):
    """The page of the record a log line belongs to."""
    if e.table_name == "sales":
        return f"/sales/{e.row_id}"
    if e.table_name == "receipts":
        return f"/receipts/{e.row_id}"
    if e.table_name == "count_sessions":
        return f"/counts/{e.row_id}"
    if e.action == "DELETE" and e.table_name in ("products", "employees", "roles"):
        return None
    if e.table_name == "products":
        return f"/products/{e.row_id}"
    if e.table_name == "employees":
        return f"/employees/{e.row_id}"
    if e.table_name == "roles":
        return f"/roles/{e.row_id}"
    if e.table_name == "suppliers":
        return "/suppliers"
    if e.table_name == "devices":
        return "/devices"
    if e.table_name == "product_barcodes":
        pid = (e.changes.get("product_id") or [None, None])
        pid = pid[1] if pid[1] is not None else pid[0]
        if pid is None:
            b = db.get(ProductBarcode, int(e.row_id))
            pid = b.product_id if b else None
        return f"/products/{pid}" if pid else None
    parent = {"sale_lines": (SaleLine, "sale_id", "/sales/"), "receipt_lines": (ReceiptLine, "receipt_id", "/receipts/"),
              "count_lines": (CountLine, "session_id", "/counts/")}.get(e.table_name)
    if not parent:
        return None
    if e.action == "DELETE":
        pid = e.changes.get(parent[1], [None])[0]
    else:
        row = db.get(parent[0], int(e.row_id))
        pid = getattr(row, parent[1]) if row else None
    return f"{parent[2]}{pid}" if pid else None


# ---------- employees ----------

def validate_employee_fields(db, emp_id, name, role, pin, username, password, need_password):
    errors = []
    if not name:
        errors.append("الاسم مطلوب")
    r = db.get(Role, role) if role else None
    if r is None:
        errors.append("اختار الدور")
    if pin or emp_id is None:
        if not (pin.isdigit() and 4 <= len(pin) <= 6):
            errors.append("الرقم السري لازم يكون من 4 إلى 6 أرقام")
        else:
            for other in db.scalars(select(Employee).where(Employee.active.is_(True), Employee.id != (emp_id or 0))):
                if verify_pin(pin, other.pin_salt, other.pin_hash):
                    errors.append("الرقم السري ده مستخدم لموظف تاني، اختار رقم مختلف")
                    break
    if username:
        if db.scalar(select(Employee.id).where(Employee.username == username, Employee.id != (emp_id or 0))):
            errors.append("اسم المستخدم مستخدم قبل كده")
        if need_password and len(password) < 8:
            errors.append("كلمة سر لوحة التحكم لازم تكون 8 حروف على الأقل")
    if need_password and not username:
        errors.append("اسم المستخدم مطلوب")
    return errors


def all_roles(db):
    return db.scalars(select(Role).order_by(case((Role.key == ADMIN_ROLE, 1), else_=0), Role.name)).all()


@router.get("/employees", response_class=HTMLResponse)
def employees(request: Request, user=Depends(need["employees"]), db: Session = Depends(get_db)):
    return render(request, "employees.html", {
        "items": db.scalars(select(Employee).order_by(Employee.active.desc(), Employee.name)).all()})


@router.get("/employees/new", response_class=HTMLResponse)
def employee_new(request: Request, user=Depends(need["employees"]), db: Session = Depends(get_db)):
    roles = all_roles(db)
    return render(request, "employee_form.html", {"e": None, "roles": roles,
                                                  "form": {"role": roles[0].key if roles else "", "active": "1"}})


@router.get("/employees/{eid}", response_class=HTMLResponse)
def employee_edit(eid: int, request: Request, user=Depends(need["employees"]), db: Session = Depends(get_db)):
    e = db.get(Employee, eid)
    if not e:
        return redirect("/employees")
    return render(request, "employee_form.html", {"e": e, "form": None, "roles": all_roles(db),
                                                  **history(db, "employees", e.id, "employees", [])})


@router.post("/employees/{eid}")
async def employee_save(eid: str, request: Request, user=Depends(need["employees"]), db: Session = Depends(get_db)):
    e = None if eid == "new" else db.get(Employee, int(eid))
    f = await request.form()
    name, role = str(f.get("name", "")).strip(), str(f.get("role", ""))
    r = db.get(Role, role)
    pin = str(f.get("pin", "")).strip()
    username = str(f.get("username", "")).strip() if r and "dashboard" in r.perms else ""
    password = str(f.get("password", ""))
    active = f.get("active") == "1"
    need_pw = bool(username) and (password != "" or not (e and e.password_hash))
    errors = validate_employee_fields(db, e.id if e else None, name, role, pin, username, password, need_pw)
    if e and e.id == user.id and (not r or "employees" not in r.perms or "dashboard" not in r.perms or not active):
        errors.append("مينفعش تشيل من حسابك صلاحية الموظفين أو تدخل اللوحة، أو توقفه")
    if errors:
        return render(request, "employee_form.html", {"e": e, "form": f, "errors": errors, "roles": all_roles(db)}, 400)
    if e is None:
        e = Employee()
        db.add(e)
    e.name, e.role, e.active = name, role, active
    if pin:
        e.pin_salt, e.pin_hash = hash_pin(pin)
    e.username = username or None
    if not username:
        e.password_hash = None
    elif password:
        e.password_hash = hash_password(password)
    services.bump(db, e)
    db.commit()
    flash(request, f"تم حفظ {e.name}")
    return redirect("/employees")


# ---------- roles ----------

PERM_GROUPS = {}
for _k, (_label, _group) in PERMISSIONS.items():
    PERM_GROUPS.setdefault(_group, []).append((_k, _label))
templates.env.globals.update(PERM_GROUPS=PERM_GROUPS)


@router.get("/roles", response_class=HTMLResponse)
def roles(request: Request, user=Depends(need["employees"]), db: Session = Depends(get_db)):
    used = dict(db.execute(select(Employee.role, func.count()).where(Employee.active.is_(True)).group_by(Employee.role)).all())
    return render(request, "roles.html", {"items": all_roles(db), "used": used})


@router.get("/roles/new", response_class=HTMLResponse)
def role_new(request: Request, user=Depends(need["employees"])):
    return render(request, "role_form.html", {"r": None, "name": "", "perms_sel": set()})


@router.get("/roles/{key}", response_class=HTMLResponse)
def role_edit(key: str, request: Request, user=Depends(need["employees"]), db: Session = Depends(get_db)):
    r = db.get(Role, key)
    if not r:
        return redirect("/roles")
    count = db.scalar(select(func.count()).select_from(Employee).where(Employee.role == key))
    return render(request, "role_form.html", {"r": r, "name": r.name, "perms_sel": r.perms, "count": count})


@router.post("/roles/{key}")
async def role_save(key: str, request: Request, user=Depends(need["employees"]), db: Session = Depends(get_db)):
    r = None if key == "new" else db.get(Role, key)
    if key != "new" and r is None:
        return redirect("/roles")
    if r is not None and r.is_system:
        flash(request, "دور المدير ثابت وليه كل الصلاحيات، علشان محدش يقفل النظام على نفسه.", "error")
        return redirect("/roles")
    f = await request.form()
    name = str(f.get("name", "")).strip()
    perms = {p for p in f.getlist("perm") if p in PERMISSIONS}
    errors = []
    if not name:
        errors.append("اسم الدور مطلوب")
    elif db.scalar(select(Role.key).where(func.lower(Role.name) == name.lower(), Role.key != (r.key if r else ""))):
        errors.append("فيه دور بنفس الاسم")
    if not perms:
        errors.append("اختار صلاحية واحدة على الأقل")
    if r is not None and user.role == r.key and not {"employees", "dashboard"} <= perms:
        errors.append("ده دورك أنت. مينفعش تشيل منه «الموظفين والأدوار» أو «دخول لوحة التحكم» وإلا هتقفل على نفسك.")
    if errors:
        count = db.scalar(select(func.count()).select_from(Employee).where(Employee.role == r.key)) if r else 0
        return render(request, "role_form.html", {"r": r, "name": name, "perms_sel": perms, "errors": errors, "count": count}, 400)
    if r is None:
        r = Role(key="r" + os.urandom(4).hex())
        db.add(r)
    r.name, r.permissions = name, ",".join(sorted(perms))
    db.flush()
    # Devices only re-download employees whose version moved, so push the new permissions to them.
    for e in db.scalars(select(Employee).where(Employee.role == r.key)):
        services.bump(db, e)
    db.commit()
    flash(request, f"تم حفظ دور «{r.name}». الأجهزة هتاخد الصلاحيات الجديدة في أول مزامنة.")
    return redirect("/roles")


@router.post("/roles/{key}/delete")
def role_delete(key: str, request: Request, user=Depends(need["employees"]), db: Session = Depends(get_db)):
    r = db.get(Role, key)
    if not r or r.is_system:
        return redirect("/roles")
    count = db.scalar(select(func.count()).select_from(Employee).where(Employee.role == key))
    if count:
        flash(request, f"مينفعش تمسح «{r.name}»: عليه {count} موظف (حتى الموقوفين). انقلهم لدور تاني الأول.", "error")
        return redirect(f"/roles/{key}")
    db.delete(r)
    db.commit()
    flash(request, f"تم مسح دور «{r.name}»")
    return redirect("/roles")


# ---------- devices ----------

@router.get("/devices", response_class=HTMLResponse)
def devices(request: Request, user=Depends(need["devices"]), db: Session = Depends(get_db)):
    items = db.scalars(select(Device).order_by(Device.active.desc(), Device.name)).all()
    return render(request, "devices.html", {"items": items, "now": now(), "show_code": request.session.pop("show_code", None)})


@router.post("/devices")
async def device_create(request: Request, user=Depends(need["devices"]), db: Session = Depends(get_db)):
    f = await request.form()
    name = str(f.get("name", "")).strip()
    if not name:
        flash(request, "اكتب اسم للجهاز (مثلاً: كاشير 1)", "error")
        return redirect("/devices")
    d = Device(name=name[:80])
    db.add(d)
    db.flush()
    set_pairing(db, d)
    db.commit()
    request.session["show_code"] = d.id
    return redirect("/devices")


def set_pairing(db, d: Device):
    while True:
        code = new_pairing_code()
        if not db.scalar(select(Device.id).where(Device.pairing_code == code)):
            break
    d.pairing_code = code
    d.pairing_expires = now() + timedelta(minutes=config.PAIRING_MINUTES)


@router.post("/devices/{did}/{action}")
def device_action(did: int, action: str, request: Request, user=Depends(need["devices"]), db: Session = Depends(get_db)):
    d = db.get(Device, did)
    if not d:
        return redirect("/devices")
    if action == "repair":
        d.token_hash = None  # the old pairing stops working immediately
        d.active = True
        set_pairing(db, d)
        request.session["show_code"] = d.id
    elif action == "disable":
        d.active, d.token_hash, d.pairing_code = False, None, None
        flash(request, f"تم إيقاف {d.name}. لن يستطيع المزامنة حتى تربطه من جديد.")
    db.commit()
    return redirect("/devices")


# ---------- backup ----------

def pg_dump_cmd():
    url = config.DATABASE_URL.replace("postgresql+psycopg://", "postgresql://")
    exe = shutil.which("pg_dump")
    return [exe, "--no-owner", "--format=custom", url] if exe else None


@router.get("/backup", response_class=HTMLResponse)
def backup_page(request: Request, user=Depends(need["backup"])):
    log = Path(config.BACKUP_DIR) / "backup.log"
    entries = []
    if log.exists():
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines()[-200:]:
            when, _, rest = line.partition("  ")
            status, _, detail = rest.strip().partition(" ")
            entries.append({"when": when, "ok": status == "OK", "detail": detail.strip()})
    last_ok = next((e for e in reversed(entries) if e["ok"]), None)
    last = entries[-1] if entries else None
    return render(request, "backup.html", {"available": bool(pg_dump_cmd()), "dir": config.BACKUP_DIR,
                                           "last_ok": last_ok, "last": last, "recent": list(reversed(entries[-10:]))})


@router.get("/backup/download")
def backup_download(request: Request, user=Depends(need["backup"]), db: Session = Depends(get_db)):
    cmd = pg_dump_cmd()
    if not cmd:
        return redirect("/backup")
    services.log_event(db, "backup_download", f"emp:{user.id}", ip=client_ip(request))
    db.commit()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    name = f"tamween-{datetime.now(TZ):%Y%m%d-%H%M}.dump"

    def stream():
        try:
            while chunk := proc.stdout.read(65536):
                yield chunk
        finally:
            proc.stdout.close()
            proc.wait()

    return StreamingResponse(stream(), media_type="application/octet-stream",
                             headers={"Content-Disposition": f"attachment; filename={name}"})
