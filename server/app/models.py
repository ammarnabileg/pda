from datetime import date, datetime, timezone
from decimal import Decimal

from sqlalchemy import (
    BigInteger, Boolean, Date, DateTime, ForeignKey, Integer, Numeric, String, Text, Uuid, text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base

Money = Numeric(12, 3)
Qty = Numeric(14, 3)

# Every permission the system checks. Roles (editable in the dashboard) are sets of these.
# key: (label, group)
PERMISSIONS = {
    # on the device
    "sale": ("البيع", "الجهاز"),
    "price": ("سعر صنف", "الجهاز"),
    "see_cost": ("يشوف سعر الشراء", "الجهاز"),
    "count": ("الجرد", "الجهاز"),
    "receive": ("استلام السندات", "الجهاز"),
    "new_receipt": ("استلام من غير سند", "الجهاز"),
    "device_admin": ("فك ربط الجهاز ورؤية العمليات المرفوضة", "الجهاز"),
    # in the dashboard
    "dashboard": ("دخول لوحة التحكم", "لوحة التحكم"),
    "products": ("الأصناف والموردين والاستيراد", "لوحة التحكم"),
    "receipts": ("سندات الاستلام والموافقة عليها", "لوحة التحكم"),
    "sales": ("المبيعات والتقارير والأرباح", "لوحة التحكم"),
    "counts": ("مراجعة الجرد واعتماده", "لوحة التحكم"),
    "accounting": ("يشوف سجل الفواتير والسندات والجرد", "لوحة التحكم"),
    "audit": ("السجل الكامل: كل التغييرات والدخول على اللوحة", "لوحة التحكم"),
    "employees": ("الموظفين والأدوار والصلاحيات", "لوحة التحكم"),
    "devices": ("الأجهزة وربطها", "لوحة التحكم"),
    "backup": ("النسخ الاحتياطي", "لوحة التحكم"),
}
ALL_PERMISSIONS = frozenset(PERMISSIONS)

# Starting roles, created once on an empty database; all but "admin" can be changed or removed.
DEFAULT_ROLES = [
    ("cashier", "كاشير", {"sale", "price", "see_cost"}),
    ("storekeeper", "أمين مخزن", {"price", "see_cost", "count", "receive", "new_receipt"}),
    ("supervisor", "مشرف", ALL_PERMISSIONS - {"employees", "devices", "backup", "accounting", "audit"}),
    ("accountant", "محاسب", {"dashboard", "sales", "receipts", "counts", "accounting"}),
    ("admin", "مدير", ALL_PERMISSIONS),
]
ADMIN_ROLE = "admin"  # always has every permission, so the system can never lock everyone out
UNITS = {"piece": "حبة", "kg": "كجم"}
MODES = {"piece": "حبة", "carton": "كرتون", "kg": "كجم"}


def now():
    return datetime.now(timezone.utc)


class Role(Base):
    __tablename__ = "roles"
    key: Mapped[str] = mapped_column(String(40), primary_key=True)
    name: Mapped[str] = mapped_column(String(80), unique=True)
    permissions: Mapped[str] = mapped_column(Text, default="")  # comma separated keys

    @property
    def perms(self) -> frozenset:
        if self.key == ADMIN_ROLE:
            return ALL_PERMISSIONS
        return frozenset(p for p in self.permissions.split(",") if p in PERMISSIONS)

    @property
    def is_system(self):
        return self.key == ADMIN_ROLE


class Employee(Base):
    __tablename__ = "employees"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(120))
    role: Mapped[str] = mapped_column(String(20), default="cashier")
    pin_salt: Mapped[str] = mapped_column(String(64))
    pin_hash: Mapped[str] = mapped_column(String(128))
    username: Mapped[str | None] = mapped_column(String(60), unique=True)
    password_hash: Mapped[str | None] = mapped_column(String(200))
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    version: Mapped[int] = mapped_column(BigInteger, default=0, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)

    role_obj: Mapped[Role | None] = relationship(primaryjoin="foreign(Employee.role) == Role.key", viewonly=True, lazy="joined")

    @property
    def perms(self) -> frozenset:
        return self.role_obj.perms if self.role_obj else frozenset()

    def can(self, perm: str) -> bool:
        return perm in self.perms

    @property
    def is_admin(self) -> bool:
        """Only the admin changes anything in the dashboard; every other role views and prints."""
        return self.role == ADMIN_ROLE

    @property
    def role_name(self):
        return self.role_obj.name if self.role_obj else self.role

    @property
    def can_dashboard(self):
        return self.can("dashboard") and bool(self.password_hash)


