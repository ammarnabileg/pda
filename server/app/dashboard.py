"""Server-rendered Arabic dashboard for supervisors and admins."""
import csv
import io
import os
import shutil
import subprocess
from datetime import date, datetime, time, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path
from urllib.parse import quote, urlencode
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response, StreamingResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy import Date, String, case, cast, func, or_, select
from sqlalchemy.orm import Session

from . import config, exports, services
from .exports import Col, Report, Table
from .db import get_db
from .models import (
    ADMIN_ROLE, MODES, PERMISSIONS, PIECE_NAMES, UNITS, AuditLog, CountLine, CountSession, Device, Employee, Product, ProductBarcode, Receipt, ReceiptLine,
    ReceiptFile, Role, Sale, SaleLine, StockMove, Supplier, SupplierPayment, PAYMENT_METHODS, now,
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
    piece = p.piece_name or "حبة"
    text = f"{fmt_qty(base)} {piece}"
    if p.carton and abs(base) >= p.carton and base == base.to_integral_value():
        c, r = divmod(int(abs(base)), p.carton)
        text += f" ({c} كرتون" + (f" و {r} {piece}" if r else "") + ")"
    return text


templates.env.filters.update(money=fmt_money, qty=fmt_qty, dt=fmt_dt)
templates.env.globals.update(PIECE_NAMES=PIECE_NAMES, COOP_NAME=config.COOP_NAME, PERMISSIONS=PERMISSIONS, UNITS=UNITS, MODES=MODES, base_text=base_text)


def render(request: Request, name: str, ctx: dict | None = None, status: int = 200):
    ctx = dict(ctx or {})
    if ctx.pop("exportable", False):
        ctx["export_links"] = {f: str(request.url.include_query_params(format=f)) for f in ("xlsx", "pdf")}
    ctx["user"] = getattr(request.state, "user", None)
    ctx["flash"] = request.session.pop("flash", None)
    ctx["path"] = request.url.path
    return templates.TemplateResponse(request, name, ctx, status_code=status)


def export_format(request: Request):
    f = request.query_params.get("format")
    return f if f in ("xlsx", "pdf") else None


def send_report(request: Request, rep: Report):
    """The page as an Excel or PDF file, same data and filters as on screen."""
    fmt = export_format(request)
    try:
        data = exports.to_xlsx(rep) if fmt == "xlsx" else exports.to_pdf(rep)
    except ImportError:
        return HTMLResponse("<p dir=rtl style='font:20px sans-serif;padding:30px'>برامج Excel و PDF مش متثبتة على الكمبيوتر ده. "
                            "شغّل setup.bat مرة (محتاج إنترنت) وجرّب تاني.</p>", status_code=503)
    media = ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" if fmt == "xlsx" else "application/pdf")
    name = f"{rep.filename}.{fmt}"
    ascii_name = "".join(c if c.isascii() and (c.isalnum() or c in "-_.") else "_" for c in name)
    return Response(data, media_type=media, headers={
        "Content-Disposition": f"attachment; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(name)}"})


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


class ReadOnly(Forbidden):
    """Anyone but the admin may only view and print."""


def is_edit_page(path: str) -> bool:
    """Pages that are only a form for changing data (new, edit, corrections, import)."""
    return (path.endswith("/new") or path.endswith("/edit") or path.startswith("/products-import")
            or (path.startswith("/accounting/") and path != "/accounting/log"))


def current_user(request: Request, db: Session = Depends(get_db)) -> Employee:
    uid = request.session.get("uid")
    user = db.get(Employee, uid) if uid else None
    if not user or not user.active or not user.can_dashboard:
        raise LoginRequired()
    request.state.user = user
    if not user.is_admin and (request.method != "GET" or is_edit_page(request.url.path)):
        raise ReadOnly()
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


def admin_only(user: Employee = Depends(current_user)) -> Employee:
    if not user.is_admin:
        raise ReadOnly()
    return user


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
        stmt = stmt.where(or_(Product.name.ilike(like), Product.barcode.ilike(like), Product.code.ilike(like),
                              func.ltrim(Product.code, "0") == q.strip().lstrip("0"), Product.id.in_(extra)))
    if low:
        stmt = stmt.where(Product.stock <= Product.min_stock, Product.min_stock > 0)
    if unit in UNITS:
        stmt = stmt.where(Product.unit == unit)
    if export_format(request):
        rows = db.scalars(stmt.order_by(Product.name)).all()
        filt = "، ".join(x for x in [f"بحث: {q.strip()}" if q.strip() else "", "تحت حد الطلب" if low else "",
                                     {"active": "الفعّال", "inactive": "الموقوف"}.get(status, "الكل")] if x)
        return send_report(request, Report(
            title="الأصناف", filename=f"products-{datetime.now(TZ):%Y%m%d}", subtitle=f"{len(rows)} صنف · {filt}",
            tables=[Table([Col("م", "int", .4), Col("رقم الصنف", "text", .9), Col("الصنف", "text", 3), Col("الباركود", "text", 1.6),
                           Col("باركودات تانية", "text", 1.6), Col("الوحدة", "text", .8), Col("حبات الكرتون", "int", .7),
                           Col("سعر البيع", "money"), Col("سعر الشراء", "money"), Col("الرصيد", "qty"),
                           Col("حد الطلب", "qty", .8), Col("الحالة", "text", .7)],
                          [[i, p.code or "", p.name, p.barcode, " ".join(b.code for b in p.extra_barcodes), p.unit_name,
                            p.carton or "", p.price, p.cost, p.stock, p.min_stock, "فعّال" if p.active else "موقوف"]
                           for i, p in enumerate(rows, 1)])]))
    total = db.scalar(select(func.count()).select_from(stmt.subquery()))
    pages = max(1, -(-total // PAGE_SIZE))
    page = min(max(1, page), pages)
    items = db.scalars(stmt.order_by(Product.name).offset((page - 1) * PAGE_SIZE).limit(PAGE_SIZE)).all()
    params = {"q": q, "status": status, "low": low or "", "unit": unit}
    return render(request, "products.html", {
        "items": items, "total": total, "page": page, "pages": pages, **params, "offset": (page - 1) * PAGE_SIZE,
        "page_url": lambda n: "/products?" + urlencode({**{k: v for k, v in params.items() if v}, "page": n}),
        "filtered": bool(q.strip() or low or unit or status != "active"), "exportable": True,
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
    code = str(f.get("code") or "").strip()
    if code:
        if not code.isalnum() or len(code) > 20:
            errors["code"] = "رقم الصنف: أرقام أو حروف بدون مسافات، لحد 20"
        elif db.scalar(select(Product.name).where(Product.code == code, Product.id != (p_id or 0))):
            errors["code"] = f"رقم الصنف ده مستخدم للصنف: {db.scalar(select(Product.name).where(Product.code == code))}"
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
    if "code" in f:  # an import file without the column keeps the number the product has
        p.code = str(f.get("code") or "").strip() or None
    if "supplier_id" in f:
        sid = str(f.get("supplier_id") or "")
        p.supplier_id = int(sid) if sid.isdigit() and db.get(Supplier, int(sid)) else None
    p.name = str(f.get("name")).strip()
    p.unit = f.get("unit")
    pn = str(f.get("piece_name") or "").strip()
    p.piece_name = pn if pn in PIECE_NAMES else (p.piece_name or "حبة")
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


def supplier_list(db):
    return db.scalars(select(Supplier).order_by(Supplier.active.desc(), Supplier.no.nulls_last(), Supplier.name)).all()


def form_ctx(p, form, errors=None, moves=None, **extra):
    if form is not None:
        barcodes = form_barcodes(form) if hasattr(form, "getlist") else []
    else:
        barcodes = [(b.code, b.mode) for b in p.extra_barcodes] if p else []
    return {"p": p, "form": form, "errors": errors or {}, "moves": moves or [], "barcodes": barcodes, **extra}


@router.get("/products/new", response_class=HTMLResponse)
def product_new(request: Request, user=Depends(need["products"]), db: Session = Depends(get_db)):
    return render(request, "product_form.html", form_ctx(None, {"unit": "piece", "active": "1", "carton": "0", "cost": "0", "min_stock": "0"}, suppliers=supplier_list(db)))


@router.post("/products/new")
async def product_create(request: Request, user=Depends(need["products"]), db: Session = Depends(get_db)):
    f = await request.form()
    extra = form_barcodes(f)
    errors = product_errors(db, None, f, extra)
    if errors:
        return render(request, "product_form.html", form_ctx(None, f, errors, suppliers=supplier_list(db)), 400)
    p = Product(stock=0)
    db.add(p)
    apply_product_form(db, p, f, extra)
    services.bump(db, p)
    db.commit()
    flash(request, f"تمت إضافة {p.name}. رصيده 0: الرصيد بييجي من سند استلام أو جرد")
    return redirect("/products/new" if f.get("next") == "new" else f"/products/{p.id}")


@router.get("/products/{pid}", response_class=HTMLResponse)
def product_detail(pid: int, request: Request, user=Depends(need["products"]), db: Session = Depends(get_db)):
    p = db.get(Product, pid)
    if not p:
        return redirect("/products")
    moves = db.scalars(select(StockMove).where(StockMove.product_id == pid).order_by(StockMove.created_at.desc()).limit(50)).all()
    sale_refs = {m.ref for m in moves if m.ref and len(m.ref) == 36}
    sale_nos = dict(db.execute(select(cast(Sale.id, String), Sale.no).where(cast(Sale.id, String).in_(sale_refs))).all()) if sale_refs else {}
    if export_format(request):
        prices = _price_rows(db, services.price_history(db, p.id, limit=200))
        reasons = {"sale": "بيع", "receipt": "استلام", "count": "جرد", "manual": "يدوي", "edit": "تعديل محاسبة"}
        return send_report(request, Report(
            title=f"كارت صنف: {p.name}", filename=f"product-{p.id}",
            info=[("رقم الصنف", p.code or "—"), ("الباركود", p.barcode), ("الوحدة", p.unit_name), ("سعر البيع", fmt_money(p.price)),
                  ("سعر الشراء", fmt_money(p.cost)), ("الرصيد", base_text(p, p.stock)), ("حد الطلب", fmt_qty(p.min_stock, p.unit)),
                  ("حبات الكرتون", p.carton or "—"), ("باركودات تانية", " ".join(b.code for b in p.extra_barcodes) or "—")],
            tables=[Table([Col("م", "int", .4), Col("الوقت", "text", 1.3), Col("سعر البيع قبل", "money"), Col("سعر البيع بعد", "money"),
                           Col("سعر الشراء قبل", "money"), Col("سعر الشراء بعد", "money"), Col("مين", "text", 1.2)],
                          [[i, fmt_dt(r["e"].at), r["price"][0], r["price"][1], r["cost"][0], r["cost"][1], r["who"]]
                           for i, r in enumerate(prices, 1)], title="سجل الأسعار"),
                    Table([Col("م", "int", .4), Col("الوقت", "text", 1.3), Col("النوع", "text", .9), Col("الكمية", "qty"),
                           Col("مرجع / ملاحظة", "text", 2.5)],
                          [[i, fmt_dt(m.created_at), reasons.get(m.reason, m.reason), m.delta,
                            (f"فاتورة {sale_nos[m.ref]}" if m.ref in sale_nos else (m.note or m.ref or ""))]
                           for i, m in enumerate(moves, 1)], title="آخر 50 حركة مخزون")]))
    return render(request, "product_form.html", form_ctx(p, None, moves=moves, sale_nos=sale_nos, exportable=True, suppliers=supplier_list(db),
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
        return render(request, "product_form.html", form_ctx(p, f, errors, suppliers=supplier_list(db)), 400)
    apply_product_form(db, p, f, extra)
    services.bump(db, p)
    db.commit()
    flash(request, f"تم حفظ {p.name}")
    return redirect(f"/products/{pid}")


# No stock column: stock only changes through sales, vouchers, approved counts and corrections with a reason.
IMPORT_COLUMNS = ["code", "barcode", "name", "unit", "price", "cost", "carton", "min_stock", "carton_barcode", "extra_barcodes",
                  "supplier_no", "supplier_name"]
# Column titles in the Excel template; files may use these or the English keys.
IMPORT_TITLES = {"supplier_no": "رقم المورد", "supplier_name": "اسم المورد", "code": "رقم الصنف", "barcode": "الباركود", "name": "اسم الصنف", "unit": "الوحدة", "price": "سعر البيع", "cost": "سعر الشراء",
                 "carton": "حبات الكرتون", "min_stock": "حد الطلب", "carton_barcode": "باركود الكرتون",
                 "extra_barcodes": "باركودات تانية"}
IMPORT_ALIASES = {**{k: k for k in IMPORT_COLUMNS}, **{v: k for k, v in IMPORT_TITLES.items()},
                  "الصنف": "name", "الاسم": "name", "كود الصنف": "code", "كود الصنف القديم": "code", "رقم صنف": "code", "المورد": "supplier_name", "نوع البيع": "unit", "عدد الحبات في الكرتون": "carton",
                  "الباركود الأساسي": "barcode", "باركودات إضافية": "extra_barcodes"}
UNIT_ALIASES = {"piece": "piece", "حبة": "piece", "بالحبة": "piece", "حبه": "piece", "kg": "kg", "كيلو": "kg",
                "بالكيلو": "kg", "كجم": "kg", "كيلوجرام": "kg", **{n: "piece" for n in PIECE_NAMES}, "علبه": "piece"}
TEXT_COLUMNS = ("code", "barcode", "carton_barcode", "extra_barcodes")


def _cell(v, key):
    """Excel values as the text the form expects. Barcodes typed as numbers come back as 6281000123456, not 6.28e12."""
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer() and (key in TEXT_COLUMNS or key == "carton"):
        return str(int(v))
    if isinstance(v, float):
        return format(Decimal(str(v)).normalize(), "f")
    return str(v).strip()


def read_import_file(name: str, raw: bytes):
    """Rows as {english key: text}, from .xlsx (first sheet, first row = titles) or CSV. None if unreadable."""
    if raw[:2] == b"PK" or name.lower().endswith(".xlsx"):
        from openpyxl import load_workbook

        try:
            ws = load_workbook(io.BytesIO(raw), read_only=True, data_only=True).worksheets[0]
        except Exception:
            return None
        it = ws.iter_rows(values_only=True)
        header = None
        for row in it:
            if any(c not in (None, "") for c in row):
                header = [IMPORT_ALIASES.get(str(c or "").strip().lower(), IMPORT_ALIASES.get(str(c or "").strip(), "")) for c in row]
                break
        if not header:
            return []
        rows = []
        for row in it:
            if not any(c not in (None, "") for c in row):
                continue
            rows.append({k: _cell(v, k) for k, v in zip(header, row) if k})
        return rows
    for enc in ("utf-8-sig", "cp1256"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    else:
        return None
    out = []
    for row in csv.DictReader(io.StringIO(text)):
        out.append({IMPORT_ALIASES.get(k.strip().lower(), IMPORT_ALIASES.get(k.strip(), "")): (v or "").strip()
                    for k, v in row.items() if k})
    return [{k: v for k, v in r.items() if k} for r in out]


def import_template_xlsx(products=None) -> bytes:
    """The import file: Arabic titles, barcode columns as text, a unit drop-down, examples or the current products."""
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Font, PatternFill
    from openpyxl.utils import get_column_letter
    from openpyxl.worksheet.datavalidation import DataValidation

    wb = Workbook()
    ws = wb.active
    ws.title = "الأصناف"
    ws.sheet_view.rightToLeft = True
    for i, key in enumerate(IMPORT_COLUMNS, start=1):
        c = ws.cell(row=1, column=i, value=IMPORT_TITLES[key])
        c.font = Font(name="Arial", bold=True, color="FFFFFF")
        c.fill = PatternFill("solid", fgColor=exports.BRAND)
        c.alignment = Alignment(horizontal="center", vertical="center")
        col = get_column_letter(i)
        ws.column_dimensions[col].width = {"name": 36, "extra_barcodes": 30}.get(key, 17)
        if key in TEXT_COLUMNS:
            for r in range(2, 5002):
                ws[f"{col}{r}"].number_format = "@"
    unit_col = get_column_letter(IMPORT_COLUMNS.index("unit") + 1)
    dv = DataValidation(type="list", formula1='"' + ",".join(PIECE_NAMES + ("كيلو",)) + '"', allow_blank=True,
                        showErrorMessage=True, errorTitle="الوحدة", error="اختار من القائمة")
    ws.add_data_validation(dv)
    dv.add(f"{unit_col}2:{unit_col}5001")
    rows = ([[p.code or "", p.barcode, p.name, p.unit_name, float(p.price), float(p.cost), p.carton,
              float(p.min_stock), " ".join(b.code for b in p.extra_barcodes if b.mode == "carton"),
              " ".join(b.code for b in p.extra_barcodes if b.mode != "carton"),
              p.supplier.no if p.supplier and p.supplier.no else "", p.supplier.name if p.supplier else ""] for p in products]
            if products is not None else
            [["00010001", "6281000123456", "أرز بسمتي ٥ كجم", "حبة", 2.45, 2.05, 6, 10, "16281000123453", "6281000123999", 1, "الشركة الكويتية للتموين"],
             ["00010002", "2100000012345", "سكر أبيض", "كيلو", 0.35, 0.28, 0, 20, "", "", 1, "الشركة الكويتية للتموين"]])
    for r, row in enumerate(rows, start=2):
        for i, v in enumerate(row, start=1):
            c = ws.cell(row=r, column=i, value=v)
            if IMPORT_COLUMNS[i - 1] in ("price", "cost"):
                c.number_format = "0.000"
    ws.freeze_panes = "A2"
    help_ = wb.create_sheet("تعليمات")
    help_.sheet_view.rightToLeft = True
    help_.column_dimensions["A"].width = 110
    for i, line in enumerate([
        "طريقة الاستيراد",
        "1. املأ ورقة «الأصناف»: كل صنف في سطر، وأول سطر هو أسماء الأعمدة (ماتغيّرهوش).",
        "رقم الصنف: رقم الصنف عندكم (زي 00010001)، مايتكررش. لو موجود، الاستيراد بيلاقي الصنف بيه حتى لو الباركود اتغيّر.",
        "رقم المورد واسم المورد: مورد الصنف، علشان براءة الذمة. لو المورد مش موجود، بيتعمل لوحده.",
        "2. الباركود: لازم يتكتب كنص (العمود متظبط كده). لو لزقت أرقام من مكان تاني، اتأكد إنها مااتحوّلتش لـ 6.28E+12.",
        "3. الوحدة: «حبة» أو «كيلو» من القائمة.",
        "4. حبات الكرتون: عدد الحبات في الكرتون، أو 0 لو مالوش كرتون.",
        "5. باركود الكرتون وباركودات تانية: اختياري. لو أكتر من باركود، حط بينهم مسافة.",
        "6. الرصيد مش في الملف: الرصيد مابيتعدلش من الاستيراد. الصنف الجديد بيبدأ بـ 0، والرصيد بييجي من سند استلام أو جرد.",
        "7. لو الباركود موجود قبل كده، الصنف بيتحدّث (الاسم والأسعار) بدل ما يتكرر.",
        "8. لو فيه أي سطر غلط، مفيش حاجة بتتحفظ، والصفحة بتقولك رقم السطر والغلط.",
        "9. تغيير الأسعار لكل الأصناف: نزّل «الأصناف الحالية بنفس الشكل»، غيّر الأسعار، وارفع الملف. كل تغيير سعر بيتسجل في سجل الأسعار.",
    ], start=1):
        help_.cell(row=i, column=1, value=line).font = Font(name="Arial", bold=i == 1, size=14 if i == 1 else 12)
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


@router.get("/products-import", response_class=HTMLResponse)
def import_form(request: Request, user=Depends(need["products"])):
    return render(request, "product_import.html", {"columns": [IMPORT_TITLES[k] for k in IMPORT_COLUMNS]})


@router.get("/products-import/template.xlsx")
def import_template(request: Request, user=Depends(need["products"]), db: Session = Depends(get_db)):
    current = request.query_params.get("current") == "1"
    products = db.scalars(select(Product).where(Product.active.is_(True)).order_by(Product.name)).all() if current else None
    name = f"products-{datetime.now(TZ):%Y%m%d}.xlsx" if current else "products-template.xlsx"
    return Response(import_template_xlsx(products),
                    media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    headers={"Content-Disposition": f"attachment; filename={name}"})


@router.get("/products-import/template.csv")
def import_template_csv(user=Depends(need["products"])):
    body = (",".join(IMPORT_COLUMNS) + "\n"
            "6281000123456,أرز بسمتي ٥ كجم,piece,2.450,2.050,6,10,16281000123453,6281000123999\n"
            "2100000012345,سكر أبيض,kg,0.350,0.280,0,20,,\n")
    return Response("\ufeff" + body, media_type="text/csv; charset=utf-8",
                    headers={"Content-Disposition": "attachment; filename=products-template.csv"})


@router.post("/products-import", response_class=HTMLResponse)
async def import_products(request: Request, user=Depends(need["products"]), db: Session = Depends(get_db)):
    cols = [IMPORT_TITLES[k] for k in IMPORT_COLUMNS]
    f = await request.form()
    upload = f.get("file")
    if not upload or not hasattr(upload, "read"):
        return render(request, "product_import.html", {"columns": cols, "errors": ["اختار ملف Excel أو CSV"]}, 400)
    rows = read_import_file(getattr(upload, "filename", "") or "", await upload.read())
    if rows is None:
        return render(request, "product_import.html", {"columns": cols, "errors": ["الملف مش مقروء. استخدم ملف Excel (.xlsx) أو CSV UTF-8"]}, 400)
    if not rows:
        return render(request, "product_import.html", {"columns": cols, "errors": ["الملف فاضي أو أول سطر مش أسماء الأعمدة"]}, 400)
    if "barcode" not in rows[0] or "name" not in rows[0]:
        return render(request, "product_import.html", {"columns": cols, "errors": [
            "مش لاقي عمود «الباركود» و«اسم الصنف». نزّل ملف النموذج وحط الأصناف فيه"]}, 400)
    errors, created, updated = [], 0, 0
    for n, row in enumerate(rows, start=2):
        unit = row.get("unit", "").strip().lower() or "piece"
        if unit not in UNIT_ALIASES:
            errors.append(f"سطر {n}: الوحدة «{row.get('unit')}» مش مفهومة. اكتب حبة أو كيلو")
            continue
        row["unit"] = UNIT_ALIASES[unit]
        row["piece_name"] = {"علبه": "علبة", "حبه": "حبة"}.get(unit, unit) if unit in PIECE_NAMES or unit in ("علبه", "حبه") else "حبة"
        for k in ("price", "cost", "carton", "min_stock"):
            row.setdefault(k, "0" if k != "price" else "")
            row[k] = row[k] or ("0" if k != "price" else "")
        row["active"] = "1"
        # Same product number first (the barcode may have changed), then the same main barcode.
        sup_no, sup_name = row.get("supplier_no", "").strip(), row.get("supplier_name", "").strip()
        if sup_no and not sup_no.isdigit():
            errors.append(f"سطر {n}: رقم المورد «{sup_no}» لازم يكون أرقام")
            continue
        if sup_no or sup_name:
            sup = (db.scalar(select(Supplier).where(Supplier.no == int(sup_no))) if sup_no else None) \
                or (db.scalar(select(Supplier).where(Supplier.name == sup_name)) if sup_name else None)
            if sup is None:  # a new supplier from the file
                sup = Supplier(name=sup_name or f"مورد {sup_no}", no=int(sup_no) if sup_no else None)
                db.add(sup)
                db.flush()
            elif sup_no and sup.no is None:
                sup.no = int(sup_no)
            row["supplier_id"] = str(sup.id)
        existing = (db.scalar(select(Product).where(Product.code == row["code"])) if row.get("code") else None) \
            or db.scalar(select(Product).where(Product.barcode == row.get("barcode", "")))
        extra = [(c, "carton") for c in row.get("carton_barcode", "").replace("|", " ").split() if c]
        extra += [(c.strip(), "kg" if row["unit"] == "kg" else "piece") for c in row.get("extra_barcodes", "").replace("|", " ").split() if c.strip()]
        if existing:  # keep barcodes the file does not mention
            extra = [(b.code, b.mode) for b in existing.extra_barcodes if b.code not in dict(extra)] + extra
        errs = list(product_errors(db, existing.id if existing else None, row, extra).values())
        if errs:
            errors.append(f"سطر {n}: " + "، ".join(errs))
            continue
        p = existing or Product(stock=0)
        if not existing:
            db.add(p)
        apply_product_form(db, p, row, extra)
        services.bump(db, p)
        db.flush()
        created, updated = created + (not existing), updated + bool(existing)
    if errors:
        db.rollback()
        return render(request, "product_import.html", {"columns": cols, "errors": errors[:50] + (["…"] if len(errors) > 50 else []),
                                                       "note": "لم يتم حفظ أي صنف. صلّح الأخطاء وارفع الملف تاني."}, 400)
    db.commit()
    flash(request, f"تم الاستيراد: {created} صنف جديد، {updated} صنف اتعدل")
    return redirect("/products")


# ---------- barcodes: every product on one page, scan to add ----------

def barcode_row(p: Product) -> dict:
    main_mode = "kg" if p.unit == "kg" else "piece"
    codes = [{"code": p.barcode, "mode": main_mode, "name": p.mode_name(main_mode), "main": True}]
    codes += [{"code": b.code, "mode": b.mode, "name": p.mode_name(b.mode), "main": False} for b in p.extra_barcodes]
    return {"id": p.id, "code": p.code or "", "name": p.name, "unit": p.unit, "piece_name": p.piece_name or "حبة", "carton": p.carton,
            "unit_name": p.unit_name, "codes": codes,
            "missing_carton": bool(p.carton) and not any(c["mode"] == "carton" for c in codes)}


@router.get("/barcodes", response_class=HTMLResponse)
def barcodes(request: Request, q: str = "", show: str = "active", user=Depends(need["products"]), db: Session = Depends(get_db)):
    stmt = select(Product).order_by(Product.name)
    if show != "all":
        stmt = stmt.where(Product.active.is_(True))
    items = db.scalars(stmt).all()
    rows = [barcode_row(p) for p in items]
    if show == "missing":
        rows = [r for r in rows if r["missing_carton"]]
    if export_format(request):
        return send_report(request, Report(
            title="باركودات الأصناف", filename=f"barcodes-{datetime.now(TZ):%Y%m%d}",
            tables=[Table([Col("م", "int", .4), Col("رقم الصنف", "text", .9), Col("الصنف", "text", 2.6), Col("الوحدة", "text", .7),
                           Col("حبات الكرتون", "int", .7), Col("الباركودات", "text", 3.5)],
                          [[i, r["code"], r["name"], r["unit_name"], r["carton"] or "",
                            "  ".join(f"{c['code']} ({c['name']}{'، أساسي' if c['main'] else ''})" for c in r["codes"])]
                           for i, r in enumerate(rows, 1)])]))
    return render(request, "barcodes.html", {"rows": rows, "q": q, "show": show, "exportable": True,
                                              "missing": sum(1 for p in items if barcode_row(p)["missing_carton"])})


@router.post("/barcodes/{pid}")
async def barcode_update(pid: int, request: Request, user=Depends(admin_only), db: Session = Depends(get_db)):
    """JSON in, JSON out, so a scanner can add barcode after barcode without reloading the page.
    {action: add, code, mode} | {action: remove, code} | {action: main, code} | {action: unit, unit, piece_name, carton}"""
    p = db.get(Product, pid)
    if not p:
        return JSONResponse({"error": "الصنف مش موجود"}, 404)
    data = await request.json()
    try:
        msg = services.barcode_action(db, p, data)
    except services.EditError as e:
        db.rollback()
        return JSONResponse({"error": str(e)}, 400)
    db.commit()
    db.refresh(p)
    return JSONResponse({"ok": True, "msg": msg, "row": barcode_row(p)})


# ---------- suppliers ----------

@router.get("/suppliers", response_class=HTMLResponse)
def suppliers(request: Request, user=Depends(need["products"]), db: Session = Depends(get_db)):
    items = db.scalars(select(Supplier).order_by(Supplier.active.desc(), Supplier.name)).all()
    today = datetime.now(TZ).date()
    balances = {s.id: services.supplier_statement(db, s, date(2000, 1, 1), today)["closing"] for s in items}
    if export_format(request):
        return send_report(request, Report(
            title="الموردين", filename=f"suppliers-{today}", subtitle=f"الأرصدة حتى {today}",
            tables=[Table([Col("م", "int", .4), Col("المورد", "text", 2.5), Col("التليفون", "text", 1.2), Col("الحالة", "text", .7),
                           Col("الرصيد المستحق", "money")],
                          [[i, x.name, x.phone or "", "فعّال" if x.active else "موقوف", balances[x.id]] for i, x in enumerate(items, 1)],
                          totals=["", "الإجمالي", "", "", sum(balances.values(), Decimal(0))])]))
    return render(request, "suppliers.html", {"items": items, "balances": balances, "exportable": True})


@router.get("/suppliers/{sid}/statement", response_class=HTMLResponse)
def supplier_statement(sid: int, request: Request, d_from: str = "", d_to: str = "", view: str = "summary",
                       user=Depends(need["receipts"]), db: Session = Depends(get_db)):
    sup = db.get(Supplier, sid)
    if not sup:
        return redirect("/suppliers")
    today = datetime.now(TZ).date()
    f_from, f_to = parse_date(d_from, date(today.year, 1, 1)), parse_date(d_to, today)
    st = services.supplier_statement(db, sup, f_from, f_to)
    lines, bal = [], st["opening"]
    for item in statement_lines(st):
        bal += item["debit"] - item["credit"]
        lines.append({**item, "balance": bal})
    if export_format(request):
        clear = st["closing"] == 0
        if clear:
            verdict = f"تشهد {config.COOP_NAME} و«{sup.name}» بأنه لا توجد أي مستحقات مالية لأي طرف على الآخر حتى تاريخ {f_to}."
        elif st["closing"] > 0:
            verdict = f"المتبقي لـ«{sup.name}» على {config.COOP_NAME} حتى {f_to}: {fmt_money(st['closing'])} د.ك"
        else:
            verdict = f"مدفوع لـ«{sup.name}» زيادة عن البضاعة المستلمة حتى {f_to}: {fmt_money(-st['closing'])} د.ك"
        tables = [Table([Col("م", "int", .4), Col("التاريخ", "text", .9), Col("البيان", "text", 1.8), Col("فاتورة الشركة", "text", 1.1),
                         Col("بضاعة (عليه)", "money"), Col("مدفوع (له)", "money"), Col("الرصيد", "money")],
                        [["", f_from, "رصيد أول المدة", "", "", "", st["opening"]]] +
                        [[i, x["date"], x["text"], x["invoice"], x["debit"] or None, x["credit"] or None, x["balance"]]
                         for i, x in enumerate(lines, 1)],
                        title="الحركة", totals=["", "", "الإجمالي", "", st["billed"], st["paid"], st["closing"]])]
        if view == "detail":
            for row in st["rows"]:
                r = row["r"]
                lt = []
                for i, l in enumerate(r.lines, 1):
                    cost = l.unit_cost if l.unit_cost is not None else l.product.cost
                    lt.append([i, l.product.name, "" if l.extra else l.ordered, l.received or 0, l.product.mode_name(l.received_mode or l.mode),
                               cost, (l.received_base or 0) * cost])
                tables.append(Table([Col("م", "int", .4), Col("الصنف", "text", 2.6), Col("المطلوب", "qty", .8), Col("المستلم", "qty", .8),
                                     Col("الوحدة", "text", .7), Col("سعر الشراء", "money", .9), Col("القيمة", "money", .9)], lt,
                                    title=f"سند {r.id} · فاتورة الشركة {r.supplier_invoice_no or '—'} · {fmt_dt(row['at'])}"
                                          + (f" · إجمالي الفاتورة {fmt_money(r.supplier_invoice_total)}" if r.supplier_invoice_total is not None else ""),
                                    totals=["", "قيمة المستلم", "", "", "", "", row["value"]]))
        return send_report(request, Report(
            title=("براءة ذمة" if clear else "كشف حساب") + (" تفصيلي" if view == "detail" else ""),
            filename=f"statement-{sid}-{f_from}-{f_to}", subtitle=f"{sup.name} · من {f_from} إلى {f_to}",
            info=[("المورد", sup.name), ("التليفون", sup.phone or "—"), ("رصيد أول المدة", fmt_money(st["opening"])),
                  ("بضاعة مستلمة", f"{fmt_money(st['billed'])} ({len(st['rows'])} سند)"),
                  ("مدفوعات", f"{fmt_money(st['paid'])} ({len(st['payments'])})"), ("الرصيد", f"{fmt_money(st['closing'])} د.ك")],
            tables=tables, note=verdict + (f"  فيه {st['pending']} سند لسه ماتستلمش ومش داخل في الحساب." if st["pending"] else ""),
            signatures=[f"توقيع وختم {config.COOP_NAME}", f"توقيع وختم مندوب «{sup.name}»"]))
    return render(request, "statement.html", {"s": sup, "st": st, "lines": lines, "d_from": f_from, "d_to": f_to, "exportable": True,
                                              "view": "detail" if view == "detail" else "summary",
                                              "today": today, "methods": PAYMENT_METHODS})


def statement_lines(st):
    """Vouchers and payments in date order, as debit (received, owed to the supplier) and credit (paid)."""
    items = [{"sort": (row["at"].astimezone(TZ).date(), 0, row["r"].id), "date": row["at"].astimezone(TZ).date(),
              "text": f"سند استلام {row['r'].id}", "invoice": row["r"].supplier_invoice_no or "", "debit": row["amount"],
              "credit": Decimal(0), "row": row} for row in st["rows"]]
    items += [{"sort": (p.paid_on, 1, p.id), "date": p.paid_on,
               "text": f"دفعة {PAYMENT_METHODS.get(p.method, p.method)}" + (f" {p.reference}" if p.reference else ""),
               "invoice": "", "debit": Decimal(0), "credit": p.amount, "pay": p} for p in st["payments"]]
    return sorted(items, key=lambda x: x["sort"])


@router.get("/suppliers/{sid}/clearance", response_class=HTMLResponse)
def supplier_clearance(sid: int, request: Request, d_from: str = "", d_to: str = "", view: str = "summary",
                       user=Depends(need["receipts"]), db: Session = Depends(get_db)):
    """براءة الذمة as the co-op prints it: detailed per product, or one line for the supplier, up to a date."""
    sup = db.get(Supplier, sid)
    if not sup:
        return redirect("/suppliers")
    today = datetime.now(TZ).date()
    start = parse_date(d_from, None) if d_from else None
    end = parse_date(d_to, today)
    cl = services.supplier_clearance(db, sup, start, end)
    detail = view == "detail"
    title = "براءة الذمة تفصيلي أصناف" if detail else f"براءة الذمة لمورد حتى {end}"
    t = cl["totals"]
    if export_format(request):
        cols = [Col("م", "int", .4), Col("رقم الصنف", "text", 1), Col("الصنف", "text", 3), Col("الافتتاحي", "money"),
                Col("الحركات", "money"), Col("المبيعات", "money"), Col("الرصيد", "money")]
        if detail:
            body = [[i, r["p"].code or "", r["p"].name, r["opening"] or None, r["moves"], r["sales"], r["balance"]]
                    for i, r in enumerate(cl["rows"], 1)]
            table = Table(cols, body, totals=["", "", "الإجمالي للمورد", t["opening"] or None, t["moves"], t["sales"], t["balance"]])
        else:
            table = Table([Col("المورد", "text", 3), Col("الافتتاحي", "money"), Col("الحركات", "money"), Col("المبيعات", "money"),
                           Col("الرصيد", "money")],
                          [[f"{sup.no or ''} {sup.name}".strip(), t["opening"] or None, t["moves"], t["sales"], t["balance"]]],
                          totals=["الإجمالي", t["opening"] or None, t["moves"], t["sales"], t["balance"]])
        return send_report(request, Report(
            title=title, filename=f"clearance-{sup.no or sid}-{end}",
            subtitle=(f"من {start} إلى {end}" if start else f"حتى {end}"),
            info=[("المورد", f"{sup.no or ''} {sup.name}".strip()), ("المستخدم", user.name)],
            tables=[table],
            note="القيم بسعر الشراء. الحركات = البضاعة المستلمة على سندات المورد + فروق الجرد. الرصيد = الافتتاحي + الحركات − المبيعات.",
            signatures=[f"توقيع وختم {config.COOP_NAME}", f"توقيع مندوب «{sup.name}»"]))
    return render(request, "clearance.html", {"s": sup, "cl": cl, "detail": detail, "title": title, "d_from": start or "",
                                              "d_to": end, "today": today, "exportable": True})


@router.post("/suppliers/{sid}/payments")
async def supplier_payment(sid: int, request: Request, user=Depends(admin_only), db: Session = Depends(get_db)):
    sup = db.get(Supplier, sid)
    if not sup:
        return redirect("/suppliers")
    f = await request.form()
    amount = dec(f.get("amount"))
    paid_on = parse_date(f.get("paid_on"), None)
    method = str(f.get("method", "cash"))
    note = str(f.get("note", "")).strip()[:500] or None
    back = f"/suppliers/{sid}/statement?" + urlencode({k: f.get(k, "") for k in ("d_from", "d_to", "view")})
    if amount is None or amount == 0 or paid_on is None or method not in PAYMENT_METHODS:
        flash(request, "اكتب المبلغ والتاريخ وطريقة الدفع", "error")
        return redirect(back)
    if amount < 0 and not note:
        flash(request, "المبلغ بالسالب معناه تصحيح دفعة غلط: اكتب السبب في الملاحظة", "error")
        return redirect(back)
    db.add(SupplierPayment(supplier_id=sid, amount=d3_money(amount), paid_on=paid_on, method=method,
                           reference=str(f.get("reference", "")).strip()[:80] or None, note=note, created_by=user.id))
    db.commit()
    flash(request, f"تم تسجيل دفعة {fmt_money(amount)} د.ك لـ {sup.name}")
    return redirect(back)


def d3_money(v):
    return Decimal(v).quantize(Decimal("0.001"))


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
    raw_no = str(f.get("no", "")).strip()
    if raw_no and not raw_no.isdigit():
        flash(request, "رقم المورد لازم يكون أرقام", "error")
        return redirect("/suppliers")
    no = int(raw_no) if raw_no else None
    if no is not None and db.scalar(select(Supplier.id).where(Supplier.no == no, Supplier.id != sid)):
        flash(request, f"رقم المورد {no} مستخدم لمورد تاني", "error")
        return redirect("/suppliers")
    s = db.get(Supplier, sid) if sid else Supplier()
    s.name, s.phone, s.no = name, str(f.get("phone", "")).strip() or None, no
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
    items = db.scalars(stmt).all()
    if export_format(request):
        return send_report(request, Report(
            title="سندات الاستلام", filename=f"receipts-{datetime.now(TZ):%Y%m%d}",
            subtitle=STATUS_NAMES.get(status, "الكل"),
            tables=[Table([Col("م", "int", .4), Col("رقم السند", "int", .7), Col("المورد", "text", 2), Col("فاتورة الشركة", "text", 1.2),
                           Col("إجمالي الفاتورة", "money"), Col("الأصناف", "int", .6), Col("أُنشئ", "text", 1.2),
                           Col("الحالة", "text", .9), Col("فيها فرق", "int", .6)],
                          [[i, r.id, r.supplier.name, r.supplier_invoice_no or "", r.supplier_invoice_total, len(r.lines),
                            fmt_dt(r.created_at), STATUS_NAMES.get(r.status, r.status), sum(1 for l in r.lines if l.diff_base)]
                           for i, r in enumerate(items, 1)])]))
    return render(request, "receipts.html", {"items": items, "status": status, "pending": pending, "exportable": True})


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
    inv_no, inv_total, inv_errors = invoice_fields(db, f, sup, r)
    errors[:0] = inv_errors
    uploads = [u for u in f.getlist("files") if getattr(u, "filename", "")]
    if errors:
        return None, render(request, "receipt_form.html", receipt_form_ctx(db, r, f, errors), 400)
    is_new = r is None
    if r is None:
        r = Receipt()
        db.add(r)
    r.supplier_id = sup.id
    r.note = str(f.get("note", "")).strip() or None
    r.supplier_invoice_no, r.supplier_invoice_total = inv_no, inv_total
    r.lines.clear()
    db.flush()
    for p, mode, q in lines:
        r.lines.append(ReceiptLine(product_id=p.id, mode=mode, ordered=q))
    try:
        for u in uploads:
            services.save_receipt_file(db, r, await u.read(), u.content_type or "", employee_id=request.state.user.id)
    except services.EditError as e:
        db.rollback()
        return None, render(request, "receipt_form.html", receipt_form_ctx(db, None if is_new else r, f, [str(e)]), 400)
    services.bump(db, r)
    db.commit()
    return r, None


def invoice_fields(db, f, sup, r):
    """Supplier invoice number (required, once per supplier) and its total (optional)."""
    errors = []
    no = str(f.get("supplier_invoice_no", "")).strip()[:60]
    if not no:
        errors.append("اكتب رقم فاتورة الشركة الأول")
    elif sup is not None:
        other = services.invoice_taken(db, sup.id, no, r.id if r else None)
        if other:
            errors.append(f"فاتورة الشركة رقم {no} متسجلة قبل كده في سند {other.id}")
    raw = str(f.get("supplier_invoice_total", "")).strip()
    total = None
    if raw:
        total = dec(raw)
        if total is None or total < 0:
            errors.append("إجمالي الفاتورة لازم يكون رقم")
            total = None
    return no or None, total, errors


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
    value, estimated = services.receipt_value(r) if r.status == "received" else (None, False)
    if export_format(request):
        rows = []
        for i, l in enumerate(r.lines, 1):
            cost = l.unit_cost if l.unit_cost is not None else l.product.cost
            d = l.diff_base
            rows.append([i, l.product.name + (" (زائد)" if l.extra else ""), "" if l.extra else l.ordered, l.product.mode_name(l.mode),
                         l.received, l.product.mode_name(l.received_mode or l.mode),
                         "" if d is None else ("مطابق" if d == 0 else (f"ناقص {base_text(l.product, -d)}" if d < 0 else f"زيادة {base_text(l.product, d)}")),
                         cost, (l.received_base or 0) * cost, l.note or ""])
        return send_report(request, Report(
            title=f"سند استلام رقم {r.id}", filename=f"receipt-{r.id}",
            info=[("المورد", r.supplier.name), ("الحالة", STATUS_NAMES.get(r.status, r.status)),
                  ("رقم فاتورة الشركة", r.supplier_invoice_no or "—"),
                  ("إجمالي الفاتورة", fmt_money(r.supplier_invoice_total) if r.supplier_invoice_total is not None else "—"),
                  ("أُنشئ", fmt_dt(r.created_at)), ("استلمه", f"{r.receiver.name if r.receiver else '—'} · {fmt_dt(r.received_at)}"),
                  ("قيمة المستلم بسعر الشراء", fmt_money(value) + (" (تقريبية)" if estimated else "") if value is not None else "—"),
                  ("ملاحظة", r.note or "—")],
            tables=[Table([Col("م", "int", .4), Col("الصنف", "text", 2.4), Col("المطلوب", "qty", .7), Col("الوحدة", "text", .6),
                           Col("المستلم", "qty", .7), Col("وحدة الاستلام", "text", .7), Col("الفرق", "text", 1.3),
                           Col("سعر الشراء", "money", .8), Col("القيمة", "money", .9), Col("ملاحظة", "text", 1.2)], rows,
                          totals=["", "الإجمالي", "", "", "", "", "", "", value or 0, ""] if value is not None else None)],
            signatures=["المستلم", "مندوب المورد", "المدير"]))
    return render(request, "receipt.html", {"r": r, "value": value, "value_estimated": estimated, "exportable": True,
                                            **history(db, "receipts", r.id, "receipt_lines", [l.id for l in r.lines])})


@router.get("/receipts/{rid}/files/{fid}")
def receipt_file(rid: int, fid: int, user=Depends(need["receipts"]), db: Session = Depends(get_db)):
    f = db.get(ReceiptFile, fid)
    if not f or f.receipt_id != rid:
        return redirect(f"/receipts/{rid}")
    path = Path(config.FILES_DIR) / f.filename
    if not path.is_file():
        return HTMLResponse("<p dir=rtl>الملف مش موجود على الكمبيوتر. رجّعه من النسخة الاحتياطية.</p>", status_code=404)
    return Response(path.read_bytes(), media_type=f.content_type,
                    headers={"Content-Disposition": f'inline; filename="invoice-{rid}-{fid}{path.suffix}"'})


@router.post("/receipts/{rid}/files")
async def receipt_file_upload(rid: int, request: Request, user=Depends(admin_only), db: Session = Depends(get_db)):
    r = db.get(Receipt, rid)
    if not r:
        return redirect("/receipts")
    form = await request.form()
    ups = [u for u in form.getlist("files") if getattr(u, "filename", "")]
    try:
        for u in ups:
            services.save_receipt_file(db, r, await u.read(), u.content_type or "", employee_id=user.id)
    except services.EditError as e:
        db.rollback()
        flash(request, str(e), "error")
        return redirect(f"/receipts/{rid}")
    db.commit()
    flash(request, f"تم رفع {len(ups)} ملف" if ups else "اختار ملف الأول", "ok" if ups else "error")
    return redirect(f"/receipts/{rid}")


@router.post("/receipts/{rid}/invoice")
async def receipt_invoice(rid: int, request: Request, user=Depends(admin_only), db: Session = Depends(get_db)):
    """Set or fix the supplier invoice number and total of any voucher (logged)."""
    r = db.get(Receipt, rid)
    if not r:
        return redirect("/receipts")
    f = await request.form()
    no, total, errors = invoice_fields(db, f, r.supplier, r)
    if errors:
        flash(request, "، ".join(errors), "error")
        return redirect(f"/receipts/{rid}")
    reason = str(f.get("reason", "")).strip()
    services.set_actor(db, f"emp:{user.id}", reason or None)
    r.supplier_invoice_no, r.supplier_invoice_total = no, total
    services.bump(db, r)
    db.commit()
    flash(request, "تم حفظ بيانات فاتورة الشركة")
    return redirect(f"/receipts/{rid}")


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
def sales(request: Request, d_from: str = "", d_to: str = "", employee: int = 0, mi: str = "", problems: int = 0,
          user=Depends(need["sales"]), db: Session = Depends(get_db)):
    today = datetime.now(TZ).date()
    f, t = parse_date(d_from, today), parse_date(d_to, today)
    start, end = local_day_range(f, t)
    mi = "".join(mi.split())
    if mi:  # a ministry invoice number finds its sale whatever the dates
        stmt = select(Sale).where(Sale.ministry_invoice_no == mi)
    else:
        stmt = select(Sale).where(Sale.created_at >= start, Sale.created_at < end)
    if employee:
        stmt = stmt.where(Sale.employee_id == employee)
    items = db.scalars(stmt.order_by(Sale.created_at.desc()).limit(1000)).all()
    flags = services.ministry_flags(db, items)
    if problems:
        items = [s for s in items if flags[s.id]]
    if export_format(request):
        names = {"duplicate": "مكررة", "total": "الإجمالي مختلف", "missing": "من غير رقم"}
        return send_report(request, Report(
            title="المبيعات", filename=f"sales-{f}-{t}",
            subtitle=(f"فاتورة الوزارة {mi}" if mi else f"من {f} إلى {t}") + (" · اللي فيها مشكلة بس" if problems else ""),
            tables=[Table([Col("م", "int", .4), Col("رقم الفاتورة", "int", .8), Col("رقم الجهاز", "int", .6),
                           Col("فاتورة الوزارة", "text", 1.3), Col("الوقت", "text", 1.2), Col("الموظف", "text", 1.1),
                           Col("الجهاز", "text", 1), Col("الأصناف", "int", .6), Col("إجمالي الوزارة", "money", .9),
                           Col("المبلغ", "money", .9), Col("ملاحظة", "text", 1.1)],
                          [[i, x.no, x.device_no or "", x.ministry_invoice_no or "", fmt_dt(x.created_at),
                            x.employee.name if x.employee else "", x.device.name, len(x.lines), x.ministry_total, x.total,
                            "، ".join(names[k] for k in flags[x.id])] for i, x in enumerate(items, 1)],
                          totals=["", "", "", "", f"{len(items)} فاتورة", "", "", "", "", sum((x.total for x in items), Decimal(0)), ""])]))
    return render(request, "sales.html", {"exportable": True,
        "items": items, "d_from": f, "d_to": t, "employee": employee, "mi": mi, "problems": problems, "flags": flags,
        "problem_count": sum(1 for v in flags.values() if v),
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
    same = db.scalars(select(Sale).where(Sale.ministry_invoice_no == s.ministry_invoice_no, Sale.id != s.id)
                      .order_by(Sale.created_at)).all() if s.ministry_invoice_no else []
    if export_format(request):
        return send_report(request, Report(
            title=f"فاتورة رقم {s.no}", filename=f"invoice-{s.no}",
            info=[("التاريخ", fmt_dt(s.created_at)), ("فاتورة الوزارة", s.ministry_invoice_no or "—"),
                  ("الموظف", s.employee.name if s.employee else "—"), ("الجهاز", s.device.name + (f" (#{s.device_no})" if s.device_no else "")),
                  ("إجمالي الوزارة", fmt_money(s.ministry_total) if s.ministry_total is not None else "—"),
                  ("الإجمالي", f"{fmt_money(s.total)} د.ك")],
            tables=[Table([Col("م", "int", .4), Col("الصنف", "text", 3), Col("الكمية", "qty", .8), Col("الوحدة", "text", .7),
                           Col("السعر", "money"), Col("الإجمالي", "money")],
                          [[i, l.product.name, l.qty, l.product.mode_name(l.mode), l.unit_price, l.total] for i, l in enumerate(s.lines, 1)],
                          totals=["", "الإجمالي", "", "", "", s.total])]))
    return render(request, "sale.html", {"s": s, "same": same, "flags": services.ministry_flags(db, [s])[s.id], "exportable": True,
                                         **history(db, "sales", s.id, "sale_lines", [l.id for l in s.lines])})


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
    if export_format(request):
        return send_report(request, Report(
            title="تقرير المبيعات", filename=f"report-{f}-{t}", subtitle=f"من {f} إلى {t}",
            info=[("عدد الفواتير", totals["count"]), ("المبيعات", f"{fmt_money(totals['sales'])} د.ك"),
                  ("التكلفة", f"{fmt_money(totals['cost'])} د.ك"), ("الربح", f"{fmt_money(totals['profit'])} د.ك")],
            tables=[Table([Col("م", "int", .4), Col("اليوم", "text"), Col("عدد الفواتير", "int"), Col("المبيعات", "money"),
                           Col("التكلفة", "money"), Col("الربح", "money")],
                          [[i, d[0], d[1], d[2] or 0, d[3] or 0, (d[2] or 0) - (d[3] or 0)] for i, d in enumerate(days, 1)],
                          title="المبيعات باليوم",
                          totals=["", "الإجمالي", totals["count"], totals["sales"], totals["cost"], totals["profit"]]),
                    Table([Col("م", "int", .4), Col("الصنف", "text", 3), Col("الكمية", "qty"), Col("المبيعات", "money")],
                          [[i, p.name, q, tt] for i, (p, q, tt) in enumerate(top, 1)], title="أكتر 20 صنف مبيعاً"),
                    Table([Col("م", "int", .4), Col("الموظف", "text", 2), Col("الفواتير", "int"), Col("المبيعات", "money")],
                          [[i, n or "—", c, tt] for i, (n, c, tt) in enumerate(by_emp, 1)], title="حسب الموظف")]))
    return render(request, "reports.html", {"days": days, "top": top, "by_emp": by_emp, "totals": totals,
                                            "d_from": f, "d_to": t, "exportable": True})


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
    if export_format(request):
        return send_report(request, Report(
            title="الجرد", filename=f"counts-{datetime.now(TZ):%Y%m%d}", subtitle=STATUS_NAMES.get(status, "الكل"),
            tables=[Table([Col("م", "int", .4), Col("تاريخ الجرد", "text", .9), Col("اللجنة", "text", .6), Col("رقم الجرد", "int", .6),
                           Col("الموظف", "text", 1.2), Col("الجهاز", "text", 1), Col("خلص", "text", 1.1), Col("الأصناف", "int", .6),
                           Col("فيها فرق", "int", .6), Col("الحالة", "text", .9)],
                          [[i, c.count_date or "", c.committee or "", c.no, c.employee.name if c.employee else "", c.device.name,
                            fmt_dt(c.finished_at), len(c.lines), sum(1 for l in c.lines if l.diff != 0), STATUS_NAMES.get(c.status, c.status)]
                           for i, c in enumerate(items, 1)])]))
    return render(request, "counts.html", {"days": days, "status": status, "count": len(items), "exportable": True})


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
    if export_format(request):
        def diff_text(r):
            return "مطابق" if r["diff"] == 0 else (f"ناقص {base_text(r['p'], -r['diff'])}" if r["diff"] < 0 else f"زيادة {base_text(r['p'], r['diff'])}")
        return send_report(request, Report(
            title=f"جرد يوم {d}", filename=f"count-day-{d}",
            info=[("عدد اللجان", len(sessions)), ("الأصناف", len(rows)), ("فيها فرق", sum(1 for r in rows if r["diff"] != 0)),
                  ("قيمة الفرق بسعر الشراء", f"{fmt_money(value)} د.ك")],
            tables=[Table([Col("م", "int", .4), Col("اللجنة", "text", .7), Col("رقم الجرد", "int", .7), Col("الموظف", "text", 1.4),
                           Col("الجهاز", "text", 1.2), Col("الأصناف", "int", .6), Col("الحالة", "text", .9)],
                          [[i, x.committee or "—", x.no, x.employee.name if x.employee else "", x.device.name, len(x.lines),
                            STATUS_NAMES.get(x.status, x.status)] for i, x in enumerate(sessions, 1)], title="اللجان"),
                    Table([Col("م", "int", .4), Col("الصنف", "text", 2.4), Col("اللجان", "text", 1.8), Col("المعدود", "qty", .8),
                           Col("في النظام", "qty", .8), Col("الفرق", "text", 1.3)],
                          [[i, r["p"].name, "، ".join(f"لجنة {x.committee or '—'}: {fmt_qty(l.counted, r['p'].unit)}" for x, l in r["lines"]),
                            r["total"], r["stock"], diff_text(r)] for i, r in enumerate(rows, 1)], title="الأصناف")],
            note=(f"تنبيه: {len(during)} فاتورة اتعملت وقت الجرد على أصناف اتعدّت." if during else ""),
            signatures=["رئيس اللجنة", "المدير"]))
    return render(request, "count_day.html", {"day": d, "sessions": sessions, "rows": rows, "value": value, "during": during, "exportable": True,
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
    if export_format(request):
        def dt_(l):
            return "مطابق" if l.diff == 0 else (f"ناقص {base_text(l.product, -l.diff)}" if l.diff < 0 else f"زيادة {base_text(l.product, l.diff)}")
        return send_report(request, Report(
            title=f"جرد رقم {c.no}" + (f" · لجنة {c.committee}" if c.committee else ""), filename=f"count-{c.no}",
            subtitle="الفروق بس" if only else "",
            info=[("تاريخ الجرد", c.count_date or "—"), ("اللجنة", c.committee or "—"),
                  ("الموظف", c.employee.name if c.employee else "—"), ("الجهاز", c.device.name),
                  ("الحالة", STATUS_NAMES.get(c.status, c.status)), ("راجعه", f"{c.reviewer.name} · {fmt_dt(c.reviewed_at)}" if c.reviewer else "—"),
                  ("الأصناف", stats["all"]), ("قيمة الفرق بسعر الشراء", f"{fmt_money(value)} د.ك")],
            tables=[Table([Col("م", "int", .4), Col("الصنف", "text", 2.6), Col("في النظام", "qty", .8), Col("المعدود", "qty", .8),
                           Col("الفرق", "text", 1.3), Col("قيمة الفرق", "money", .9)],
                          [[i, l.product.name, l.stock_at_sync, l.counted, dt_(l), l.diff * l.product.cost] for i, l in enumerate(lines, 1)],
                          totals=["", "الإجمالي", "", "", "", value])],
            signatures=["رئيس اللجنة", "المدير"]))
    return render(request, "count.html", {"c": c, "value": value, "stats": stats, "lines": lines, "only": only, "exportable": True,
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
    return [{"id": l.id, "name": l.product.name, "unit": l.product.mode_name(l.mode),
             "fields": [("q", "الكمية", f.get(f"q_{l.id}") if f else fmt_qty(l.qty, l.product.unit)),
                        ("p", "السعر", f.get(f"p_{l.id}") if f else fmt_money(l.unit_price))]} for l in s.lines]


def _receipt_rows(r, f=None):
    return [{"id": l.id, "name": l.product.name, "unit": l.product.mode_name(l.received_mode or l.mode),
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
def sale_correct_form(sid: str, request: Request, user=Depends(admin_only), db: Session = Depends(get_db)):
    s = db.get(Sale, sid)
    return _correct_page(request, "sale", s, _sale_rows(s)) if s else redirect("/sales")


@router.post("/accounting/sales/{sid}")
async def sale_correct(sid: str, request: Request, user=Depends(admin_only), db: Session = Depends(get_db)):
    s = db.get(Sale, sid)
    if not s:
        return redirect("/sales")
    return await _correct(request, db, user, "sale", s, _sale_rows, services.edit_sale, f"/sales/{sid}")


@router.get("/accounting/receipts/{rid}", response_class=HTMLResponse)
def receipt_correct_form(rid: int, request: Request, user=Depends(admin_only), db: Session = Depends(get_db)):
    r = db.get(Receipt, rid)
    if not r or r.status != "received":
        return redirect(f"/receipts/{rid}")
    return _correct_page(request, "receipt", r, _receipt_rows(r))


@router.post("/accounting/receipts/{rid}")
async def receipt_correct(rid: int, request: Request, user=Depends(admin_only), db: Session = Depends(get_db)):
    r = db.get(Receipt, rid)
    if not r or r.status != "received":
        return redirect(f"/receipts/{rid}")
    return await _correct(request, db, user, "receipt", r, _receipt_rows, services.correct_receipt, f"/receipts/{rid}")


@router.get("/accounting/counts/{cid}", response_class=HTMLResponse)
def count_correct_form(cid: str, request: Request, user=Depends(admin_only), db: Session = Depends(get_db)):
    c = db.get(CountSession, cid)
    if not c or c.status == "rejected":
        return redirect(f"/counts/{cid}")
    return _correct_page(request, "count", c, _count_rows(c))


@router.post("/accounting/counts/{cid}")
async def count_correct(cid: str, request: Request, user=Depends(admin_only), db: Session = Depends(get_db)):
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
    if export_format(request):
        return send_report(request, Report(
            title="سجل الأسعار", filename=f"prices-{f_from}-{f_to}", subtitle=f"من {f_from} إلى {f_to}" + (f" · {q.strip()}" if q.strip() else ""),
            tables=[Table([Col("م", "int", .4), Col("الوقت", "text", 1.2), Col("الصنف", "text", 2.2), Col("الباركود", "text", 1.3),
                           Col("البيع قبل", "money", .8), Col("البيع بعد", "money", .8), Col("التغيير %", "text", .7),
                           Col("الشراء قبل", "money", .8), Col("الشراء بعد", "money", .8), Col("مين", "text", 1.1)],
                          [[i, fmt_dt(r["e"].at), r["p"].name if r["p"] else f"#{r['pid']}", r["p"].barcode if r["p"] else "",
                            r["price"][0], r["price"][1], "" if r["pct"] is None else f"{r['pct']:+.1f}%", r["cost"][0], r["cost"][1],
                            r["who"]] for i, r in enumerate(rows, 1)])]))
    return render(request, "prices.html", {"rows": rows, "d_from": f_from, "d_to": f_to, "q": q, "exportable": True})


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
    if export_format(request):
        allrows = audit_view(db, db.scalars(q.order_by(AuditLog.at.desc(), AuditLog.id.desc()).limit(5000)).all())
        return send_report(request, Report(
            title="السجل", filename=f"log-{f_from}-{f_to}", subtitle=f"من {f_from} إلى {f_to}" + (" · أول 5000 سطر" if total > 5000 else ""),
            tables=[Table([Col("م", "int", .4), Col("الوقت", "text", 1.1), Col("مين", "text", 1.2), Col("إيه", "text", 1),
                           Col("اتغيّر", "text", 3.5), Col("السبب", "text", 1.3)],
                          [[i, fmt_dt(h["e"].at), h["who"], h["what"] + (f" ({h['action'][0]})" if h["action"] else ""),
                            "\n".join(f"{lbl}: {new}" if (h["is_event"] or h["e"].action == "INSERT") else
                                      (f"{lbl}: {old}" if h["e"].action == "DELETE" else f"{lbl}: {old} ← {new}")
                                      for lbl, old, new in h["changes"]), h["e"].reason or ""]
                           for i, h in enumerate(allrows, 1)])]))
    return render(request, "audit.html", {"exportable": True, "rows": audit_view(db, entries), "links": {e.id: audit_link(db, e) for e in entries},
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
    items = db.scalars(select(Employee).order_by(Employee.active.desc(), Employee.name)).all()
    if export_format(request):
        return send_report(request, Report(
            title="الموظفين", filename=f"employees-{datetime.now(TZ):%Y%m%d}",
            tables=[Table([Col("م", "int", .4), Col("الاسم", "text", 2), Col("الدور", "text", 1.2), Col("اسم المستخدم للوحة", "text", 1.3),
                           Col("الحالة", "text", .7)],
                          [[i, e.name, e.role_name, e.username if e.can_dashboard else "", "فعّال" if e.active else "موقوف"]
                           for i, e in enumerate(items, 1)])]))
    return render(request, "employees.html", {"items": items, "exportable": True})


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
    if e and e.id == user.id and (role != ADMIN_ROLE or not active):
        errors.append("مينفعش تشيل دور المدير من حسابك أو توقفه: المدير بس اللي يقدر يعدّل")
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
    items = all_roles(db)
    if export_format(request):
        return send_report(request, Report(
            title="الأدوار والصلاحيات", filename="roles",
            tables=[Table([Col("م", "int", .4), Col("الدور", "text", 1.2)] + [Col(g, "text", 2.5) for g in PERM_GROUPS] + [Col("موظفين", "int", .6)],
                          [[i, r.name] + ["، ".join(l.split(":")[0] for k, l in perms if k in r.perms) or "—" for perms in PERM_GROUPS.values()]
                           + [used.get(r.key, 0)] for i, r in enumerate(items, 1)])]))
    return render(request, "roles.html", {"items": items, "used": used, "exportable": True})


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
    if export_format(request):
        return send_report(request, Report(
            title="الأجهزة", filename=f"devices-{datetime.now(TZ):%Y%m%d}",
            tables=[Table([Col("م", "int", .4), Col("الجهاز", "text", 2), Col("الحالة", "text", 1), Col("آخر اتصال", "text", 1.2),
                           Col("نسخة التطبيق", "text", 1)],
                          [[i, d.name, "موقوف" if not d.active else ("مربوط" if d.token_hash else "مش مربوط"), fmt_dt(d.last_seen),
                            d.app_version or ""] for i, d in enumerate(items, 1)])]))
    return render(request, "devices.html", {"items": items, "now": now(), "show_code": request.session.pop("show_code", None),
                                            "exportable": True})


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
    return render(request, "backup.html", {"files_dir": config.FILES_DIR, "available": bool(pg_dump_cmd()), "dir": config.BACKUP_DIR,
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