class Device(Base):
    __tablename__ = "devices"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(80))
    token_hash: Mapped[str | None] = mapped_column(String(128), unique=True)
    pairing_code: Mapped[str | None] = mapped_column(String(12))
    pairing_expires: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    paired_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_seen: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    app_version: Mapped[str | None] = mapped_column(String(40))
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class Product(Base):
    __tablename__ = "products"
    id: Mapped[int] = mapped_column(primary_key=True)
    barcode: Mapped[str] = mapped_column(String(40), unique=True)
    name: Mapped[str] = mapped_column(String(200))
    unit: Mapped[str] = mapped_column(String(10), default="piece")
    price: Mapped[Decimal] = mapped_column(Money, default=0)
    cost: Mapped[Decimal] = mapped_column(Money, default=0)
    carton: Mapped[int] = mapped_column(Integer, default=0)
    stock: Mapped[Decimal] = mapped_column(Qty, default=0)
    min_stock: Mapped[Decimal] = mapped_column(Qty, default=0)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    version: Mapped[int] = mapped_column(BigInteger, default=0, index=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now, onupdate=now)

    extra_barcodes: Mapped[list["ProductBarcode"]] = relationship(
        back_populates="product", cascade="all, delete-orphan", order_by="ProductBarcode.id"
    )

    def to_base(self, qty, mode):
        qty = Decimal(str(qty))
        return qty * self.carton if mode == "carton" else qty

    def unit_price(self, mode):
        return self.price * self.carton if mode == "carton" else self.price


class ProductBarcode(Base):
    """More barcodes for one product: another piece barcode, or the carton's own barcode.
    The product's main barcode stays in products.barcode."""
    __tablename__ = "product_barcodes"
    id: Mapped[int] = mapped_column(primary_key=True)
    product_id: Mapped[int] = mapped_column(ForeignKey("products.id", ondelete="CASCADE"), index=True)
    code: Mapped[str] = mapped_column(String(40), unique=True)
    mode: Mapped[str] = mapped_column(String(10), default="piece")  # piece | carton | kg
    note: Mapped[str | None] = mapped_column(String(80))
    product: Mapped["Product"] = relationship(back_populates="extra_barcodes")


class StockMove(Base):
    __tablename__ = "stock_moves"
    id: Mapped[int] = mapped_column(primary_key=True)
    product_id: Mapped[int] = mapped_column(ForeignKey("products.id"), index=True)
    delta: Mapped[Decimal] = mapped_column(Qty)
    reason: Mapped[str] = mapped_column(String(20))  # sale, receipt, count, manual
    ref: Mapped[str | None] = mapped_column(String(80))
    note: Mapped[str | None] = mapped_column(String(200))
    employee_id: Mapped[int | None] = mapped_column(ForeignKey("employees.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now, index=True)
    product: Mapped[Product] = relationship()


class Supplier(Base):
    __tablename__ = "suppliers"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(200), unique=True)
    phone: Mapped[str | None] = mapped_column(String(40))
    active: Mapped[bool] = mapped_column(Boolean, default=True)


class Receipt(Base):
    """A supplier delivery voucher: created in the dashboard, checked on the device."""
    __tablename__ = "receipts"
    id: Mapped[int] = mapped_column(primary_key=True)
    supplier_id: Mapped[int] = mapped_column(ForeignKey("suppliers.id"))
    status: Mapped[str] = mapped_column(String(12), default="open")  # open, received, cancelled
    note: Mapped[str | None] = mapped_column(Text)
    # The supplier's own invoice: its number (asked first, never twice for the same supplier) and its total,
    # which is what the supplier statement bills. Empty only on vouchers from before these fields existed.
    supplier_invoice_no: Mapped[str | None] = mapped_column(String(60))
    supplier_invoice_total: Mapped[Decimal | None] = mapped_column(Money)
    # Set when the voucher was made on a device for a delivery that had none (idempotent upload).
    client_id: Mapped[str | None] = mapped_column(String(40), unique=True)
    # Device-made vouchers wait for a supervisor (status "pending") before stock changes.
    approved_by: Mapped[int | None] = mapped_column(ForeignKey("employees.id"))
    approved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    device_notes: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    received_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    received_by: Mapped[int | None] = mapped_column(ForeignKey("employees.id"))
    device_id: Mapped[int | None] = mapped_column(ForeignKey("devices.id"))
    version: Mapped[int] = mapped_column(BigInteger, default=0, index=True)
    supplier: Mapped[Supplier] = relationship()
    receiver: Mapped[Employee | None] = relationship(foreign_keys=[received_by])
    approver: Mapped[Employee | None] = relationship(foreign_keys=[approved_by])
    lines: Mapped[list["ReceiptLine"]] = relationship(
        back_populates="receipt", cascade="all, delete-orphan", order_by="ReceiptLine.id"
    )
    files: Mapped[list["ReceiptFile"]] = relationship(back_populates="receipt", order_by="ReceiptFile.id")


class ReceiptLine(Base):
    __tablename__ = "receipt_lines"
    id: Mapped[int] = mapped_column(primary_key=True)
    receipt_id: Mapped[int] = mapped_column(ForeignKey("receipts.id"), index=True)
    product_id: Mapped[int] = mapped_column(ForeignKey("products.id"))
    mode: Mapped[str] = mapped_column(String(10))
    ordered: Mapped[Decimal] = mapped_column(Qty, default=0)
    received: Mapped[Decimal | None] = mapped_column(Qty)
    received_mode: Mapped[str | None] = mapped_column(String(10))
    extra: Mapped[bool] = mapped_column(Boolean, default=False)
    note: Mapped[str | None] = mapped_column(String(200))  # written on the device, e.g. "3 علب تالفة"
    # Purchase price per piece (or kg) when the line was received, so old vouchers keep their value.
    unit_cost: Mapped[Decimal | None] = mapped_column(Money)
    receipt: Mapped[Receipt] = relationship(back_populates="lines")
    product: Mapped[Product] = relationship()

    @property
    def ordered_base(self):
        return self.product.to_base(self.ordered, self.mode)

    @property
    def received_base(self):
        if self.received is None:
            return None
        return self.product.to_base(self.received, self.received_mode or self.mode)

    @property
    def diff_base(self):
        r = self.received_base
        return None if r is None else r - self.ordered_base


class Sale(Base):
    __tablename__ = "sales"
    id: Mapped[str] = mapped_column(Uuid(as_uuid=False), primary_key=True)
    # Invoice number: one sequence for the whole co-op, given when the sale reaches the server.
    no: Mapped[int] = mapped_column(BigInteger, unique=True, server_default=text("nextval('sale_no')"))
    # The device's own running number, shown to the cashier before the sale is synced.
    device_no: Mapped[int | None] = mapped_column(Integer)
    device_id: Mapped[int] = mapped_column(ForeignKey("devices.id"))
    employee_id: Mapped[int | None] = mapped_column(ForeignKey("employees.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    synced_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    total: Mapped[Decimal] = mapped_column(Money)
    employee: Mapped[Employee | None] = relationship()
    device: Mapped[Device] = relationship()
    lines: Mapped[list["SaleLine"]] = relationship(
        back_populates="sale", cascade="all, delete-orphan", order_by="SaleLine.id"
    )


class SaleLine(Base):
    __tablename__ = "sale_lines"
    id: Mapped[int] = mapped_column(primary_key=True)
    sale_id: Mapped[str] = mapped_column(ForeignKey("sales.id"), index=True)
    product_id: Mapped[int] = mapped_column(ForeignKey("products.id"), index=True)
    mode: Mapped[str] = mapped_column(String(10))
    qty: Mapped[Decimal] = mapped_column(Qty)
    unit_price: Mapped[Decimal] = mapped_column(Money)
    unit_cost: Mapped[Decimal] = mapped_column(Money, default=0)
    total: Mapped[Decimal] = mapped_column(Money)
    sale: Mapped[Sale] = relationship(back_populates="lines")
    product: Mapped[Product] = relationship()


class CountSession(Base):
    __tablename__ = "count_sessions"
    id: Mapped[str] = mapped_column(Uuid(as_uuid=False), primary_key=True)
    no: Mapped[int] = mapped_column(BigInteger, unique=True, server_default=text("nextval('count_no')"))
    device_no: Mapped[int | None] = mapped_column(Integer)
    # One stocktake = one date; each committee (team on one device) counts its part. Same date = counted together.
    count_date: Mapped[date | None] = mapped_column(Date, index=True)
    committee: Mapped[str | None] = mapped_column(String(20))
    device_id: Mapped[int] = mapped_column(ForeignKey("devices.id"))
    employee_id: Mapped[int | None] = mapped_column(ForeignKey("employees.id"))
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    finished_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    synced_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    status: Mapped[str] = mapped_column(String(12), default="submitted")  # submitted, approved, rejected
    reviewed_by: Mapped[int | None] = mapped_column(ForeignKey("employees.id"))
    reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    employee: Mapped[Employee | None] = relationship(foreign_keys=[employee_id])
    reviewer: Mapped[Employee | None] = relationship(foreign_keys=[reviewed_by])
    device: Mapped[Device] = relationship()
    lines: Mapped[list["CountLine"]] = relationship(
        back_populates="session", cascade="all, delete-orphan", order_by="CountLine.id"
    )


class CountLine(Base):
    __tablename__ = "count_lines"
    id: Mapped[int] = mapped_column(primary_key=True)
    session_id: Mapped[str] = mapped_column(ForeignKey("count_sessions.id"), index=True)
    product_id: Mapped[int] = mapped_column(ForeignKey("products.id"))
    counted: Mapped[Decimal] = mapped_column(Qty)
    # Server stock when the count arrived. Approval applies (counted - this), so sales
    # made between counting and approval are not wiped out.
    stock_at_sync: Mapped[Decimal] = mapped_column(Qty)
    session: Mapped[CountSession] = relationship(back_populates="lines")
    product: Mapped[Product] = relationship()

    @property
    def diff(self):
        return self.counted - self.stock_at_sync


class AuditLog(Base):
    """Every change to a sale, voucher or count, written by PostgreSQL triggers (see db.KEEP_FOREVER).

    Never updated or deleted. actor is "emp:<id>", "dev:<id>" or empty for a change made outside the app.
    """
    __tablename__ = "audit_log"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    actor: Mapped[str | None] = mapped_column(String(40))
    reason: Mapped[str | None] = mapped_column(Text)
    table_name: Mapped[str] = mapped_column(String(40))
    row_id: Mapped[str] = mapped_column(String(64))
    action: Mapped[str] = mapped_column(String(20))
    changes: Mapped[dict] = mapped_column(JSONB)


class ReceiptFile(Base):
    """A photo or scan of the supplier's invoice. The file lives in config.FILES_DIR; it is never deleted."""
    __tablename__ = "receipt_files"
    id: Mapped[int] = mapped_column(primary_key=True)
    receipt_id: Mapped[int] = mapped_column(ForeignKey("receipts.id"), index=True)
    filename: Mapped[str] = mapped_column(String(120))  # path inside FILES_DIR
    content_type: Mapped[str] = mapped_column(String(60))
    size: Mapped[int] = mapped_column(Integer)
    uploaded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    uploaded_by: Mapped[int | None] = mapped_column(ForeignKey("employees.id"))
    device_id: Mapped[int | None] = mapped_column(ForeignKey("devices.id"))
    client_id: Mapped[str | None] = mapped_column(String(60), unique=True)  # retry-safe uploads from devices
    receipt: Mapped[Receipt] = relationship(back_populates="files")


PAYMENT_METHODS = {"cash": "نقدي", "cheque": "شيك", "transfer": "تحويل بنكي", "other": "أخرى"}


class SupplierPayment(Base):
    """Money paid to a supplier. Together with received vouchers it makes the supplier statement."""
    __tablename__ = "supplier_payments"
    id: Mapped[int] = mapped_column(primary_key=True)
    supplier_id: Mapped[int] = mapped_column(ForeignKey("suppliers.id"), index=True)
    amount: Mapped[Decimal] = mapped_column(Money)
    paid_on: Mapped[date] = mapped_column(Date, index=True)
    method: Mapped[str] = mapped_column(String(20), default="cash")
    reference: Mapped[str | None] = mapped_column(String(80))  # cheque or transfer number
    note: Mapped[str | None] = mapped_column(Text)
    created_by: Mapped[int | None] = mapped_column(ForeignKey("employees.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    supplier: Mapped[Supplier] = relationship()
    creator: Mapped[Employee | None] = relationship()

